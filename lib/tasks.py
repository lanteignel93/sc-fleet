#!/usr/bin/env python3
"""Task engine for a markdown task board, tasks.md.

Markdown checkbox tasks in the Obsidian Tasks emoji grammar:

    - [ ] Rotate certs ⏫ 🔁 every 3 months 🛫 2026-09-24 📅 2026-10-01

Fields: priority 🔺⏫🔼🔽⏬ · 🔁 recurrence (optional "... when done")
· 🛫 scheduled/lead-time · 📅 due · ✅ done stamp · ❌ cancelled stamp.
Statuses: [ ] todo · [/] in progress · [x] done · [-] cancelled.

State changes should go through this tool (recurrence math stays
deterministic); reorganizing or rewording by hand is fine — run `check`
afterwards. Full spec: docs/tasks.md in the sc-fleet checkout.
"""

from __future__ import annotations

import argparse
import calendar
import json
import os
import pwd
import re
import sys
import tempfile
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Dict, List, Optional, Tuple


# The fleet's config reader, twin of lib/scconf.sh (tests/test_conf.sh keeps
# them identical). Files: $SC_CONFIG_HOME/{config,config.local}; grammar
# `tool.key=value`, `#` comments, read and never evaluated.
def sc_conf_home() -> str:
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.environ.get("SC_CONFIG_HOME") or os.path.join(xdg, "sc-fleet")


def _sc_conf_values(path: str, key: str) -> List[str]:
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        if re.match(r"^\s*(#|$)", line):
            continue
        line = re.sub(r"\s+#.*$", "", line)
        k, eq, v = line.partition("=")
        if eq and k.strip() == key:
            out.append(v.strip())
    return out


def _sc_conf_expand(value: str) -> str:
    home = os.path.expanduser("~")
    user = os.environ.get("USER") or pwd.getpwuid(os.getuid()).pw_name
    v = (" " + value).replace(" ~/", " " + home + "/")
    if v == " ~":
        v = " " + home
    v = v.replace("${HOME}", home).replace("$HOME", home)
    v = v.replace("${USER}", user).replace("$USER", user)
    return v[1:]


def sc_conf(key: str, default: str = "") -> str:
    home = sc_conf_home()
    for name in ("config.local", "config"):
        vals = _sc_conf_values(os.path.join(home, name), key)
        if vals and vals[-1]:
            return _sc_conf_expand(vals[-1])
    return default


def sc_conf_all(key: str) -> List[str]:
    home = sc_conf_home()
    vals = (_sc_conf_values(os.path.join(home, "config.local"), key)
            + _sc_conf_values(os.path.join(home, "config"), key))
    return [_sc_conf_expand(v) for v in vals if v]


def default_file() -> str:
    """<tk.store>/tasks.md; tk.store follows the notes root (config), and
    TK_STORE wins, as it does for tk. Resolved at call time, not import time,
    because other tools import this module."""
    store = os.environ.get("TK_STORE") or sc_conf(
        "tk.store", sc_conf("notes", os.path.join(os.path.expanduser("~"), "notes")))
    return os.path.join(store, "tasks.md")


def bootstrap_hint(path: str) -> str:
    here = os.path.dirname(os.path.realpath(__file__))
    tpl = os.path.join(here, "..", "examples", "tasks.md")
    if os.path.isfile(tpl):
        return "bootstrap: mkdir -p {} && cp {} {}".format(
            os.path.dirname(path), os.path.normpath(tpl), path)
    return "bootstrap: create {} with a '## Inbox' heading".format(path)


SPEC = os.path.normpath(os.path.join(
    os.path.dirname(os.path.realpath(__file__)), "..", "docs", "tasks.md"))

ARCHIVE_BASENAME = "tasks_archive.md"
ARCHIVE_HEADER = [
    "# Task archive",
    "",
    "Closed tasks moved out of tasks.md by `tasks.py prune` — grouped by the",
    "month of the ✅/❌ stamp, original section in trailing parentheses.",
    "Append-only; grep it for accomplishment history.",
]

PRI_WORDS = {"🔺": "highest", "⏫": "high", "🔼": "medium", "🔽": "low", "⏬": "lowest"}
PRI_EMOJIS = {w: e for e, w in PRI_WORDS.items()}
PRI_RANK = {"🔺": 4, "⏫": 3, "🔼": 2, "🔽": 1, "⏬": 0}
STATUS_WORDS = {" ": "todo", "/": "in-progress", "x": "done", "-": "cancelled"}
WEEKDAYS = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}

