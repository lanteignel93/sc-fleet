# Task board grammar

The task board is one Markdown file of checkbox lines in the
[Obsidian Tasks](https://github.com/obsidian-tasks-group/obsidian-tasks) emoji
grammar, so the same file also renders as tasks if it is opened in Obsidian.
`tk` is the command-line surface; `lib/tasks.py` is the engine that implements
this spec, and its error messages point here. `tk` holds no task logic: it
renames two verbs, passes every flag to the engine untouched and prints a band
after a state change succeeds. `man tk` is the command reference.

## Where the board lives

The board is `<store>/tasks.md`. The store directory is resolved in this order:

1. the `TK_STORE` environment variable;
2. the config key `tk.store`;
3. the config key `notes`;
4. `~/notes`.

Config is `~/.config/sc-fleet/config`, with a per-machine `config.local` beside
it that wins (`SC_CONFIG_HOME`, or `XDG_CONFIG_HOME`, moves the directory). Lines
are `tool.key=value`; the file is read, never sourced, and only `~/`, `$HOME` and
`$USER` are expanded. `tk path` prints the resolved board path. Every engine verb
also takes `--file PATH` to point at another board.

`prune` writes `tasks_archive.md` in the same directory as the board.

With no board, every verb except `hook-context` refuses (exit 1) and prints a
bootstrap line. The starter board ships in the sc-fleet checkout:

```sh
mkdir -p ~/notes && cp <sc-fleet>/examples/tasks.md ~/notes/tasks.md
```

No board means no surfacing: opting in is deliberate. Nothing in the fleet
commits the board; if you want it on more than one machine, see
[Limitations](#limitations).

## Line grammar

```text
- [ ] <text> [priority] [🔁 <rule>] [🛫 YYYY-MM-DD] [📅 YYYY-MM-DD]
```

One example per shape:

```text
- [ ] Rotate the staging TLS certificates ⏫ 🔁 every 3 months 🛫 2026-09-24 📅 2026-10-01
- [ ] Reconcile the vendor invoices 🔺 🔁 every month on the 1st 📅 2026-11-01
- [ ] Benchmark the new parser #project/parser 📅 2026-10-15
- [/] Write the migration notes 📅 2026-10-08
- [x] Renew the VPN certificate 📅 2026-07-01 ✅ 2026-07-01
- [-] Evaluate the old queue library ❌ 2026-09-12
```

### Statuses

| Box   | Status      | State  | Stamp written by the tool |
|-------|-------------|--------|---------------------------|
| `[ ]` | todo        | open   |                           |
| `[/]` | in progress | open   |                           |
| `[x]` | done        | closed | `✅ YYYY-MM-DD`           |
| `[-]` | cancelled   | closed | `❌ YYYY-MM-DD`           |

The done marker is a lowercase `x`. `[X]` is not a status; `check` reports it as
a malformed checkbox.

### Priority

| Emoji | Word      |
|-------|-----------|
| 🔺    | highest   |
| ⏫    | high      |
| 🔼    | medium    |
| 🔽    | low       |
| ⏬    | lowest    |

`--priority` takes the word or the emoji; JSON output uses the word. A task with
no priority sorts below `lowest`.

### Fields

| Field          | Meaning                                                    | Set by                |
|----------------|------------------------------------------------------------|-----------------------|
| `🔁 <rule>`    | recurrence rule, optionally ending in `when done`          | hand, or `--every`    |
| `🛫 YYYY-MM-DD` | scheduled: lead time, the day the task starts surfacing   | hand, or `--sched`    |
| `📅 YYYY-MM-DD` | due                                                       | hand, or `--due`      |
| `✅ YYYY-MM-DD` | done stamp                                                | `done` only           |
| `❌ YYYY-MM-DD` | cancelled stamp                                           | `cancel` only         |

Do not hand-author the stamps. `prune` reads them, and `done` is what keeps the
recurrence maths deterministic.

### Parsing rules

- A task line is: optional indentation, a bullet (`-` or `*`), whitespace, the
  box, whitespace, the body. Indented (nested) tasks are tasks too. A missing
  space after the bullet (`-[ ]`), an empty box (`[]`) or an unknown status
  character makes a malformed checkbox.
- Fields are found anywhere in the body. The task's *text* is what remains once
  they are removed, with whitespace collapsed; matching works on the text.
- Each field counts once: the first occurrence wins.
- An emoji may carry the U+FE0F variation selector; both forms parse.
- A priority emoji must stand alone, with whitespace (or the line edge) on both
  sides.
- A date field is the emoji, optional whitespace, then `YYYY-MM-DD`. An
  impossible date such as `2026-02-30` is an error.
- A `🔁` rule runs from the emoji to the next `#`, the next field emoji, or the
  end of the line. Free text after a rule becomes part of the rule and breaks
  it, so write the text first and the fields after it.
- Tags (`#` followed by a letter, then letters, digits, `_`, `/` or `-`) belong
  to the text and are never treated as fields: `#project/parser`, `#ops`. A tag
  ends a `🔁` rule, so put tags before the fields, not inside the rule.

### How the engine writes lines

New lines (`add`, and the next occurrence of a recurring task) are emitted in
canonical order: text, priority, `🔁`, `🛫`, `📅`, with a `-` bullet for `add`.
Changes to an existing line are made in place and keep the line's own order:
the status character is replaced, a stamp is appended at the end, `defer`
rewrites the dates where they sit. Because the next occurrence is rebuilt from
the parsed text, a tag that sat among the fields moves into the text on the new
line.

## Sections

- A section is a level-two heading, `## Name`. A `#` title or a `###` heading
  does not start a section: tasks under a `###` belong to the enclosing `##`.
  Tasks above the first `##` have no section and list as `(no section)`.
- Section names are compared case-insensitively.
- The engine gives no meaning to section names except one: `add` without
  `--section` appends to `## Inbox`, and creates that heading just before the
  first `##` if it is missing.
- `add --section S` and `move --to S` refuse a section that does not exist and
  list the ones that do. `move --create` appends a new `## S` at the end of the
  file.
- A task added or moved into a section lands at the end of it, above any
  trailing blank lines.

### Routing

The engine does not classify tasks. Whoever adds a task picks its section at
write time: a person passing `--section`, or an agent that interprets the
request and chooses one. Inbox is for what genuinely does not fit anywhere, not
the default resting place. Triage is reading Inbox and running `tk move` on
each item.

Sections are yours: rename, add and reorder them by hand, then run `tk doctor`.
The starter board (`examples/tasks.md`) begins with Inbox, Recurring, Projects,
Infra, Admin, One-Time and Backlog.

## Recurrence

Rules are case-insensitive and whitespace is collapsed. Weekday names are full
English names (`friday`, not `fri`). The interval is a whole number of at least 1.

| Rule                                      | Next occurrence, from the reference date               |
|-------------------------------------------|--------------------------------------------------------|
| `every day`, `every N days`               | `every 3 days`: 06-09 becomes 06-12                    |
| `every weekday` (or `every weekdays`)     | the next Monday to Friday: Fri becomes Mon             |
| `every week`, `every N weeks`             | `every 2 weeks`: 06-24 becomes 07-08                   |
| `every <weekday>`                         | the next such weekday strictly after the reference     |
| `every N weeks on <weekday>`              | add 7N days, then move forward to that weekday         |
| `every month`, `every N months`           | same day of the month, clamped at the month's end      |
| `every [N] month[s] on the 15th`          | pins the day (1st to 31st), clamped in short months    |
| `every [N] month[s] on the last`          | the last day of the month                              |
| `every year`, `every N years`             | same date; Feb 29 clamps to Feb 28                     |
| any rule followed by ` when done`         | counts from the completion day instead                 |

Not supported: abbreviations, `every other ...`, `fortnight`, and `on ...` with
days or years.

### Semantics

- **Completing spawns the next occurrence.** `done` on a recurring task marks
  it `[x]` with a `✅` stamp and inserts the next occurrence directly above it: a
  fresh `[ ]` line with the same text, priority, rule, bullet and indentation.
- **Due-based by default.** The reference date is the task's `📅`, or its `🛫`
  when it has no `📅`. A task done late still recurs on its schedule, not from
  the day it was finished. Append `when done` for chores measured from the last
  time they were done: `every 3 days when done 📅 2026-09-01`, completed on
  2026-10-02, comes back due 2026-10-05.
- **`🛫` keeps its offset.** With both dates, the new `📅` is computed and the
  new `🛫` keeps the same lead time:
  `🔁 every year 🛫 2026-12-01 📅 2026-12-15` spawns
  `🛫 2027-12-01 📅 2027-12-15`. With only one of the two, that one advances.
- **Month-end drift.** Plain `every month` from Jan 31 clamps to Feb 28 and then
  *stays* on the 28th, because each line is recomputed from its own date with no
  memory of the original. If you mean the month's end, write `on the last`. If
  you mean the 31st wherever it exists, write `on the 31st`: it clamps to Feb 28
  and returns to Mar 31. `every year` from Feb 29 drifts the same way.
- **`every friday` is not `every week on friday`.** From Monday 2026-09-28,
  `every friday` gives Friday 2026-10-02 (the next Friday), while
  `every week on friday` adds seven days first and gives Friday 2026-10-09. From
  a Friday, both give the following Friday.
- **Dateless rules** (`🔁` with neither `🛫` nor `📅`) spawn from today, with a
  warning, and the new line gets a `📅`. The chain survives, but give it a date.
- **Unparseable rules refuse to complete.** `done` exits 1 rather than silently
  ending the chain; fix the rule or remove the `🔁` field. `start` and `cancel`
  still work on such a line. `check` finds bad rules before you trip on them,
  and `add --every` validates the rule up front (and requires `--due` or
  `--sched`).
- **`cancel` ends a chain.** It never spawns. To skip one occurrence, `done` it
  (which spawns the next) or `defer` it.

## Surfacing

A task *surfaces* when it is open (`[ ]` or `[/]`) and its `📅` or its `🛫` is
today or earlier. `🛫` is lead time: set it days or weeks before `📅` and the
task appears early, counting down to its due date. An open task with no dates
never surfaces, in progress or not; `tk -a` shows the whole board.

`tk` (or `tk ls`) prints the surfaced tasks in three groups:

1. Overdue: `📅` before today, with the number of days overdue.
2. Due today.
3. Scheduled: `🛫` reached, `📅` later or absent, with the days left to due.

Within a group, tasks sort by priority (highest first, none last), then by
earliest `📅`, then by position in the file. Each line also names its section.

"Today" is the machine's local date. Every verb takes `--today YYYY-MM-DD` to
override it, for backfilling ("I actually did this yesterday") and for tests.

## Operations

| You want                 | `tk`                                    | Engine verb          |
|--------------------------|-----------------------------------------|----------------------|
| what is due              | `tk` or `tk ls`                         | `list`               |
| the whole board          | `tk -a`                                 | `list --all`         |
| one section              | `tk ls --section S`                     | `list --section S`   |
| machine-readable         | `tk ls --json`                          | `list --json`        |
| capture                  | `tk new "text" [flags]`                 | `add`                |
| mark in progress         | `tk start <match>`                      | `start`              |
| complete                 | `tk done <match>`                       | `done`               |
| kill a task or a chain   | `tk cancel <match>`                     | `cancel`             |
| push back                | `tk defer <match> YYYY-MM-DD`           | `defer`              |
| refile                   | `tk move <match> --to S [--create]`     | `move`               |
| tidy                     | `tk prune [--keep-days N] [--dry-run]`  | `prune`              |
| lint                     | `tk doctor`                             | `check`              |
| where is the board       | `tk path`                               |                      |

`new` and `doctor` are the fleet's names for the engine's `add` and `check`;
`tk` accepts both spellings. `tk -a` is the fleet spelling of `--all`.

**Matching.** `<match>` is a case-insensitive substring of the task text
(fields removed, tags kept), searched among open tasks only; closed tasks
cannot be targeted. No match exits 1. More than one match exits 2 and lists the
candidates with their line numbers: re-run with `--line N` (line numbers are in
`tk -a`).

**`new` / `add`.** Flags: `--due`, `--sched` (both strictly `YYYY-MM-DD`; a
`--sched` later than `--due` is refused), `--every RULE`, `--priority P`,
`--section S` (default Inbox).

```sh
tk new "Rotate the staging TLS certificates" --every "every 3 months" \
    --sched 2026-12-18 --due 2027-01-01 --priority high --section Recurring
```

**`defer`.** The last argument is the new date. A task with `📅` gets that `📅`,
and its `🛫` (if any) moves by the same number of days. A task with only `🛫`
gets that `🛫`. A task with neither gains `📅` on that date.

```text
- [ ] Draft the release notes 🛫 2026-09-25 📅 2026-10-01
tk defer "release notes" 2026-10-11
- [ ] Draft the release notes 🛫 2026-10-05 📅 2026-10-11
```

**`start`** marks `[/]` and stamps nothing. **`done`** and **`cancel`** stamp
today's date, or the `--today` date.

State changes go through the tool. Rewording a task and reorganizing sections
by hand is fine; run `tk doctor` afterwards.

### JSON

`tk ls --json` prints an array of objects, one per task: surfaced tasks by
default, every task with `-a`.

| Key            | Value                                                       |
|----------------|-------------------------------------------------------------|
| `line`         | 1-based line number                                         |
| `section`      | section name, or `null`                                     |
| `status`       | `todo`, `in-progress`, `done` or `cancelled`                |
| `text`         | the text, fields removed                                    |
| `priority`     | the priority word, or `null`                                |
| `recurrence`   | the rule without its `when done` suffix, or `null`          |
| `when_done`    | `true` when the rule ends in `when done`                    |
| `scheduled`, `due`, `done`, `cancelled` | ISO dates, or `null`               |
| `tags`         | tags without the `#`                                        |
| `surfaced`     | whether the task surfaces today                             |
| `overdue_days` | days past `📅` for an open overdue task, else `null`        |

## Archive and prune

Completed and cancelled lines stay where they are until `prune` moves them.

`prune` takes closed tasks whose stamp (`✅` for done, `❌` for cancelled) is
older than `--keep-days` days (default 30) and appends them to
`tasks_archive.md` beside the board. It reads stamps, not sections: a closed
line is archived wherever it sits. A closed line with no stamp is kept and
reported, never guessed at.

The archive is plain Markdown, append-only and tool-written. It is created with
a short header on the first prune; entries go under a `## YYYY-MM` heading for
the month of their stamp, verbatim apart from leading indentation, with the
source section in trailing parentheses:

```text
## 2026-08
- [x] Reconcile the vendor invoices ✅ 2026-08-01 (Admin)
- [-] Evaluate the old queue library ❌ 2026-08-15 (Backlog)
```

`--dry-run` lists what would move and changes nothing. The engine's
`--no-archive` deletes instead of archiving; do not make it a habit.

History questions ("which Infra tasks did I finish in the last two months?")
are a grep over the archive plus the closed lines still on the board, filtered
by month heading, section or tag.

An optional convention: a `## Finished` section at the bottom of the board, so
open work reads first. Move closed lines there by hand (`tk move` targets open
tasks only); `prune` drains the section as its lines age.

## What `check` validates

`tk doctor` (the engine's `check`) is read-only.

Errors (exit 1):

- an impossible date in a `🛫`, `📅`, `✅` or `❌` field;
- a malformed checkbox: a line that starts like a checkbox but does not parse
  as a task (`[X]`, `[]`, `-[ ]`, an unknown status character);
- a recurrence rule that does not parse.

Warnings (exit 0):

- `[x]` without a `✅` stamp (prune will never archive it);
- `🛫` later than `📅`;
- an open task whose text repeats another open task in the same section,
  compared case-insensitively.

A clean board prints `ok` and the task count. A `[-]` line without `❌` is not
flagged, but prune keeps it.

## Agents

An agent can use the board through the engine directly. `tasks.py list --json`
is the structured read. `tasks.py hook-context` prints the JSON a Claude Code
`SessionStart` hook returns: its `additionalContext` is a block headed by the
board's path, listing the surfaced tasks (as `tk ls` groups them, capped at 20
with a count of the rest), and closed by a footer line taken from the config
key `tk.hook_footer` (default `Manage via tk.`). It prints nothing and exits 0
when the board is missing or nothing is surfaced, so it is safe to wire
unconditionally:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
                     "command": "python3 <sc-fleet>/lib/tasks.py hook-context" } ] }
    ]
  }
}
```

## Scope

The board is for single, dated next actions. Multi-step work belongs in a plan
or a topic note (see [wt-layout.md](wt-layout.md)); promote one of its steps to
a task when it needs a date. Undated someday ideas belong in a list of their
own, not as dateless tasks that never surface.

## Limitations

- **Per machine.** The board is a local file. Completing a task on one machine
  does not mark it done on another. Work from one machine, or keep the store in
  a git repository and sync it.
- **No locking.** Concurrent writers are last-writer-wins. Writes are atomic
  (temporary file, then rename), so the file never tears, but two simultaneous
  state changes can lose one.
- **No code-fence tracking.** The parser does not know about fences: a
  task-shaped line inside a code block in the board is a real task. Keep
  examples out of the board.
