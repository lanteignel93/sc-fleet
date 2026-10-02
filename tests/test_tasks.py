#!/usr/bin/env python3
"""Test suite for lib/tasks.py — run: python tests/test_tasks.py"""

import io
import json
import os
import sys
import tempfile
import traceback
from contextlib import redirect_stderr, redirect_stdout
from datetime import date

sys.path.insert(0, os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "lib")))

import tasks  # noqa: E402

# never read the real ~/.config/sc-fleet: point at a path that holds no config
os.environ["SC_CONFIG_HOME"] = os.path.join(tempfile.gettempdir(), "sc-fleet-test-noconfig-%d" % os.getpid())

TODAY = "2026-07-06"  # a Monday

TEMPLATE = """# Work tasks

## Inbox

## Recurring

## Infra

## One-Time
"""


def run(argv, expect=0):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = tasks.main(argv)
    assert rc == expect, "argv={} rc={} expected={}\nstdout: {}\nstderr: {}".format(
        argv, rc, expect, out.getvalue(), err.getvalue())
    return out.getvalue(), err.getvalue()


def write_file(dirpath, content):
    path = os.path.join(dirpath, "tasks.md")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    return path


def read_file(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def rec(rule):
    r = tasks.parse_recurrence(rule)
    assert r is not None, "rule failed to parse: " + rule
    return r


def nd(rule, y, m, d):
    return tasks.next_due(rec(rule), date(y, m, d))


# --- recurrence date math ---

def test_every_day():
    assert nd("every day", 2026, 7, 6) == date(2026, 7, 7)
    assert nd("every 1 day", 2026, 7, 6) == date(2026, 7, 7)
    assert nd("every 3 days", 2026, 6, 9) == date(2026, 6, 12)


def test_every_weekday():
    assert nd("every weekday", 2026, 7, 3) == date(2026, 7, 6)  # Fri -> Mon
    assert nd("every weekday", 2026, 7, 1) == date(2026, 7, 2)  # Wed -> Thu
    assert nd("every weekday", 2026, 7, 5) == date(2026, 7, 6)  # Sun -> Mon


def test_every_week():
    assert nd("every week", 2026, 6, 26) == date(2026, 7, 3)
    assert nd("every 2 weeks", 2026, 6, 24) == date(2026, 7, 8)


def test_weeks_on_weekday_snap():
    assert nd("every 2 weeks on Friday", 2026, 7, 3) == date(2026, 7, 17)
    assert nd("every 2 weeks on friday", 2026, 7, 4) == date(2026, 7, 24)  # Sat base snaps forward


def test_bare_weekday():
    assert nd("every Friday", 2026, 7, 6) == date(2026, 7, 10)  # Mon -> this Fri
    assert nd("every friday", 2026, 7, 3) == date(2026, 7, 10)  # Fri -> next Fri


def test_every_month():
    assert nd("every month", 2026, 6, 26) == date(2026, 7, 26)
    assert nd("every month", 2026, 1, 31) == date(2026, 2, 28)  # clamp
    assert nd("every month", 2024, 1, 31) == date(2024, 2, 29)  # leap clamp
    assert nd("every 2 months", 2026, 5, 30) == date(2026, 7, 30)


def test_month_ordinals():
    assert nd("every month on the 1st", 2026, 7, 1) == date(2026, 8, 1)
    assert nd("every month on the 1st", 2026, 7, 15) == date(2026, 8, 1)  # re-pins
    assert nd("every month on the 31st", 2026, 1, 31) == date(2026, 2, 28)
    assert nd("every month on the 31st", 2026, 2, 28) == date(2026, 3, 31)  # un-sticks
    assert nd("every month on the last", 2026, 2, 28) == date(2026, 3, 31)


def test_every_year():
    assert nd("every year", 2026, 5, 30) == date(2027, 5, 30)
    assert nd("every year", 2024, 2, 29) == date(2025, 2, 28)
    assert nd("every 4 years", 2024, 2, 29) == date(2028, 2, 29)


def test_bad_rules():
    assert tasks.parse_recurrence("every 2 weekdays") is None
    assert tasks.parse_recurrence("every fortnight") is None
    assert tasks.parse_recurrence("everyday") is None
    assert tasks.parse_recurrence("every 0 days") is None
    assert tasks.parse_recurrence("every month on the 32nd") is None


def test_when_done_parses():
    r = rec("every 3 days when done")
    assert r.when_done and r.interval == 3 and r.unit == "day"


# --- done flows ---

def test_done_due_based_not_completion_based():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Recurring\n\n- [ ] Floss 🔁 every 3 days 📅 2026-06-09\n")
        out, _ = run(["done", "floss", "--file", path, "--today", "2026-07-05"])
        lines = read_file(path).splitlines()
        assert lines[2] == "- [ ] Floss 🔁 every 3 days 📅 2026-06-12", lines
        assert lines[3] == "- [x] Floss 🔁 every 3 days 📅 2026-06-09 ✅ 2026-07-05", lines
        assert "next:" in out


def test_done_when_done_bases_on_today():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Recurring\n\n- [ ] Floss 🔁 every 3 days when done 📅 2026-06-09\n")
        run(["done", "floss", "--file", path, "--today", "2026-07-05"])
        lines = read_file(path).splitlines()
        assert lines[2] == "- [ ] Floss 🔁 every 3 days when done 📅 2026-07-08", lines


def test_done_sched_offset_preserved():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(
            tmp, "## Recurring\n\n- [ ] Prep license renewal 🔁 every year 🛫 2026-12-01 📅 2026-12-15\n")
        run(["done", "license", "--file", path, "--today", "2026-12-15"])
        lines = read_file(path).splitlines()
        assert lines[2] == ("- [ ] Prep license renewal 🔁 every year "
                            "🛫 2027-12-01 📅 2027-12-15"), lines


def test_done_sched_only_recurrence():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Recurring\n\n- [ ] Water plants 🔁 every week 🛫 2026-07-01\n")
        run(["done", "water", "--file", path, "--today", TODAY])
        lines = read_file(path).splitlines()
        assert lines[2] == "- [ ] Water plants 🔁 every week 🛫 2026-07-08", lines
        assert "📅" not in lines[2]


def test_done_dateless_recurrence_warns():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Recurring\n\n- [ ] Clean humidifier 🔁 every week\n")
        _, err = run(["done", "humidifier", "--file", path, "--today", TODAY])
        assert "no reference date" in err
        lines = read_file(path).splitlines()
        assert lines[2] == "- [ ] Clean humidifier 🔁 every week 📅 2026-07-13", lines


def test_done_unparseable_rule_refuses():
    with tempfile.TemporaryDirectory() as tmp:
        content = "## Recurring\n\n- [ ] Weird 🔁 every fortnight 📅 2026-07-01\n"
        path = write_file(tmp, content)
        _, err = run(["done", "weird", "--file", path, "--today", TODAY], expect=1)
        assert "unparseable recurrence" in err
        assert read_file(path) == content  # untouched


def test_done_non_recurring_no_spawn():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## One-Time\n\n- [ ] Renew VPN cert 📅 2026-07-01\n")
        run(["done", "vpn", "--file", path, "--today", "2026-07-01"])
        lines = read_file(path).splitlines()
        assert len(lines) == 3, lines
        assert lines[2] == "- [x] Renew VPN cert 📅 2026-07-01 ✅ 2026-07-01", lines


def test_done_star_bullet_surgical():
    with tempfile.TemporaryDirectory() as tmp:
        orig = "* [ ] Talk to Alex 🔁 every 2 weeks 📅 2026-06-24"
        path = write_file(tmp, "## Recurring\n\n" + orig + "\n")
        run(["done", "alex", "--file", path, "--today", "2026-06-24"])
        lines = read_file(path).splitlines()
        assert lines[2] == "* [ ] Talk to Alex 🔁 every 2 weeks 📅 2026-07-08", lines
        assert lines[3] == orig.replace("* [ ]", "* [x]", 1) + " ✅ 2026-06-24", lines


def test_done_matching_and_ambiguity():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n- [ ] Review invoices A 📅 2026-07-06\n"
                               "- [ ] Review invoices B 📅 2026-07-06\n")
        _, err = run(["done", "review invoices", "--file", path, "--today", TODAY],
                     expect=2)
        assert "ambiguous" in err and "line 3" in err and "line 4" in err
        run(["done", "--line", "4", "--file", path, "--today", TODAY])
        assert "- [x] Review invoices B" in read_file(path)
        _, err = run(["done", "nonexistent", "--file", path, "--today", TODAY],
                     expect=1)
        assert "no open task matching" in err


