#!/usr/bin/env python3
"""leakgate: refuse site-specific strings before they reach a public repo.

  leakgate.py [--strict] [PATH...]   scan files; default: the repo's tracked
                                     and untracked (non-ignored) files
  leakgate.py --staged               scan the index (pre-commit)
  leakgate.py --msg FILE             scan a commit message (commit-msg)
  leakgate.py --history              scan every commit's identities, message
                                     and blobs, plus ref names (pre-push)

Two kinds of finding:

  generic  IPv4 addresses, e-mail addresses, host names, URL and scp hosts,
           /home/<name> paths, binary files. Each class has a built-in allow
           set: loopback and the documentation address ranges, example.*
           domains, the public forges, GitHub noreply addresses. A line
           carrying the pragma `leakgate: allow` is exempt from the generic
           classes.
  deny     one case-insensitive regex per line of a private deny list:
           --deny FILE, else $LEAKGATE_DENY, else <config home>/leakgate.deny
           where the config home is $SC_CONFIG_HOME, else
           ${XDG_CONFIG_HOME:-~/.config}/sc-fleet. Nothing exempts a deny
           match.

The deny list is private on purpose: the names it guards must not appear in
the repo it guards. --strict fails when the list is missing or empty, so a
machine without it cannot pass a publish check by accident.

Findings print as `where: class token`, the token redacted unless --show.
Exit 0 clean, 1 findings, 2 usage error or (with --strict) no deny list.
"""
from __future__ import annotations

import argparse
import ipaddress
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

PRAGMA = "leakgate: allow"

ALLOWED_DOMAINS = (
    "example.com", "example.org", "example.net", "example",
    "invalid", "test", "localhost",
    "github.com", "githubusercontent.com", "gitlab.com", "codeberg.org",
    "gnu.org", "kernel.org", "python.org", "freedesktop.org", "man7.org",
    "git-scm.com", "semver.org", "keepachangelog.com", "opensource.org",
    "spdx.org", "shellcheck.net", "zsh.org", "tmux.github.io",
)
ALLOWED_EMAIL_DOMAINS = ("users.noreply.github.com",)
PLACEHOLDER_HOSTS = {"host", "hostname", "h", "server"}
ALLOWED_HOME_NAMES = {"user", "you", "me", "alice", "bob", "carol", "someone", "example", "name"}
DOC_NETS = tuple(ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "0.0.0.0/32", "255.255.255.255/32",
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
))
# Netmasks look like addresses and name no host.
NETMASKS = {f"255.255.{c}.0" for c in (0, 128, 192, 224, 240, 248, 252, 254, 255)} | {
    "255.0.0.0", "255.255.0.0", "255.255.255.0"}

# Host names are recognised by a curated TLD list rather than "anything
# dotted", which would flag every file.md and module.py. `local` is left out
# because `config.local` is a file name here, not an mDNS host.
TLDS = ("com|net|org|io|dev|ai|co|app|cloud|tech|info|biz|xyz|me|us|uk|ca|de|fr|ch|nl|eu|jp|au"
        "|lan|internal|intranet|corp|intra|localdomain|home")

OCTET = r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"
RX_IPV4 = re.compile(rf"(?<![\w.]){OCTET}(?:\.{OCTET}){{3}}(?!\.?\d)")
RX_URL = re.compile(r"\b[a-z][a-z0-9+.-]*://([^/\s'\"<>()\[\]`]*)", re.I)
RX_SCP = re.compile(r"(?<![\w/@.-])[\w.-]+@([\w-]+(?:\.[\w-]+)*):(?!//)")
RX_EMAIL = re.compile(r"(?<![\w.%+-])[\w.%+-]+@([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?![\w-])", re.I)
RX_FQDN = re.compile(rf"(?:(?<![\w@.$\\-])|(?<=\\[ntr]))((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:{TLDS}))(?![\w-]|\.[a-z0-9])", re.I)
# Only at a path's root: $T/home/<n> is a test fixture, /home/<n> a person.
RX_HOME = re.compile(r"(?<![\w.$}~/-])/(?:home|Users)/([A-Za-z0-9._-]+)")


@dataclass(frozen=True)
class Finding:
    where: str
    cls: str
    token: str


def redact(tok: str, show: bool) -> str:
    if show or len(tok) <= 3:
        return tok if show else "…" * len(tok)
    return f"{tok[:2]}…({len(tok)})"