FIELD_CHARS = "🔺⏫🔼🔽⏬🛫📅✅❌🔁"
TASK_RE = re.compile(r"^(\s*)([-*])\s+\[([ x/-])\]\s+(.*)$")
CHECKBOX_PROBE_RE = re.compile(r"^\s*[-*]\s*\[.{0,2}\]")
PRI_RE = re.compile("(?:^|(?<=\\s))([🔺⏫🔼🔽⏬])️?(?=\\s|$)")
REC_RE = re.compile("🔁️?\\s*([^#" + FIELD_CHARS + "]*)")
TAG_RE = re.compile(r"#[A-Za-z][\w/-]*")
HEADING_RE = re.compile(r"^##\s+(.+?)\s*$")
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _date_re(emoji: str) -> "re.Pattern[str]":
    return re.compile(emoji + "️?\\s*(\\d{4}-\\d{2}-\\d{2})")


SCHED_RE = _date_re("🛫")
DUE_RE = _date_re("📅")
DONE_RE = _date_re("✅")
CANCELLED_RE = _date_re("❌")


@dataclass(frozen=True)
class Recurrence:
    interval: int
    unit: str  # day | week | month | year
    weekday: Optional[int] = None  # 0=Mon .. 6=Sun
    monthday: Optional[int] = None  # 1..31, -1 = last
    weekdays_only: bool = False
    snap: bool = False  # "[N] weeks on <weekday>": +7N then forward-snap
    when_done: bool = False


@dataclass
class Task:
    raw: str
    line_no: int  # 1-based
    indent: str
    bullet: str
    status: str
    text: str
    priority: Optional[str]
    recurrence_raw: Optional[str]
    recurrence: Optional[Recurrence]
    scheduled: Optional[date]
    due: Optional[date]
    done_date: Optional[date]
    cancelled_date: Optional[date]
    tags: List[str]
    section: Optional[str]
    status_pos: int
    sched_span: Optional[Tuple[int, int]]
    due_span: Optional[Tuple[int, int]]


def parse_recurrence(raw: str) -> Optional[Recurrence]:
    text = " ".join(raw.strip().lower().split())
    when_done = False
    if text.endswith(" when done"):
        when_done = True
        text = text[: -len(" when done")].rstrip()
    m = re.match(r"^every\s+(.+)$", text)
    if not m:
        return None
    body = m.group(1)
    if body in ("weekday", "weekdays"):
        return Recurrence(1, "day", weekdays_only=True, when_done=when_done)
    if body in WEEKDAYS:
        return Recurrence(1, "week", weekday=WEEKDAYS[body], when_done=when_done)
    m = re.match(r"^(?:(\d+)\s+)?(day|week|month|year)s?(?:\s+on\s+(.+))?$", body)
    if not m:
        return None
    interval = int(m.group(1) or 1)
    if interval < 1:
        return None
    unit, rest = m.group(2), m.group(3)
    if rest is None:
        return Recurrence(interval, unit, when_done=when_done)
    if unit == "week":
        if rest not in WEEKDAYS:
            return None
        return Recurrence(interval, unit, weekday=WEEKDAYS[rest], snap=True,
                          when_done=when_done)
    if unit == "month":
        m2 = re.match(r"^the\s+(?:(\d{1,2})(?:st|nd|rd|th)|(last))$", rest)
        if not m2:
            return None
        monthday = -1 if m2.group(2) else int(m2.group(1))
        if monthday != -1 and not 1 <= monthday <= 31:
            return None
        return Recurrence(interval, unit, monthday=monthday, when_done=when_done)
    return None


def _add_months(base: date, months: int, monthday: Optional[int]) -> date:
    total = base.month - 1 + months
    year = base.year + total // 12
    month = total % 12 + 1
    last = calendar.monthrange(year, month)[1]
    if monthday is None:
        day = base.day
    elif monthday == -1:
        day = last
    else:
        day = monthday
    return date(year, month, min(day, last))