def test_cancel_and_start():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Recurring\n\n- [ ] Rotate certs 🔁 every month 📅 2026-07-06\n"
                               "- [ ] Draft memo 📅 2026-07-06\n")
        out, _ = run(["cancel", "rotate", "--file", path, "--today", TODAY])
        assert "recurrence chain ended" in out
        lines = read_file(path).splitlines()
        assert lines[2] == ("- [-] Rotate certs 🔁 every month 📅 2026-07-06 "
                            "❌ 2026-07-06"), lines
        assert len(lines) == 4  # no spawn
        run(["start", "memo", "--file", path, "--today", TODAY])
        assert "- [/] Draft memo 📅 2026-07-06" in read_file(path)
        run(["done", "memo", "--file", path, "--today", TODAY])  # [/] is open
        assert "- [x] Draft memo" in read_file(path)


# --- parse / round-trip ---

def test_vault_line_roundtrip():
    line = "- [ ] Pay Rent 🔺 🔁 every month on the 1st 🛫 2026-08-01 📅 2026-08-01"
    task, err = tasks.parse_line(line, 1, "Finance")
    assert err is None
    assert task.text == "Pay Rent" and task.priority == "🔺"
    assert task.recurrence_raw == "every month on the 1st"
    assert task.scheduled == date(2026, 8, 1) and task.due == date(2026, 8, 1)
    rebuilt = tasks.format_task(task.bullet, task.status, task.text, task.priority,
                                task.recurrence_raw, task.scheduled, task.due)
    assert rebuilt == line, rebuilt


