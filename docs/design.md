# Design notes

Why sc-fleet is shaped the way it is, one decision per section: the decision,
why, and what it rules out. The tools left a private config repo with a fresh
history; this keeps the rationale from its decision log. Behaviour is in the
man pages, [configuration.md](configuration.md) and [members.md](members.md).

## No site facts in tool source

The tools carry no hostnames, mounts, internal addresses, organisation names
or user names. Site facts arrive as data (fleet config, rig roster, env var)
with a neutral default, and tools probe for what a box has.

Why: the fleet was always meant to be public, and the rule came long before
the move so that extraction would be a filter of paths, not archaeology. A
rule that is only a habit does not survive, so the leak gate enforces it.

Rules out: per-site branches, tables of known boxes, single-site defaults.

## Membership is a marker, not a manifest

A tool is a member when it sits beside `sc`, is executable, carries a line
starting `# sc-fleet` and answers the hidden `__id` verb. The `sc` roster and
the `install.sh` link manifest are both derived from that marker.

Why: lists drift. A repo puller brought new commits to every box but never
re-ran the link installer, so a new link entry landed only where it was
written. Deriving the manifest killed the class: adding `arm`, then `crew`,
each produced a correct `MISSING` line with no installer edit. The marker is
read before anything runs, so `sc` never executes a neighbour to ask what it
is. The kit (`lib/sckit.sh`) is sourced inside a conditional with fallbacks,
so one tool copied alone to a bare box still runs.

Rules out: a registration file, an installer edited per tool, and a hard
dependency on the kit. Orphan links are reported, never deleted.

## One config reader; site facts are keys with neutral defaults

`lib/scconf.sh` and its twin `sc_conf()` in `lib/tasks.py` read `config` and
`config.local` under `$SC_CONFIG_HOME` (default `~/.config/sc-fleet`):
`tool.key=value` lines, the roster's grammar, read and never sourced, with
only `~/`, `$HOME` and `$USER` expanded as text. Every site decision is a key
(`wt.root`, `notes`, `wt.forge`, `tk.store`, the rig installers, and so on).
`sc config [KEY]` shows each value and the file that set it.

Why: site facts needed a home that is data, not code; a value like `$(...)`
stays text. `config.local` beats `config`, and an env var a tool already
honoured (`WT_ROOT`, `TK_STORE`) beats both. The engine keeps its own reader
because it is stdlib-only Python; `test_conf.sh` asserts the twins agree.
`wt.forge` is a list of `<glob> <kind>` rules tried before the built-in public
forges, so a site's forge host lives only in its config. With no safe default
a tool refuses and names the key. The cut-over was checked old against new
under the private config: same forge detection, roots, store and board.

Rules out: config that executes, a config file per tool, Python shelling out
to bash, and guessing a forge from a hostname.

## The leak gate: generic classes built in, site names kept private

`tools/leakgate.py` refuses generic leaks itself (addresses, e-mail, hosts,
home paths, binaries) and site names only through a regex deny list outside
the repo, at `~/.config/sc-fleet/leakgate.deny`; `--strict` fails without it.
The git hooks run it on staged content, the commit message, and before a push
on all history, next to gitleaks for credentials.

Why: the first enforcement was a grep inside a test file, which then carried
the strings it guarded. Names a public repo must never carry cannot live in
it, so the site's own installer links the list into place. Strict mode makes
the safe failure the default: a clone without the list cannot commit at all,
rather than commit with half a check.

Rules out: shipping the deny list, and exempting a deny match (the
`leakgate: allow` pragma covers only the generic classes).

## fleet.zsh: the shell surface ships with the tools

The shell functions (`wt`, `sc`, `arm`) and completion wiring live in
`shell/fleet.zsh`; `.zshrc` sources it with one line, via a stable link.

Why: a function and its completion must version with the tool. While they
lived in an rc file, a completion shipped to one box by hand and stranded
there. The file is idempotent by contract because `arm` re-sources it: `fpath`
is filtered before it is extended, and `PATH` is never touched.