def next_due(rec: Recurrence, base: date) -> date:
    if rec.weekdays_only:
        d = base + timedelta(days=1)
        while d.weekday() >= 5:
            d += timedelta(days=1)
        return d
    if rec.unit == "day":
        return base + timedelta(days=rec.interval)
    if rec.unit == "week":
        if rec.weekday is None:
            return base + timedelta(weeks=rec.interval)
        if rec.snap:
            d = base + timedelta(weeks=rec.interval)
            return d + timedelta(days=(rec.weekday - d.weekday()) % 7)
        delta = (rec.weekday - base.weekday()) % 7
        return base + timedelta(days=delta or 7)
    if rec.unit == "month":
        return _add_months(base, rec.interval, rec.monthday)
    return _add_months(base, 12 * rec.interval, rec.monthday)


def parse_line(line: str, line_no: int,
               section: Optional[str]) -> Tuple[Optional[Task], Optional[str]]:
    m = TASK_RE.match(line)
    if not m:
        return None, None
    body = m.group(4)
    body_off = m.start(4)
    spans: List[Tuple[int, int]] = []

    pm = PRI_RE.search(body)
    priority = pm.group(1) if pm else None
    if pm:
        spans.append(pm.span())

    rm = REC_RE.search(body)
    recurrence_raw: Optional[str] = None
    if rm:
        recurrence_raw = " ".join(rm.group(1).split()) or None
        spans.append(rm.span())

    dates: Dict[str, Optional[date]] = {}
    date_spans: Dict[str, Tuple[int, int]] = {}
    for key, regex in (("scheduled", SCHED_RE), ("due", DUE_RE),
                       ("done", DONE_RE), ("cancelled", CANCELLED_RE)):
        dm = regex.search(body)
        if not dm:
            dates[key] = None
            continue
        try:
            dates[key] = date.fromisoformat(dm.group(1))
        except ValueError:
            return None, "invalid date '{}'".format(dm.group(1))
        spans.append(dm.span())
        date_spans[key] = (body_off + dm.start(1), body_off + dm.end(1))

    text = body
    for start, end in sorted(spans, reverse=True):
        text = text[:start] + " " + text[end:]
    text = " ".join(text.split())

    task = Task(
        raw=line,
        line_no=line_no,
        indent=m.group(1),
        bullet=m.group(2),
        status=m.group(3),
        text=text,
        priority=priority,
        recurrence_raw=recurrence_raw,
        recurrence=parse_recurrence(recurrence_raw) if recurrence_raw else None,
        scheduled=dates["scheduled"],
        due=dates["due"],
        done_date=dates["done"],
        cancelled_date=dates["cancelled"],
        tags=[t.lstrip("#") for t in TAG_RE.findall(text)],
        section=section,
        status_pos=m.start(3),
        sched_span=date_spans.get("scheduled"),
        due_span=date_spans.get("due"),
    )
    return task, None


def format_task(bullet: str, status: str, text: str, priority: Optional[str],
                recurrence_raw: Optional[str], scheduled: Optional[date],
                due: Optional[date], indent: str = "") -> str:
    parts = ["{}{} [{}] {}".format(indent, bullet, status, text)]
    if priority:
        parts.append(priority)
    if recurrence_raw:
        parts.append("🔁 " + recurrence_raw)
    if scheduled:
        parts.append("🛫 " + scheduled.isoformat())
    if due:
        parts.append("📅 " + due.isoformat())
    return " ".join(parts)


def _atomic_write(path: str, lines: List[str], trailing_newline: bool = True) -> None:
    content = "\n".join(lines) + ("\n" if trailing_newline else "")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=".tasks-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _find_heading(lines: List[str], name: str) -> Tuple[Optional[int], Optional[str]]:
    for i, line in enumerate(lines):
        hm = HEADING_RE.match(line)
        if hm and hm.group(1).lower() == name.lower():
            return i, hm.group(1)
    return None, None


def _section_end(lines: List[str], heading_idx: int) -> int:
    """Insertion point at the end of a section: before the next heading,
    behind any trailing blank lines."""
    insert_at = next((i for i in range(heading_idx + 1, len(lines))
                      if HEADING_RE.match(lines[i])), len(lines))
    while insert_at - 1 > heading_idx and not lines[insert_at - 1].strip():
        insert_at -= 1
    return insert_at


