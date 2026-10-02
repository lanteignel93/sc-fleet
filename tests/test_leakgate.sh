#!/usr/bin/env bash
# Offline test suite for tools/leakgate.py — run: bash tests/test_leakgate.sh
#
# Every class is planted at run time, its value assembled with printf, so this
# file never carries a literal the gate would refuse. The synthetic deny term
# is built the same way and lives only in a temp deny list. The last section
# runs the gate, strict, over this repository with the real deny list; on a
# machine without one it says SKIP and runs the generic classes only.
set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GATE="$REPO/tools/leakgate.py"
T="$(mktemp -d -t leakgate-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
check_eq() { [[ "$2" == "$3" ]] && pass || fail "$1: expected [$3] got [$2]"; }
check_grep() { grep -qE -- "$2" <<<"$3" && pass || fail "$1: no match for /$2/ in: $3"; }
check_nogrep() { grep -qE -- "$2" <<<"$3" && fail "$1: unexpected /$2/" || pass; }

TERM_="$(printf '%s-%s-%s' zq acme zq)"
printf '# synthetic\n%s\n' "$TERM_" > "$T/deny"
: > "$T/empty-deny"
gate() { python3 "$GATE" --deny "$T/deny" "$@"; }

# caught LABEL CLASS LINE: the line alone in a file must give one CLASS finding
caught() {
  printf '%s\n' "$3" > "$T/f.txt"
  local o rc; o="$(gate "$T/f.txt" 2>/dev/null)"; rc=$?
  check_eq "$1: exits 1" "$rc" 1
  check_grep "$1: classed $2" ": $2 " "$o"
}
# clean LABEL LINE: the line alone in a file must pass
clean() {
  printf '%s\n' "$2" > "$T/f.txt"
  local o rc; o="$(gate "$T/f.txt" 2>/dev/null)"; rc=$?
  check_eq "$1: passes" "$rc:$o" "0:"
}

# --- 1. every generic class fires -------------------------------------------
caught "ipv4"          ipv4  "$(printf 'reach %s.%s.%s.%s' 10 20 30 40)"
caught "email"         email "$(printf 'mail %s@%s.%s' jdoe corp-zq com)"
caught "host"          host  "$(printf 'see build.%s.%s' corp-zq com)"
caught "url host"      url   "$(printf 'open https://%s/x' intranet-zq)"
caught "scp host"      scp   "$(printf 'git@%s:o/r.git' forge-zq)"
caught "home path"     home  "$(printf 'cd "/%s/%s/x"' home jdoe-zq)"
caught "internal tld"  host  "$(printf 'ssh box.%s' lan)"
caught "escaped glue"  host  "$(printf 'a\\nforge.%s.%s' corp-zq com)"

# --- 2. the allow sets ------------------------------------------------------
clean "loopback"              "$(printf 'bind %s.%s.%s.%s' 127 0 0 1)"
clean "documentation range"   "$(printf 'reach %s.%s.%s.%s' 192 0 2 7)"
clean "a netmask"             "$(printf 'mask %s.%s.%s.%s' 255 255 255 0)"
clean "a three-part version"  "bash 5.2.21"
clean "example domains"       "$(printf 'git@forge.%s:acme/r.git and x@%s' example.org example.com)"
clean "public forges"         "$(printf 'git@%s:o/r and https://%s/o/r' github.com gitlab.com)"
clean "a github ssh alias"    "$(printf 'git@%s:acme/r.git' github-acme)"
clean "a noreply address"     "$(printf '1+me@%s' users.noreply.github.com)"
clean "file names, not hosts" "config.local tasks.md mkart.py sckit.sh"
clean "placeholders"          "$(printf 'https://%s/o/r ssh://u@%s https://%s/x' '<host>' host '$FORGE')"
clean "file URLs"             "file:///tmp/x.git"
clean "a fixture home"        "$(printf '%s/%s/%s' '$T' home jdoe-zq)"
clean "a placeholder home"    "$(printf '/%s/%s/x' home user)"
clean "the pragma"            "$(printf 'reach %s.%s.%s.%s  # leakgate: allow' 10 20 30 40)"

# --- 3. the deny list --------------------------------------------------------
caught "deny term"            'deny#1' "a line naming $TERM_ here"
caught "deny is case-blind"   'deny#1' "$(tr a-z A-Z <<<"$TERM_")"
caught "the pragma never exempts a deny term" 'deny#1' "$TERM_  # leakgate: allow"
mkdir -p "$T/tree"; : > "$T/tree/$TERM_.txt"
o="$(gate "$T/tree" 2>/dev/null)"; rc=$?
check_eq "deny: a file name is scanned" "$rc" 1
check_grep "deny: the name finding" '\(name\): deny#1' "$o"