Rules out: a line per tool in the rc, and re-sourcing the whole rc (an
oh-my-zsh rc with a powerlevel10k instant prompt is not safe twice).

## arm: re-arm running shells

`arm` brings running shells up to the current `fleet.zsh`. Bare `arm` is a zsh
function that re-sources it in place; the binary sweeps tmux panes.

Why: a shell keeps the functions it started with. Seven of eight live panes
once lacked a function landed the day before, and the history showed
`exec zsh` seven times in a week. A child cannot change its parent shell (the
`wt cd` wall), so the bare verb is a function. The sweep sends `source <path>`,
never a typed command: with zsh autocorrect on, near a `src` directory, the
word `sc` raises a `correct 'sc' to 'src'` prompt that eats the next keys.

Rules out: typing commands into other panes, and `exec zsh` by default.

## wt: one worktree per topic

Worktree flow is one deterministic bash tool that humans and agents call the
same way; an agent's topic command only adds judgment (goal, PR evidence).

Why: a procedure the model executes step by step was non-deterministic,
token-costly and unusable from a shell; a "finish topic" command proved to be
two lines of per-repo convention. Checkouts are siblings under `src/<repo>/`,
`main` owning `.git`: symmetric, and unlike a flat `src/<slug>` it survives
sibling repos and slashed branch names. Per-repo conventions live in a durable
git store, not on purge-prone disk. `wt pr` squashes by default and pushes
`--force-with-lease`; `wt rm` asks the forge whether the PR merged, as a
squash-merge rewrites the SHA. A local agent settings file at the main
checkout covers every worktree, so interpreter allows are written there once,
only behind `allow_interp=true` or `--mine`.

Rules out: model-executed git procedures, and per-worktree permission files.

## rig: git is the transport, every box a replica

Each box reconciles to its own upstreams; git remotes are the authority, and
divergence is surfaced, never auto-merged. Reach is read all, write local:
any roster box can be read over ssh, only the current box is changed.

Why: nothing knew what was true on which box. A report invented dead
pipelines from logs under a mount that box lacked; a pushed fix read as
unpushed because the work was on the other machine. An early design note
assumed home directories were shared across boxes. They were not: per-box
clones lagged, a real cross-box divergence had to be resolved, and dotfiles
and timezones differed.

Rules out: shared-filesystem assumptions and auto-merge. Distro, editor and
systemd are probed, not listed: such a table is wrong within a month.

## rig push: publishing is sync's mirror

`rig push [-m MSG]` visits each repo this box may publish: fetch, fast-forward
if behind, then commit the dirty tree whole, then push.

Why: every other write path ran one way, so publishing was done by hand under
messages that said nothing. Committing first would turn a stale box into a
diverged one, and stale is the usual morning state. On divergence the tree is
still committed (`git pull --rebase` by hand is then the whole fix) but
nothing is pushed and the run exits 1. One message per run,
`sync: <box> <YYYY-MM-DD HH:MM>`, so commits correlate and one `git log --grep`
finds them; the body lists what was staged. The roster's `push=` narrows
`repos=`, since a public repo must never get `sync: <host>` commits.

Rules out: force pushes, merging in the tool, and writes past this box's own
upstreams. `arm -a` follows only if `fleet.zsh` or a completion changed.

## rig's installers are config; the stage protocol is v0.2

`rig sync` sequences the installers a box already has and adds the checks
they lack (link gaps after a pull, expected versus enabled timers). Each is a
config key: `rig.pull` (with `rig.pull_log`), `rig.journal`,
`rig.journal_repo`, `rig.installer`, `rig.timer_installer`,
`rig.cron_installer`. An unset key is a skipped stage, never a finding.

Why: these were hard-coded paths into the original repo, which a public tool
cannot carry. The move was checked as a no-op (`rig sync --dry-run`
byte-identical on a configured box), and bootstrap reads `bootstrap_repo=` and
`bootstrap=` from the roster. Stages report on the artifact: after the link
installer applies, `--check` runs again, and a disagreement is `VERIFY_FAILED`.