class TaskFile:
    def __init__(self, path: str):
        self.path = path
        with open(path, encoding="utf-8") as f:
            content = f.read()
        self.trailing_newline = content.endswith("\n")
        self.lines = content.split("\n")
        if self.trailing_newline:
            self.lines.pop()
        self.tasks: List[Task] = []
        self.parse_errors: List[Tuple[int, str, str]] = []
        section: Optional[str] = None
        for i, line in enumerate(self.lines, start=1):
            hm = HEADING_RE.match(line)
            if hm:
                section = hm.group(1)
                continue
            task, err = parse_line(line, i, section)
            if task:
                self.tasks.append(task)
            elif err:
                self.parse_errors.append((i, err, line.strip()))

    def write(self) -> None:
        _atomic_write(self.path, self.lines, self.trailing_newline)

    def headings(self) -> List[str]:
        return [HEADING_RE.match(l).group(1) for l in self.lines
                if HEADING_RE.match(l)]


def is_open(task: Task) -> bool:
    return task.status in (" ", "/")


def is_surfaced(task: Task, today: date) -> bool:
    if not is_open(task):
        return False
    if task.due and task.due <= today:
        return True
    return bool(task.scheduled and task.scheduled <= today)


def _sort_key(task: Task) -> Tuple[int, date, int]:
    rank = PRI_RANK.get(task.priority or "", -1)
    return (-rank, task.due or date.max, task.line_no)


def _grouped(tasks: List[Task], today: date) -> Dict[str, List[Task]]:
    groups: Dict[str, List[Task]] = {"overdue": [], "today": [], "lead": []}
    for t in tasks:
        if t.due and t.due < today:
            groups["overdue"].append(t)
        elif t.due == today:
            groups["today"].append(t)
        else:
            groups["lead"].append(t)
    for g in groups.values():
        g.sort(key=_sort_key)
    return groups


def _format_surfaced(task: Task, today: date) -> str:
    pri = " " + task.priority if task.priority else ""
    sec = " ({})".format(task.section) if task.section else ""
    if task.due and task.due < today:
        age = (today - task.due).days
        return "- {}{} — due {} ({}d overdue){}".format(
            task.text, pri, task.due, age, sec)
    if task.due == today:
        return "- {}{} — due {}{}".format(task.text, pri, task.due, sec)
    if task.due:
        return "- {}{} — due {} (in {}d){}".format(
            task.text, pri, task.due, (task.due - today).days, sec)
    return "- {}{} — scheduled {}{}".format(task.text, pri, task.scheduled, sec)


def _surfaced_block(tasks: List[Task], today: date,
                    cap: Optional[int] = None) -> str:
    groups = _grouped(tasks, today)
    titles = (("overdue", "Overdue:"), ("today", "Due today:"),
              ("lead", "Scheduled (lead-time to due):"))
    lines: List[str] = []
    shown = 0
    hidden = 0
    for key, title in titles:
        group = groups[key]
        if not group:
            continue
        emitted_title = False
        for t in group:
            if cap is not None and shown >= cap:
                hidden += 1
                continue
            if not emitted_title:
                lines.append(title)
                emitted_title = True
            lines.append(_format_surfaced(t, today))
            shown += 1
    if hidden:
        lines.append("…and {} more — tk -a".format(hidden))
    return "\n".join(lines)


def _require_file(path: str) -> Optional[int]:
    if os.path.exists(path):
        return None
    print("no tasks file at {}; {}".format(path, bootstrap_hint(path)), file=sys.stderr)
    return 1


def _resolve(tasks: List[Task], terms: List[str],
             line_no: Optional[int]) -> Tuple[Optional[Task], int]:
    open_tasks = [t for t in tasks if is_open(t)]
    if line_no is not None:
        for t in open_tasks:
            if t.line_no == line_no:
                return t, 0
        print("no open task at line {}".format(line_no), file=sys.stderr)
        return None, 1
    needle = " ".join(terms).strip().lower()
    if not needle:
        print("provide a match string or --line N", file=sys.stderr)
        return None, 1
    candidates = [t for t in open_tasks if needle in t.text.lower()]
    if not candidates:
        print("no open task matching '{}'".format(needle), file=sys.stderr)
        return None, 1
    if len(candidates) > 1:
        print("ambiguous match '{}' — candidates:".format(needle), file=sys.stderr)
        for t in candidates:
            print("  line {}: {}".format(t.line_no, t.text), file=sys.stderr)
        print("re-run with --line N", file=sys.stderr)
        return None, 2
    return candidates[0], 0


def _replace_span(raw: str, span: Tuple[int, int], value: str) -> str:
    return raw[: span[0]] + value + raw[span[1]:]


def _set_status(raw: str, status_pos: int, status: str) -> str:
    return raw[:status_pos] + status + raw[status_pos + 1:]


def _append_field(raw: str, field: str) -> str:
    end = len(raw.rstrip())
    return raw[:end] + " " + field + raw[end:]