def test_tags_and_variation_selector():
    line = "- [ ] Benchmark fill model #project/fill-model 📅️ 2026-07-15"
    task, err = tasks.parse_line(line, 1, None)
    assert err is None
    assert task.tags == ["project/fill-model"]
    assert "#project/fill-model" in task.text
    assert task.due == date(2026, 7, 15)
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n" + line + "\n")
        run(["defer", "benchmark", "2026-07-20", "--file", path, "--today", TODAY])
        lines = read_file(path).splitlines()
        assert lines[2] == line.replace("2026-07-15", "2026-07-20"), lines


def test_statuses_parse_and_surface():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n- [/] In flight 📅 2026-07-06\n"
                               "- [x] Done one 📅 2026-07-01 ✅ 2026-07-01\n"
                               "- [-] Dropped 📅 2026-07-01 ❌ 2026-07-01\n")
        out, _ = run(["list", "--file", path, "--today", TODAY])
        assert "In flight" in out
        assert "Done one" not in out and "Dropped" not in out


def test_non_task_lines_pass_through():
    content = ("# Work tasks\n\nSome prose intro.\n\n> - [ ] quoted example 📅 2026-01-01\n\n"
               "## Inbox\n\n- plain bullet, not a task\n- [ ] Real task 📅 2026-07-06\n")
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, content)
        run(["done", "real task", "--file", path, "--today", TODAY])
        after = read_file(path).splitlines()
        before = content.splitlines()
        assert after[:9] == before[:9]  # everything above the task untouched
        assert after[9] == "- [x] Real task 📅 2026-07-06 ✅ 2026-07-06"


# --- surfacing / sorting / listing ---

def test_surfacing_rules():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n"
                               "- [ ] Overdue one 📅 2026-07-01\n"
                               "- [ ] Today one 📅 2026-07-06\n"
                               "- [ ] Lead one 🛫 2026-07-05 📅 2026-07-10\n"
                               "- [ ] Future due 📅 2026-07-10\n"
                               "- [ ] Future sched 🛫 2026-07-09 📅 2026-07-20\n"
                               "- [ ] Sched only past 🛫 2026-07-01\n")
        out, _ = run(["list", "--file", path, "--today", TODAY])
        assert "Overdue one" in out and "(5d overdue)" in out
        assert "Today one" in out
        assert "Lead one" in out and "(in 4d)" in out
        assert "Sched only past" in out and "scheduled 2026-07-01" in out
        assert "Future due" not in out and "Future sched" not in out
        assert out.index("Overdue:") < out.index("Due today:") < out.index("Scheduled")


def test_sort_priority_then_due():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n"
                               "- [ ] Plain old 📅 2026-06-20\n"
                               "- [ ] High one ⏫ 📅 2026-07-01\n"
                               "- [ ] Top one 🔺 📅 2026-07-02\n")
        out, _ = run(["list", "--file", path, "--today", TODAY])
        assert out.index("Top one") < out.index("High one") < out.index("Plain old")