Deferred to v0.2: a pluggable stage protocol. Stages become executables with
a marker header, answering `check` and `apply`, exit 0 clean, 1 pending,
2 blocked, 3 not applicable, with `check` re-run after every `apply`. v0.1
keeps the fixed sequence and the named keys.

## rig doctor: one door for drift

`rig doctor` is the one place to ask what is wrong here. Other checkers are
rows: `editor` runs the dotfiles repo's editor check, `theme` the theme
switcher's doctor, `links` the installer's `--check`, `timers` the expected
set; `--disk` folds in a one-off disk triage script.

Why: four incidents (an rc gone plain instead of linked, a CLI tool missing on
one distro, a secrets file hand-built per host, themes copied by hand) were
one class, and three had a checker behind its own door. A fourth doctor was
proposed; the annoyance was real, the shape stale. Editor gaps are a finding
in doctor but a note in unattended `sync`, which cannot fix an interactive
script. An absent theme switcher is a skip; one that crashes is a finding.

Rules out: one doctor per concern, and disk scans over ssh (`--disk` is local).

## crew: a roll call, not a tracker

`crew` lists Claude Code sessions on this box, or with `-a` on every roster
box over read-only ssh, with project, pane and state.

Why: ten sessions on several boxes and no way to see them; tmux shows a pane
running `claude` and no more. Discovery starts from the process list, so
sessions outside tmux appear. State is transcript mtime, with the limit stated
in the man page: a long tool call looks idle. `--sample` measures CPU instead,
and its first run proved a session three minutes "idle" was busy. `crew` reads
`rig`'s roster: one registry, not two.

Rules out: per-file attribution, tmux-only discovery, and a second host list.

## The fleet wears the theme; the kit's palette is the fallback

The kit's builtin palette (voidrunner, pinned to a test fixture) keeps every
box readable. A worn theme bundle's `~/.config/theme/current/sckit.sh`
(or `SC_THEME`) overrides it, so the fleet wears what the terminal wears.

Why: one palette was kept by hand in over a dozen files, and drift defects
survived for weeks. A theme factory now renders every surface from one file;
the fleet is one more surface. It keeps the spacecowboy name while wearing
whichever theme is current (the theme of that name is another palette).
`SC_COLOR=1` forces colour through a pipe for tests; `NO_COLOR` still wins.

Rules out: a palette per tool, and a fleet unreadable without a bundle.

## The sc menu: every verb, derived from the headers

Bare `sc` opens a two-level fzf menu under the logo (tools, then verbs with
descriptions), parsed from the header lines each member's `usage()` prints,
and runs or prefills the pick.

Why: six tools and forty-odd verbs is past memory, and a verb is in the menu
once its header line exists. Run versus prefill needs no list of dangerous
verbs: a required `<slug>` or an uppercase value word (`[-m MSG]`) lands on
the prompt, a flag-only verb runs, Tab forces the prompt. Only the shell
function can call a shell function (`wt cd`) or prefill (`print -z`), so it
decides. Without fzf or a terminal, `__pick` exits 2 and the splash shows, so
scripts see no change. A flat list proved too long, hence two levels.

Rules out: a hand-kept menu list, and an allowlist of verbs safe to run.

## Tasks: Obsidian grammar, deterministic engine

The board is one markdown file in the Obsidian Tasks emoji grammar (due,
scheduled, recurrence, done and cancelled stamps, priorities; statuses `[ ]`
`[/]` `[x]` `[-]`). All date maths, recurrence and writes go through
`lib/tasks.py`, stdlib-only; `tk` passes flags through untouched.

Why: one grammar everywhere means nothing to relearn, and the file renders in
Obsidian; plain-ASCII fields were easier to grep but a second grammar. Parity
is deliberate: recurrence is due-date-based unless the rule ends `when done`,
the next instance goes above the completed line, `-` and `*` both parse. A
model computing "every 2nd Tuesday" is mostly right, and mostly is not good
enough for a reminder system; an agent only turns language into ISO dates and
flags. Writes are surgical and atomic, so the file stays hand-editable.

Rules out: a bespoke syntax, model-computed dates, and a wrapper that
re-implements the engine.