def _spawn(task: Task, today: date) -> Tuple[str, Optional[str]]:
    rec = task.recurrence
    assert rec is not None
    warning = None
    if rec.when_done or (not task.due and not task.scheduled):
        base = today
        if not rec.when_done:
            warning = ("no reference date; based next occurrence on today "
                       "({})".format(today))
    else:
        base = task.due or task.scheduled  # type: ignore[assignment]
    new_due: Optional[date] = None
    new_sched: Optional[date] = None
    if task.due:
        new_due = next_due(rec, base)
        if task.scheduled:
            new_sched = new_due - (task.due - task.scheduled)
    elif task.scheduled:
        new_sched = next_due(rec, base)
    else:
        new_due = next_due(rec, base)
    line = format_task(task.bullet, " ", task.text, task.priority,
                       task.recurrence_raw, new_sched, new_due, task.indent)
    return line, warning


def cmd_list(args: argparse.Namespace, today: date) -> int:
    rc = _require_file(args.file)
    if rc:
        return rc
    tf = TaskFile(args.file)
    tasks = tf.tasks
    if args.section:
        tasks = [t for t in tasks
                 if (t.section or "").lower() == args.section.lower()]
        if not tasks and args.section.lower() not in [
                h.lower() for h in tf.headings()]:
            print("unknown section '{}'; available: {}".format(
                args.section, ", ".join(tf.headings())), file=sys.stderr)
            return 1
    if not args.all:
        tasks = [t for t in tasks if is_surfaced(t, today)]
    if args.json:
        print(json.dumps([_task_json(t, today) for t in tasks], indent=2))
        return 0
    if not args.all:
        block = _surfaced_block(tasks, today)
        print(block if block else "No tasks due.")
        return 0
    section = object()
    for t in tasks:
        if t.section != section:
            section = t.section
            print("## {}".format(section or "(no section)"))
        print("{:>5}  {}".format(t.line_no, t.raw.strip()))
    if not tasks:
        print("No tasks.")
    return 0


def _task_json(task: Task, today: date) -> Dict[str, object]:
    rec_display = None
    if task.recurrence_raw:
        rec_display = re.sub(r"\s+when done\s*$", "", task.recurrence_raw,
                             flags=re.IGNORECASE)
    overdue_days = None
    if is_open(task) and task.due and task.due < today:
        overdue_days = (today - task.due).days
    return {
        "line": task.line_no,
        "section": task.section,
        "status": STATUS_WORDS[task.status],
        "text": task.text,
        "priority": PRI_WORDS.get(task.priority or ""),
        "recurrence": rec_display,
        "when_done": bool(task.recurrence and task.recurrence.when_done),
        "scheduled": task.scheduled.isoformat() if task.scheduled else None,
        "due": task.due.isoformat() if task.due else None,
        "done": task.done_date.isoformat() if task.done_date else None,
        "cancelled": task.cancelled_date.isoformat() if task.cancelled_date else None,
        "tags": task.tags,
        "surfaced": is_surfaced(task, today),
        "overdue_days": overdue_days,
    }


def _parse_iso(value: str, what: str) -> Optional[date]:
    if not ISO_RE.match(value):
        print("{} must be YYYY-MM-DD, got '{}'".format(what, value),
              file=sys.stderr)
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        print("invalid {} '{}'".format(what, value), file=sys.stderr)
        return None


def cmd_add(args: argparse.Namespace, today: date) -> int:
    rc = _require_file(args.file)
    if rc:
        return rc
    due = sched = None
    if args.due:
        due = _parse_iso(args.due, "--due")
        if due is None:
            return 1
    if args.sched:
        sched = _parse_iso(args.sched, "--sched")
        if sched is None:
            return 1
    if sched and due and sched > due:
        print("--sched {} is after --due {}".format(sched, due), file=sys.stderr)
        return 1
    if args.every:
        if not (due or sched):
            print("--every requires --due or --sched", file=sys.stderr)
            return 1
        if parse_recurrence(args.every) is None:
            print("unparseable recurrence rule '{}'; supported rules: "
                  "see {}".format(args.every, SPEC),
                  file=sys.stderr)
            return 1
    priority = None
    if args.priority:
        priority = (args.priority if args.priority in PRI_WORDS
                    else PRI_EMOJIS.get(args.priority.lower()))
        if priority is None:
            print("priority must be one of: {} (or the emoji)".format(
                ", ".join(PRI_EMOJIS)), file=sys.stderr)
            return 1

    tf = TaskFile(args.file)
    heading_idx, section = _find_heading(tf.lines, args.section or "Inbox")
    if heading_idx is None:
        if args.section:
            print("unknown section '{}'; available: {}".format(
                args.section, ", ".join(tf.headings())), file=sys.stderr)
            return 1
        section = "Inbox"
        first_heading = next((i for i, l in enumerate(tf.lines)
                              if HEADING_RE.match(l)), len(tf.lines))
        tf.lines[first_heading:first_heading] = ["## Inbox", ""]
        heading_idx = first_heading
    insert_at = _section_end(tf.lines, heading_idx)
    line = format_task("-", " ", args.text, priority,
                       " ".join(args.every.split()) if args.every else None,
                       sched, due)
    tf.lines.insert(insert_at, line)
    tf.write()
    print("added to {}: {}".format(section, line))
    return 0