def test_list_json_fields():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Infra\n\n"
                               "- [ ] Rotate certs ⏫ 🔁 every 3 months when done "
                               "#project/infra 🛫 2026-06-24 📅 2026-07-01\n")
        out, _ = run(["list", "--all", "--json", "--file", path, "--today", TODAY])
        data = json.loads(out)
        assert len(data) == 1
        t = data[0]
        assert t["section"] == "Infra" and t["status"] == "todo"
        assert t["priority"] == "high" and t["recurrence"] == "every 3 months"
        assert t["when_done"] is True and t["tags"] == ["project/infra"]
        assert t["due"] == "2026-07-01" and t["scheduled"] == "2026-06-24"
        assert t["surfaced"] is True and t["overdue_days"] == 5


def test_list_empty_and_missing():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, TEMPLATE)
        out, _ = run(["list", "--file", path, "--today", TODAY])
        assert "No tasks due." in out
        missing = os.path.join(tmp, "nope.md")
        _, err = run(["list", "--file", missing, "--today", TODAY], expect=1)
        assert "bootstrap" in err


# --- add ---

def test_add_placement_and_format():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, TEMPLATE)
        out, _ = run(["add", "Rotate certs", "--every", "every 3 months",
                      "--sched", "2026-09-24", "--due", "2026-10-01",
                      "--priority", "high", "--section", "Infra",
                      "--file", path, "--today", TODAY])
        assert "added to Infra" in out
        lines = read_file(path).splitlines()
        idx = lines.index("## Infra")
        assert lines[idx + 1] == ("- [ ] Rotate certs ⏫ 🔁 every 3 months "
                                  "🛫 2026-09-24 📅 2026-10-01"), lines
        run(["add", "Second infra item", "--section", "infra", "--file", path,
             "--today", TODAY])
        lines = read_file(path).splitlines()
        assert lines[idx + 2] == "- [ ] Second infra item", lines  # appended after first


def test_add_validation():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, TEMPLATE)
        _, err = run(["add", "X", "--section", "Nope", "--file", path,
                      "--today", TODAY], expect=1)
        assert "unknown section" in err and "Infra" in err
        _, err = run(["add", "X", "--every", "every week", "--file", path,
                      "--today", TODAY], expect=1)
        assert "--every requires" in err
        _, err = run(["add", "X", "--every", "every fortnight", "--due",
                      "2026-08-01", "--file", path, "--today", TODAY], expect=1)
        assert "unparseable recurrence" in err
        _, err = run(["add", "X", "--sched", "2026-08-02", "--due", "2026-08-01",
                      "--file", path, "--today", TODAY], expect=1)
        assert "after" in err
        missing = os.path.join(tmp, "nope.md")
        _, err = run(["add", "X", "--file", missing, "--today", TODAY], expect=1)
        assert "bootstrap" in err


def test_add_creates_inbox_when_absent():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "# Work tasks\n\n## Infra\n")
        run(["add", "Loose thought", "--file", path, "--today", TODAY])
        lines = read_file(path).splitlines()
        assert lines[2] == "## Inbox" and lines[3] == "- [ ] Loose thought", lines
        assert lines.index("## Inbox") < lines.index("## Infra")


# --- defer ---

def test_defer_shifts_window():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n- [ ] Prep review 🛫 2026-07-01 📅 2026-07-10\n"
                               "- [ ] No dates yet\n"
                               "- [ ] Sched only 🛫 2026-07-02\n")
        run(["defer", "prep review", "2026-07-17", "--file", path, "--today", TODAY])
        lines = read_file(path).splitlines()
        assert lines[2] == "- [ ] Prep review 🛫 2026-07-08 📅 2026-07-17", lines
        run(["defer", "no dates", "2026-07-09", "--file", path, "--today", TODAY])
        assert "- [ ] No dates yet 📅 2026-07-09" in read_file(path)
        run(["defer", "sched only", "2026-07-11", "--file", path, "--today", TODAY])
        assert "- [ ] Sched only 🛫 2026-07-11" in read_file(path)


# --- hook-context ---

def test_hook_context_json():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Infra\n\n- [ ] Rotate certs ⏫ 📅 2026-07-01\n")
        out, _ = run(["hook-context", "--file", path, "--today", TODAY])
        payload = json.loads(out)
        ctx = payload["hookSpecificOutput"]
        assert ctx["hookEventName"] == "SessionStart"
        assert "Rotate certs" in ctx["additionalContext"]
        assert "Overdue:" in ctx["additionalContext"]
        assert "Manage via tk." in ctx["additionalContext"]  # neutral footer; config sets the site's


def test_hook_context_silent_paths():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, TEMPLATE)
        out, err = run(["hook-context", "--file", path, "--today", TODAY])
        assert out == "" and err == ""
        missing = os.path.join(tmp, "nope.md")
        out, err = run(["hook-context", "--file", missing, "--today", TODAY])
        assert out == "" and err == ""