def domain_allowed(host: str) -> bool:
    h = host.lower().rstrip(".")
    return any(h == d or h.endswith("." + d) for d in ALLOWED_DOMAINS)


def ip_allowed(text: str) -> bool:
    if text in NETMASKS:
        return True
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return True
    return any(ip in n for n in DOC_NETS)


def host_allowed(host: str) -> bool:
    host = host.rsplit("@", 1)[-1]
    if host.startswith("["):
        return True
    host = host.split(":", 1)[0].lower()
    if not re.search(r"[a-z0-9]", host) or host[0] in "$<{%*" or host == "localhost" \
            or host in PLACEHOLDER_HOSTS:
        return True
    if re.fullmatch(r"github-[\w-]+", host):
        return True
    if RX_IPV4.fullmatch(host):
        return ip_allowed(host)
    return domain_allowed(host)


def load_deny(path: Path | None) -> tuple[list[re.Pattern[str]], Path]:
    if path is None:
        env = os.environ.get("LEAKGATE_DENY")
        if env:
            path = Path(env)
        else:
            home = os.environ.get("SC_CONFIG_HOME") or os.path.join(
                os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "sc-fleet")
            path = Path(home) / "leakgate.deny"
    pats: list[re.Pattern[str]] = []
    if path.is_file():
        for n, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                pats.append(re.compile(line, re.I))
            except re.error as e:
                sys.exit(f"leakgate: {path}:{n}: bad regex ({e})")
    return pats, path


class Scanner:
    def __init__(self, deny: list[re.Pattern[str]]) -> None:
        self.deny = deny
        self.findings: list[Finding] = []
        self.scanned = 0

    def add(self, where: str, cls: str, tok: str) -> None:
        self.findings.append(Finding(where, cls, tok))

    def line(self, where: str, text: str) -> None:
        for i, rx in enumerate(self.deny, 1):
            for m in rx.finditer(text):
                self.add(where, f"deny#{i}", m.group(0))
        if PRAGMA in text:
            return
        taken: list[tuple[int, int]] = []

        def free(a: int, b: int) -> bool:
            return all(b <= x or a >= y for x, y in taken)

        for m in RX_URL.finditer(text):
            taken.append(m.span())
            if not host_allowed(m.group(1)):
                self.add(where, "url", m.group(1))
        for m in RX_SCP.finditer(text):
            if not free(*m.span()):
                continue
            taken.append(m.span())
            if not host_allowed(m.group(1)):
                self.add(where, "scp", m.group(1))
        for m in RX_EMAIL.finditer(text):
            if not free(*m.span()):
                continue
            taken.append(m.span())
            dom = m.group(1).lower()
            if not (domain_allowed(dom) or any(dom == d for d in ALLOWED_EMAIL_DOMAINS)):
                self.add(where, "email", m.group(0))
        for m in RX_IPV4.finditer(text):
            if free(*m.span()) and not ip_allowed(m.group(0)):
                self.add(where, "ipv4", m.group(0))
        for m in RX_FQDN.finditer(text):
            if free(*m.span()) and not domain_allowed(m.group(1)):
                self.add(where, "host", m.group(1))
        for m in RX_HOME.finditer(text):
            if m.group(1).lower() not in ALLOWED_HOME_NAMES:
                self.add(where, "home", m.group(0))

    def text(self, where: str, body: str, skip_comments: bool = False) -> None:
        for n, ln in enumerate(body.splitlines(), 1):
            if skip_comments and ln.startswith("#"):
                continue
            self.line(f"{where}:{n}", ln)

    def blob(self, name: str, data: bytes) -> None:
        self.scanned += 1
        self.line(f"{name} (name)", name)
        if b"\0" in data[:8192]:
            self.add(name, "binary", name.rsplit("/", 1)[-1])
            return
        self.text(name, data.decode("utf-8", errors="replace"))


def git(*args: str, cwd: str | None = None) -> bytes:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True).stdout


def in_repo() -> bool:
    return subprocess.run(["git", "rev-parse", "--git-dir"], capture_output=True).returncode == 0


def walk(paths: list[str]) -> list[tuple[Path, str]]:
    """(file, name as published): relative to a directory argument, the bare
    name for a file argument. Where the file sits on this machine is not part
    of what gets published, so it is not scanned."""
    out: list[tuple[Path, str]] = []
    for p in map(Path, paths):
        if p.is_dir():
            out += sorted((f, str(f.relative_to(p))) for f in p.rglob("*") if f.is_file()
                          and not {".git", "__pycache__"} & set(f.relative_to(p).parts))
        elif p.is_file():
            out.append((p, p.name))
        else:
            sys.exit(f"leakgate: no such file: {p}")
    return out