def _mark(args: argparse.Namespace, today: date, status: str,
          stamp_emoji: Optional[str]) -> int:
    rc = _require_file(args.file)
    if rc:
        return rc
    tf = TaskFile(args.file)
    task, rc = _resolve(tf.tasks, args.match, args.line)
    if task is None:
        return rc
    if status == "x" and task.recurrence_raw and task.recurrence is None:
        print("unparseable recurrence rule '{}'; fix the line (see "
              "{}) or remove the 🔁 field".format(
                  task.recurrence_raw, SPEC), file=sys.stderr)
        return 1
    raw = _set_status(task.raw, task.status_pos, status)
    if stamp_emoji:
        raw = _append_field(raw, "{} {}".format(stamp_emoji, today))
    tf.lines[task.line_no - 1] = raw
    if status == "x" and task.recurrence:
        spawn_line, warning = _spawn(task, today)
        if warning:
            print(warning, file=sys.stderr)
        tf.lines.insert(task.line_no - 1, spawn_line)
        tf.write()
        print("completed: {}".format(raw.strip()))
        print("next: {}".format(spawn_line.strip()))
        return 0
    tf.write()
    verb = {"x": "completed", "-": "cancelled", "/": "started"}[status]
    print("{}: {}".format(verb, raw.strip()))
    if status == "-" and task.recurrence_raw:
        print("note: recurrence chain ended — use done or defer to skip "
              "one occurrence")
    return 0


def cmd_done(args: argparse.Namespace, today: date) -> int:
    return _mark(args, today, "x", "✅")


def cmd_cancel(args: argparse.Namespace, today: date) -> int:
    return _mark(args, today, "-", "❌")


def cmd_start(args: argparse.Namespace, today: date) -> int:
    return _mark(args, today, "/", None)


def cmd_defer(args: argparse.Namespace, today: date) -> int:
    rc = _require_file(args.file)
    if rc:
        return rc
    if not args.args:
        print("usage: defer <match...> <YYYY-MM-DD>", file=sys.stderr)
        return 1
    new_date = _parse_iso(args.args[-1], "defer date")
    if new_date is None:
        return 1
    terms = args.args[:-1]
    tf = TaskFile(args.file)
    task, rc = _resolve(tf.tasks, terms, args.line)
    if task is None:
        return rc
    raw = task.raw
    if task.due:
        delta = new_date - task.due
        raw = _replace_span(raw, task.due_span, new_date.isoformat())
        if task.scheduled:
            raw = _replace_span(raw, task.sched_span,
                                (task.scheduled + delta).isoformat())
    elif task.scheduled:
        raw = _replace_span(raw, task.sched_span, new_date.isoformat())
    else:
        raw = _append_field(raw, "📅 {}".format(new_date))
    tf.lines[task.line_no - 1] = raw
    tf.write()
    print("deferred: {}".format(raw.strip()))
    return 0


def cmd_move(args: argparse.Namespace, today: date) -> int:
    rc = _require_file(args.file)
    if rc:
        return rc
    tf = TaskFile(args.file)
    task, rc = _resolve(tf.tasks, args.match, args.line)
    if task is None:
        return rc
    heading_idx, section = _find_heading(tf.lines, args.to)
    if heading_idx is None:
        if not args.create:
            print("unknown section '{}'; available: {} (--create to add it)".format(
                args.to, ", ".join(tf.headings())), file=sys.stderr)
            return 1
        section = args.to
        if tf.lines and tf.lines[-1].strip():
            tf.lines.append("")
        tf.lines.append("## " + section)
        heading_idx = len(tf.lines) - 1
    if (task.section or "").lower() == (section or "").lower():
        print("already in {}: {}".format(section, task.text))
        return 0
    del tf.lines[task.line_no - 1]
    if task.line_no - 1 < heading_idx:
        heading_idx -= 1
    tf.lines.insert(_section_end(tf.lines, heading_idx), task.raw)
    tf.write()
    print("moved to {}: {}".format(section, task.raw.strip()))
    return 0