# --- 4. binaries, redaction, strictness ------------------------------------------
printf 'a\0b' > "$T/blob.bin"
o="$(gate "$T/blob.bin" 2>/dev/null)"; check_grep "binary: refused" ': binary ' "$o"
printf '%s\n' "$TERM_" > "$T/f.txt"
o="$(gate "$T/f.txt" 2>/dev/null)"
check_nogrep "redact: the token is not printed" "$TERM_" "$o"
check_grep "redact: --show prints it" "$TERM_" "$(gate --show "$T/f.txt" 2>/dev/null)"
printf 'nothing to see\n' > "$T/ok.txt"
python3 "$GATE" --strict --deny "$T/empty-deny" "$T/ok.txt" >/dev/null 2>&1; rc=$?
check_eq "strict: an empty deny list exits 2" "$rc" 2
python3 "$GATE" --strict --deny "$T/absent" "$T/ok.txt" >/dev/null 2>&1; rc=$?
check_eq "strict: a missing deny list exits 2" "$rc" 2
o="$(python3 "$GATE" --deny "$T/absent" "$T/ok.txt" 2>&1)"; rc=$?
check_eq "lax: no deny list still runs the generic classes" "$rc" 0
check_grep "lax: and says so" 'generic classes only' "$o"
printf 'bad[\n' > "$T/bad-deny"
python3 "$GATE" --deny "$T/bad-deny" "$T/ok.txt" >/dev/null 2>&1; rc=$?
check_eq "deny: a bad regex is an error, not a pass" "$rc" 1

# --- 5. hook modes on a scratch repo -----------------------------------------
R="$T/repo"; mkdir -p "$R"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git -C "$R" init -q -b main
git -C "$R" config user.name Tester
git -C "$R" config user.email "1+tester@users.noreply.github.com"
printf 'clean\n' > "$R/a.txt"; git -C "$R" add a.txt; git -C "$R" commit -qm "a clean start"
o="$(cd "$R" && gate --history 2>/dev/null)"; rc=$?
check_eq "history: a clean repo passes" "$rc:$o" "0:"

printf '%s\n' "$TERM_" > "$R/b.txt"; git -C "$R" add b.txt
o="$(cd "$R" && gate --staged 2>/dev/null)"; rc=$?
check_eq "staged: a planted term is refused" "$rc" 1
check_grep "staged: names the file" '^b\.txt:1: deny#1' "$o"
git -C "$R" reset -q b.txt; rm "$R/b.txt"
printf '%s\n' "$TERM_" > "$R/a.txt"
o="$(cd "$R" && gate --staged 2>/dev/null)"; rc=$?
check_eq "staged: an unstaged edit is not the index's" "$rc" 0
git -C "$R" checkout -q a.txt

printf 'subject\n\nbody naming %s\n' "$TERM_" > "$T/msg"
gate --msg "$T/msg" >/dev/null 2>&1; rc=$?
check_eq "msg: a planted term is refused" "$rc" 1
printf 'subject\n# git comment naming %s\n' "$TERM_" > "$T/msg"
gate --msg "$T/msg" >/dev/null 2>&1; rc=$?
check_eq "msg: git's comment lines are skipped" "$rc" 0

printf '%s\n' "$TERM_" > "$R/c.txt"; git -C "$R" add c.txt; git -C "$R" commit -qm "add c"
git -C "$R" rm -q c.txt; git -C "$R" commit -qm "drop c"
o="$(cd "$R" && gate --history 2>/dev/null)"
check_grep "history: a blob deleted later is still found" '^c\.txt@[0-9a-f]+:1: deny#1' "$o"
git -C "$R" -c user.email="$(printf '%s@%s.%s' jdoe corp-zq com)" commit -q --allow-empty -m "x"
o="$(cd "$R" && gate --history 2>/dev/null)"
check_grep "history: an author address is checked" 'author: email' "$o"
git -C "$R" commit -q --allow-empty -m "naming $TERM_"
o="$(cd "$R" && gate --history 2>/dev/null)"
check_grep "history: a commit message is checked" 'message:1: deny#1' "$o"
git -C "$R" branch "topic-$TERM_"
o="$(cd "$R" && gate --history 2>/dev/null)"
check_grep "history: a ref name is checked" '^ref refs/heads/topic' "$o"
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

# --- 6. this repository is clean ----------------------------------------------
if o="$(cd "$REPO" && python3 "$GATE" --strict -q 2>&1)"; then
  pass
elif grep -q 'no deny list' <<<"$o"; then
  printf 'SKIP  no deny list on this machine: generic classes only\n' >&2
  o="$(cd "$REPO" && python3 "$GATE" -q 2>&1)" && pass || fail "repo: generic classes: $o"
else
  fail "repo: the gate refuses this tree: $o"
fi

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