def test_hook_context_cap():
    body = "## Inbox\n\n" + "".join(
        "- [ ] Task number {} 📅 2026-07-06\n".format(i) for i in range(25))
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, body)
        out, _ = run(["hook-context", "--file", path, "--today", TODAY])
        ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
        assert "…and 5 more — tk -a" in ctx


# --- check / prune ---

def test_check_errors():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n"
                               "- [ ] Bad date 📅 2026-02-30\n"
                               "- [ ] Bad rule 🔁 every fortnight 📅 2026-07-01\n"
                               "-[ ] malformed checkbox\n")
        out, _ = run(["check", "--file", path, "--today", TODAY], expect=1)
        assert "invalid date '2026-02-30'" in out
        assert "unparseable recurrence rule 'every fortnight'" in out
        assert "malformed checkbox" in out


def test_check_warnings_ok_exit():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n"
                               "- [ ] Same thing 📅 2026-07-08\n"
                               "- [ ] Same thing 📅 2026-07-09\n"
                               "- [x] Finished but unstamped\n"
                               "- [ ] Window swapped 🛫 2026-07-10 📅 2026-07-08\n")
        out, _ = run(["check", "--file", path, "--today", TODAY], expect=0)
        assert "duplicate of line 3" in out
        assert "done without ✅ stamp" in out
        assert "after" in out and "warning:" in out


def test_check_clean():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n- [ ] Fine 📅 2026-07-08\n")
        out, _ = run(["check", "--file", path, "--today", TODAY])
        assert "ok — 1 task(s)" in out


def test_prune():
    content = ("## Inbox\n\n"
               "- [x] Old done ✅ 2026-05-01\n"
               "- [x] Recent done ✅ 2026-07-01\n"
               "- [x] Unstamped done\n"
               "- [-] Old cancelled ❌ 2026-04-01\n"
               "- [ ] Open task 📅 2026-07-08\n")
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, content)
        archive = os.path.join(tmp, "tasks_archive.md")
        out, _ = run(["prune", "--dry-run", "--file", path, "--today", TODAY])
        assert "2 to archive" in out and "skipped (no stamp)" in out
        assert read_file(path) == content  # dry-run writes nothing
        assert not os.path.exists(archive)
        out, _ = run(["prune", "--file", path, "--today", TODAY])
        assert "pruned 2" in out and "tasks_archive.md" in out
        after = read_file(path)
        assert "Old done" not in after and "Old cancelled" not in after
        assert "Recent done" in after and "Unstamped done" in after
        assert "Open task" in after
        arch = read_file(archive).splitlines()
        assert arch[0] == "# Task archive"
        assert "## 2026-04" in arch and "## 2026-05" in arch
        assert arch.index("## 2026-04") < arch.index("## 2026-05")  # stamp order
        assert "- [-] Old cancelled ❌ 2026-04-01 (Inbox)" in arch
        assert "- [x] Old done ✅ 2026-05-01 (Inbox)" in arch


def test_prune_archive_appends_to_existing_month():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Research\n\n"
                               "- [x] Study A #research ✅ 2026-05-02\n")
        archive = os.path.join(tmp, "tasks_archive.md")
        run(["prune", "--file", path, "--today", TODAY])
        path2 = write_file(tmp, "## Research\n\n"
                                "- [x] Study B #research ✅ 2026-05-20\n")
        run(["prune", "--file", path2, "--today", TODAY])
        arch = read_file(archive).splitlines()
        assert arch.count("## 2026-05") == 1
        a = arch.index("- [x] Study A #research ✅ 2026-05-02 (Research)")
        b = arch.index("- [x] Study B #research ✅ 2026-05-20 (Research)")
        assert arch.index("## 2026-05") < a < b


def test_prune_no_archive():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n- [x] Old done ✅ 2026-05-01\n")
        out, _ = run(["prune", "--no-archive", "--file", path, "--today", TODAY])
        assert "pruned 1" in out and "tasks_archive.md" not in out
        assert not os.path.exists(os.path.join(tmp, "tasks_archive.md"))
        assert "Old done" not in read_file(path)


# --- move ---