def _archive_append(path: str, entries: List[Tuple[str, str]]) -> None:
    """entries: (YYYY-MM, raw task line) — appended under the month heading."""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            content = f.read()
        lines = content.split("\n")
        if content.endswith("\n"):
            lines.pop()
    else:
        lines = list(ARCHIVE_HEADER)
    for month, raw in entries:
        heading_idx, _ = _find_heading(lines, month)
        if heading_idx is None:
            if lines and lines[-1].strip():
                lines.append("")
            lines.append("## " + month)
            heading_idx = len(lines) - 1
        lines.insert(_section_end(lines, heading_idx), raw)
    _atomic_write(path, lines)


def cmd_prune(args: argparse.Namespace, today: date) -> int:
    rc = _require_file(args.file)
    if rc:
        return rc
    cutoff = today - timedelta(days=args.keep_days)
    archive_path = os.path.join(os.path.dirname(args.file) or ".",
                                ARCHIVE_BASENAME)
    tf = TaskFile(args.file)
    remove: List[Tuple[Task, date]] = []
    skipped: List[Task] = []
    for t in tf.tasks:
        if t.status not in ("x", "-"):
            continue
        stamp = t.done_date if t.status == "x" else t.cancelled_date
        if stamp is None:
            skipped.append(t)
        elif stamp < cutoff:
            remove.append((t, stamp))
    verb = "remove" if args.no_archive else "archive"
    if args.dry_run:
        for t, _ in remove:
            print("would {} line {}: {}".format(verb, t.line_no, t.raw.strip()))
        for t in skipped:
            print("skipped (no stamp) line {}: {}".format(t.line_no,
                                                          t.raw.strip()))
        print("{} to {}, {} kept (closed within {}d or unstamped)".format(
            len(remove), verb, len(skipped), args.keep_days))
        return 0
    if remove and not args.no_archive:
        entries = []
        for t, stamp in sorted(remove, key=lambda pair: (pair[1], pair[0].line_no)):
            raw = t.raw.strip()
            if t.section:
                raw += " ({})".format(t.section)
            entries.append(("{:04d}-{:02d}".format(stamp.year, stamp.month), raw))
        _archive_append(archive_path, entries)
    for t, _ in sorted(remove, key=lambda pair: pair[0].line_no, reverse=True):
        del tf.lines[t.line_no - 1]
    if remove:
        tf.write()
    dest = "" if args.no_archive else " → {}".format(archive_path)
    print("pruned {} closed task(s) older than {}d{}; {} unstamped kept".format(
        len(remove), args.keep_days, dest, len(skipped)))
    return 0


def cmd_check(args: argparse.Namespace, today: date) -> int:
    rc = _require_file(args.file)
    if rc:
        return rc
    tf = TaskFile(args.file)
    errors: List[str] = []
    warnings: List[str] = []
    for line_no, err, text in tf.parse_errors:
        errors.append("line {}: {}: {}".format(line_no, err, text))
    task_lines = {t.line_no for t in tf.tasks}
    error_lines = {n for n, _, _ in tf.parse_errors}
    for i, line in enumerate(tf.lines, start=1):
        if i in task_lines or i in error_lines:
            continue
        if CHECKBOX_PROBE_RE.match(line):
            errors.append("line {}: malformed checkbox: {}".format(
                i, line.strip()))
    seen: Dict[Tuple[Optional[str], str], int] = {}
    for t in tf.tasks:
        if t.recurrence_raw and t.recurrence is None:
            errors.append("line {}: unparseable recurrence rule '{}': {}".format(
                t.line_no, t.recurrence_raw, t.text))
        if t.status == "x" and t.done_date is None:
            warnings.append("line {}: done without ✅ stamp: {}".format(
                t.line_no, t.text))
        if t.scheduled and t.due and t.scheduled > t.due:
            warnings.append("line {}: 🛫 {} after 📅 {}: {}".format(
                t.line_no, t.scheduled, t.due, t.text))
        if is_open(t):
            key = (t.section, t.text.lower())
            if key in seen:
                warnings.append(
                    "line {}: duplicate of line {} in same section: {}".format(
                        t.line_no, seen[key], t.text))
            else:
                seen[key] = t.line_no
    for msg in errors:
        print("error: " + msg)
    for msg in warnings:
        print("warning: " + msg)
    if errors:
        return 1
    if not warnings:
        print("ok — {} task(s), no issues".format(len(tf.tasks)))
    return 0