def scan_files(sc: Scanner, paths: list[str]) -> None:
    if paths:
        files = walk(paths)
    elif in_repo():
        top = Path(git("rev-parse", "--show-toplevel").decode().strip())
        names = git("ls-files", "-z", "-co", "--exclude-standard", cwd=str(top)).decode().split("\0")
        files = [(top / n, n) for n in names if n and (top / n).is_file()]
    else:
        files = walk(["."])
    for f, name in files:
        sc.blob(name, f.read_bytes())


def scan_staged(sc: Scanner) -> None:
    names = git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR").decode().split("\0")
    for n in filter(None, names):
        sc.blob(n, git("show", f":{n}"))


def cat_blobs(shas: dict[str, str]) -> dict[str, bytes]:
    if not shas:
        return {}
    p = subprocess.run(["git", "cat-file", "--batch"], input="\n".join(shas).encode() + b"\n",
                       capture_output=True, check=True)
    out, buf, i = {}, p.stdout, 0
    while i < len(buf):
        nl = buf.index(b"\n", i)
        sha, typ, size = buf[i:nl].decode().split()
        start = nl + 1
        out[sha] = buf[start:start + int(size)] if typ == "blob" else b""
        i = start + int(size) + 1
    return out


def scan_history(sc: Scanner) -> None:
    if not git("rev-list", "--all", "--max-count=1").strip():
        return
    log = git("log", "--all", "--format=%H%x00%an%x00%ae%x00%cn%x00%ce%x00%B%x1e").decode(errors="replace")
    for rec in filter(str.strip, log.split("\x1e")):
        sha, an, ae, cn, ce, msg = rec.lstrip("\n").split("\0", 5)
        short = sha[:10]
        for label, val in (("author", f"{an} <{ae}>"), ("committer", f"{cn} <{ce}>")):
            sc.line(f"commit {short} {label}", val)
        sc.text(f"commit {short} message", msg)
    for ref in git("for-each-ref", "--format=%(refname)").decode().split():
        sc.line(f"ref {ref}", ref)
    blobs: dict[str, str] = {}
    for ln in git("rev-list", "--all", "--objects").decode(errors="replace").splitlines():
        sha, _, path = ln.partition(" ")
        if path:
            blobs.setdefault(sha, path)
    for sha, data in cat_blobs(blobs).items():
        if data or blobs[sha]:
            sc.blob(f"{blobs[sha]}@{sha[:10]}", data)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="leakgate", description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--staged", action="store_true", help="scan the index")
    mode.add_argument("--msg", metavar="FILE", help="scan a commit message file")
    mode.add_argument("--history", action="store_true", help="scan every commit and ref")
    ap.add_argument("--deny", type=Path, help="deny list (default: see --help)")
    ap.add_argument("--strict", action="store_true", help="fail without a deny list")
    ap.add_argument("--show", action="store_true", help="print tokens unredacted")
    ap.add_argument("-q", "--quiet", action="store_true", help="print findings only")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args(argv)

    deny, deny_path = load_deny(a.deny)
    if not deny:
        if a.strict:
            print(f"leakgate: no deny list at {deny_path} (--strict)", file=sys.stderr)
            return 2
        if not a.quiet:
            print(f"leakgate: no deny list at {deny_path}; generic classes only", file=sys.stderr)

    sc = Scanner(deny)
    if a.staged:
        scan_staged(sc)
    elif a.msg:
        sc.text("message", Path(a.msg).read_text(encoding="utf-8", errors="replace"), skip_comments=True)
        sc.scanned = 1
    elif a.history:
        scan_history(sc)
    else:
        scan_files(sc, a.paths)

    for f in sc.findings:
        print(f"{f.where}: {f.cls} {redact(f.token, a.show)}")
    if sc.findings:
        where = {f.where.split(":", 1)[0] for f in sc.findings}
        print(f"leakgate: {len(sc.findings)} finding(s) in {len(where)} place(s)", file=sys.stderr)
        return 1
    if not a.quiet:
        print(f"leakgate: clean ({sc.scanned} scanned, {len(deny)} deny pattern(s))", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