def test_move_between_sections():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n"
                               "- [ ] Rotate certs ⏫ 📅 2026-08-01\n"
                               "- [ ] Other thing 📅 2026-07-08\n\n"
                               "## Infra\n\n"
                               "- [ ] Existing infra item\n")
        out, _ = run(["move", "rotate certs", "--to", "Infra", "--file", path,
                      "--today", TODAY])
        assert "moved to Infra" in out
        lines = read_file(path).splitlines()
        infra = lines.index("## Infra")
        assert lines[infra + 2] == "- [ ] Existing infra item", lines
        assert lines[infra + 3] == "- [ ] Rotate certs ⏫ 📅 2026-08-01", lines
        assert lines.index("- [ ] Other thing 📅 2026-07-08") < infra
        # case-insensitive section match, no-op when already there
        out, _ = run(["move", "rotate certs", "--to", "infra", "--file", path,
                      "--today", TODAY])
        assert "already in Infra" in out


def test_move_unknown_and_create():
    with tempfile.TemporaryDirectory() as tmp:
        path = write_file(tmp, "## Inbox\n\n- [ ] Deep dive #research 📅 2026-07-20\n")
        _, err = run(["move", "deep dive", "--to", "Research", "--file", path,
                      "--today", TODAY], expect=1)
        assert "unknown section" in err and "--create" in err
        out, _ = run(["move", "deep dive", "--to", "Research", "--create",
                      "--file", path, "--today", TODAY])
        assert "moved to Research" in out
        lines = read_file(path).splitlines()
        r = lines.index("## Research")
        assert lines[r + 1] == "- [ ] Deep dive #research 📅 2026-07-20", lines
        assert lines.index("## Inbox") < r
        run(["check", "--file", path, "--today", TODAY])


# --- config: the default board and the hook footer ---

def _with_conf(text, fn):
    old = {k: os.environ.get(k) for k in ("SC_CONFIG_HOME", "TK_STORE")}
    with tempfile.TemporaryDirectory() as d:
        os.environ["SC_CONFIG_HOME"] = d
        os.environ.pop("TK_STORE", None)
        with open(os.path.join(d, "config"), "w", encoding="utf-8") as f:
            f.write(text)
        try:
            return fn(d)
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


def test_default_file_follows_notes():
    with tempfile.TemporaryDirectory() as top:
        notes = os.path.join(top, "notes")
        _with_conf("notes=%s\n" % notes,
                   lambda d: _assert_eq(tasks.default_file(), os.path.join(notes, "tasks.md")))
        store = os.path.join(top, "store")
        _with_conf("notes=%s\ntk.store=%s\n" % (notes, store),
                   lambda d: _assert_eq(tasks.default_file(), os.path.join(store, "tasks.md")))


def test_default_file_tk_store_wins():
    def body(d):
        os.environ["TK_STORE"] = "/tk/store"
        _assert_eq(tasks.default_file(), "/tk/store/tasks.md")
    _with_conf("notes=/from/config\n", body)


def test_default_file_neutral():
    _with_conf("", lambda d: _assert_eq(
        tasks.default_file(), os.path.join(os.path.expanduser("~"), "notes", "tasks.md")))


def test_hook_footer_from_config():
    def body(d):
        with tempfile.TemporaryDirectory() as td:
            path = write_file(td, "# Work tasks\n\n## Inbox\n- [ ] due one 📅 2026-07-06\n")
            out, _ = run(["hook-context", "--file", path, "--today", TODAY])
            assert "Manage via the custom footer." in out, out
    _with_conf("tk.hook_footer=Manage via the custom footer.\n", body)


def test_hook_footer_neutral():
    def body(d):
        with tempfile.TemporaryDirectory() as td:
            path = write_file(td, "# Work tasks\n\n## Inbox\n- [ ] due one 📅 2026-07-06\n")
            out, _ = run(["hook-context", "--file", path, "--today", TODAY])
            assert "Manage via tk." in out, out
    _with_conf("", body)


def test_bootstrap_hint_names_the_board():
    hint = tasks.bootstrap_hint("/nowhere/notes/tasks.md")
    assert "/nowhere/notes/tasks.md" in hint, hint
    assert hint.startswith("bootstrap: "), hint


def _assert_eq(got, want):
    assert got == want, "got {!r} want {!r}".format(got, want)


def main():
    fns = [(name, fn) for name, fn in sorted(globals().items())
           if name.startswith("test_") and callable(fn)]
    failures = 0
    for name, fn in fns:
        try:
            fn()
            print("PASS  " + name)
        except Exception:
            failures += 1
            print("FAIL  " + name)
            traceback.print_exc()
    print("\n{} passed, {} failed, {} total".format(
        len(fns) - failures, failures, len(fns)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