def cmd_hook_context(args: argparse.Namespace, today: date) -> int:
    if not os.path.exists(args.file):
        return 0
    tf = TaskFile(args.file)
    surfaced = [t for t in tf.tasks if is_surfaced(t, today)]
    if not surfaced:
        return 0
    home = os.path.expanduser("~")
    display = args.file
    if display.startswith(home):
        display = "~" + display[len(home):].replace(os.sep, "/")
    header = "=== TASKS ({}) ===".format(display)
    block = "\n".join([
        header,
        _surfaced_block(surfaced, today, cap=20),
        sc_conf("tk.hook_footer", "Manage via tk."),
        "=" * len(header),
    ])
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": block,
    }}))
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                pass

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--file", default=default_file(),
                        help="tasks file (default: %(default)s)")
    common.add_argument("--today", metavar="YYYY-MM-DD",
                        help="override today's date (tests, backfill)")

    parser = argparse.ArgumentParser(
        prog="tasks.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("list", parents=[common],
                       help="surfaced tasks (default) or --all")
    p.add_argument("--all", action="store_true",
                   help="every task, every status, grouped by section")
    p.add_argument("--section", help="filter to one section")
    p.add_argument("--json", action="store_true", help="machine output")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("add", parents=[common], help="add a task")
    p.add_argument("text")
    p.add_argument("--due", metavar="YYYY-MM-DD")
    p.add_argument("--sched", metavar="YYYY-MM-DD")
    p.add_argument("--every", metavar="RULE",
                   help='recurrence, e.g. "every 2 weeks"')
    p.add_argument("--priority", metavar="P",
                   help="highest|high|medium|low|lowest or the emoji")
    p.add_argument("--section", metavar="S", help="target section (default Inbox)")
    p.set_defaults(func=cmd_add)

    for name, func, help_text in (
            ("done", cmd_done, "complete a task (spawns next recurrence)"),
            ("cancel", cmd_cancel, "cancel a task (ends a recurrence chain)"),
            ("start", cmd_start, "mark a task in progress")):
        p = sub.add_parser(name, parents=[common], help=help_text)
        p.add_argument("match", nargs="*", help="substring of the task text")
        p.add_argument("--line", type=int, metavar="N",
                       help="target by exact line number")
        p.set_defaults(func=func)

    p = sub.add_parser("defer", parents=[common],
                       help="move a task's dates: defer <match...> <date>")
    p.add_argument("args", nargs="+", metavar="MATCH... DATE")
    p.add_argument("--line", type=int, metavar="N")
    p.set_defaults(func=cmd_defer)

    p = sub.add_parser("move", parents=[common],
                       help="move a task to another section")
    p.add_argument("match", nargs="*", help="substring of the task text")
    p.add_argument("--to", required=True, metavar="S", help="target section")
    p.add_argument("--line", type=int, metavar="N",
                   help="target by exact line number")
    p.add_argument("--create", action="store_true",
                   help="create the section if missing")
    p.set_defaults(func=cmd_move)

    p = sub.add_parser("prune", parents=[common],
                       help="archive closed tasks older than --keep-days "
                            "to tasks_archive.md")
    p.add_argument("--keep-days", type=int, default=30, metavar="N")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-archive", action="store_true",
                   help="delete instead of archiving")
    p.set_defaults(func=cmd_prune)

    p = sub.add_parser("check", parents=[common], help="lint the tasks file")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("hook-context", parents=[common],
                       help="SessionStart hook JSON (silent when nothing due)")
    p.set_defaults(func=cmd_hook_context)

    args = parser.parse_args(argv)
    if args.today:
        today = _parse_iso(args.today, "--today")
        if today is None:
            return 1
    else:
        today = date.today()
    args.file = os.path.expanduser(args.file)
    return args.func(args, today)


if __name__ == "__main__":
    sys.exit(main())
