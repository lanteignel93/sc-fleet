# wt workspace layout

`wt` lays out several projects on one machine, each with several topics in
flight, on the assumption that the machine's local disk need not be durable: a
VM whose local disk is purged or rebuilt, a build volume nobody backs up.
Every checkout of a repo is a sibling directory, every topic is a git worktree
on its own branch, and everything that must survive lives in a git-backed store
elsewhere and is symlinked in. Several agent sessions can work the same repo at
once without colliding, and shared repos stay free of personal files.

`man wt` is the command reference; this page is the shape and the reasons.

## The rule

**Local working storage holds only what a command can recreate.** Apply it to
everything in the tree:

| Artifact                                     | Recreated by                     | Lives in            |
|----------------------------------------------|----------------------------------|---------------------|
| the clone and its worktrees                  | `wt init --clone`, `wt new`      | `<root>`            |
| build output, containers                     | the build                        | `<root>`            |
| derived data, caches                         | the command that derived them    | `<root>`            |
| project context, notes, per-repo conventions | nothing                          | `<store>` (durable) |
| uncommitted branch work                      | nothing                          | push it, or accept the risk |

Durable is not the same as shared. A home directory that survives a rebuild is
not necessarily visible from the next machine, so git is the transport between
machines, not the filesystem: keep the store in a git repository and push it.
`wt` writes files into the store but never commits or pushes it.

## Locations

| Config key       | Env override    | Default                              |
|------------------|-----------------|--------------------------------------|
| `notes`          |                 | `~/notes`                            |
| `wt.root`        | `WT_ROOT`       | `~/wt`                               |
| `wt.store`       | `WT_STORE`      | `<notes>/projects`, so `~/notes/projects` |
| `wt.token_file`  | `WT_TOKEN_FILE` | `~/.config/forgejo/token`            |
| `wt.templates`   |                 | `~/.config/sc-fleet/wt`              |
| `wt.forgejo_web` | `WT_FORGE_WEB`  | unset                                |
| `wt.forge`       |                 | none (a list; see [Forges](#forges)) |

The fleet config is `~/.config/sc-fleet/config`, with a per-machine
`config.local` beside it that wins. Lines are `tool.key=value`; the file is read
with grep, never sourced, and only `~/`, `$HOME` and `$USER` are expanded.
`sc config` shows the effective values.

## Layout

```text
<root>/<proj>/                             plain directory, never a git repo
├── CLAUDE.md -> <store>/<proj>/CLAUDE.md
├── docs      -> <store>/<proj>/
└── src/<repo>/
    ├── main/                              the clone; stays on the default branch
    │   └── .claude/settings.local.json    repo-scoped allows (allow_interp=true only)
    └── <slug>/                            linked worktree, branch = <prefix><slug>
        └── CLAUDE.local.md -> ../../../docs/topics/<slug>.md    (git-excluded)

<store>/<proj>/                            durable store: git, pushed
├── CLAUDE.md  README.md
├── repos/<repo>.conf                      per-repo conventions, read by wt
└── topics/<slug>.md  topics/archive/      one note per topic; archived by wt rm
```

Every checkout is a sibling under `src/<repo>/`. `main` is the one that owns
`.git`; the topic worktrees share its object store. `ls src/<repo>/` is the list
of what is in flight. Sibling repos of one project sit beside each other under
`src/`.

The project directory is a **plain directory, not a git repo**: making it one
would nest the real clone inside it. The symlinks do real work. The natural
place to write notes is outside the repo, so personal files never drift into
somebody else's PR by accident.

`CLAUDE.local.md` in a worktree is a relative link through the project's `docs`
link to the topic note, so it resolves wherever the store is mounted. (When
`docs` is not a symlink, `wt new` links the note's absolute store path instead.)

`$(git rev-parse --git-common-dir)/info/exclude` carries `CLAUDE.local.md` and
`.claude/`. That file is local to the clone, never pushed, and applies to every
worktree, so nothing personal ever shows in `git status` in a shared repo.
`wt init` and `wt new` both make sure the entries are there.

`wt init` also sets `core.hooksPath scripts/hooks` when the repo ships a
`scripts/hooks` directory and no hooks path is set yet.

### The store

`<store>/<proj>/` is where everything that cannot be recreated goes.

- **`CLAUDE.md`**: project context, stubbed by `wt init` with Layout, Repo
  conventions, Data and This box sections. Fill it in. It is the file that stops
  every new session re-deriving the same facts: where the data lives and its
  pitfalls, what this machine is and is not provisioned for, the repo's branch
  and PR conventions, known defects in merged code, the current acceptance gate.
- **`README.md`**: a stub explaining the store. A `store-README.md` in the
  `wt.templates` directory replaces it, with `{{PROJ}}`, `{{WRAP}}` and
  `{{STORE}}` substituted.
- **`repos/<repo>.conf`**: per-repo conventions (below).
- **`topics/<slug>.md`**: one note per topic, seeded by `wt new` with the
  branch, worktree, base, start date (and the parent ref when the topic was
  branched with `--from`), then Goal, Acceptance gate and Log sections. `wt pr`
  builds the default PR body from Goal and Acceptance gate plus the commit list,
  and appends `- YYYY-MM-DD PR opened: <url>` to the note.
- **`topics/archive/`**: `wt rm` moves the note here, so the record of what was
  tried stays.

### Per-repo conventions: `repos/<repo>.conf`

```ini
prefix=            # prepended to the slug: empty, t/ or ab/feature/
base=origin        # remote holding the default branch; upstream on a fork checkout
push=origin        # remote topics are pushed to
squash=true        # wt pr squashes to one commit; false keeps the commits
forge=github       # auto|github|forgejo|gitlab
allow_interp=false # true: interpreter allows in main/.claude/settings.local.json
web=               # browser/API base (https://<host>) when the remote is an IP or an ssh alias
```

`key=value`, one per line, `#` comments allowed, read with grep and never
sourced. `wt init` infers it once and never overwrites it; edit it like any
note. The inference:

- `base` is `upstream` when that remote exists, otherwise `origin`.
- `prefix` is the most common `dir/` prefix among remote branches whose tip you
  authored (bot branch prefixes are ignored).
- `forge` is derived from the base remote's host through the forge rules and
  written as the resolved kind; set `forge=auto` to re-derive it on every run.
- `web` is `https://github.com` for a `github-*` ssh alias, and left empty for a
  bare IP, with a warning to fill it in.

Branch = `prefix` + slug; directory = slug, which may not contain `/`. A
non-empty prefix must end in `/`, `-`, `_` or `.`. Override it for one call with
`wt new --prefix ab/fix/ <slug>`, or adopt a live remote branch with
`wt new --track <branch>`.

## Forges

`wt pr`, `wt ls --pr` and `wt rm` talk to the repo's forge. The kind comes from,
in order:

1. the conf's `forge=`, when it is not `auto`;
2. the `wt.forge` config list, matched against the base remote's host: one
   `<glob> <kind>` per line, repeatable, `config.local` rules tried before
   `config`'s, first match wins;
3. the built-ins:

| Host                                   | Kind      |
|----------------------------------------|-----------|
| `github.com`, `github-*` ssh aliases   | `github`  |
| `gitlab.com`, `*gitlab*`               | `gitlab`  |
| `codeberg.org`                         | `forgejo` |
| anything else                          | unknown: `wt pr` pushes and you open the PR by hand |

A site's own forge goes in the config:

```ini
wt.forge=forge.example.org forgejo
wt.forge=*.git.example.org gitlab
```

- **GitHub** goes through `gh`, **GitLab** through `glab`.
- **Forgejo** goes through its REST API at `web=` (or `https://<remote host>`),
  with a token from `$FORGEJO_TOKEN` or `wt.token_file` (mode 0600, scope
  `write:repository`). Without a token, `wt pr` pushes, prints the compare URL
  and writes the PR body to `$XDG_RUNTIME_DIR/wt-pr-body.md` for pasting.
- **`wt.forgejo_web`** is the Forgejo base URL that
  `wt init --new <name> --forge forgejo --org <org>` uses to create a repo. It
  is unset by default, and that command then refuses and names the key.

## What an agent session reads

Start `claude` (Claude Code) inside the worktree. From there it loads:

| Loaded  | File                                              | Why                                                        |
|---------|---------------------------------------------------|------------------------------------------------------------|
| yes     | `~/.claude/CLAUDE.md`                             | user scope                                                 |
| yes     | `<proj>/CLAUDE.md`, linked to the store           | ancestor directories load at launch; symlinks are followed |
| yes     | `<slug>/CLAUDE.md`                                | the repo's own, if it has one                              |
| yes     | `<slug>/CLAUDE.local.md`, linked to the topic note | the launch directory; git-excluded                        |
| yes     | `main/.claude/settings.local.json`                | read at the main checkout's root and applied to every worktree; "don't ask again" approvals are written there |
| **no**  | `<proj>/.claude/settings.json`                    | project settings load from the launch directory only, which is why the project directory has no `.claude/` |
| shared  | auto-memory                                       | one per repository, shared by `main` and every worktree   |

So repo permissions go once in `main/.claude/settings.local.json` (written only
by `wt init --mine` or with `allow_interp=true`), project context in the
project's `CLAUDE.md`, and topic context in the topic note. These are Claude
Code's loading rules as this layout relies on them; if a session misses
context, check them against the current Claude Code documentation.

## Topic lifecycle

```text
wt init      bootstrap or repair a project: wrapper, clone, store, links, conf, exclude
wt new       branch from base/default, seed the note, link CLAUDE.local.md
wt cd        cd into a worktree (zsh function in shell/fleet.zsh over wt path)
wt ls        every worktree: ahead/behind, dirty, note, PR state with --pr
wt sync      fetch and rebase onto base/default; stops on conflict
wt pr        rebase, squash (per conf), push, open the PR on the repo's forge
wt rm        after the merge; refuses dirty, unpushed or unmerged work
wt doctor    links, conf, remote HEAD, exclude, forge credential, disk
```

### init

```sh
wt init --project borealis --clone forgejo@forge.example.org:acme/borealis.git   # a project from an existing remote
cd ~/wt/borealis && wt init --clone git@github.com:acme/borealis-tools.git       # a sibling repo in an existing project
wt init --project atlas --new atlas --mine --forge forgejo --org acme            # a brand-new repo of your own
wt init --migrate                                                                # old layout src/<repo> to src/<repo>/main
```

Each leaves the project directory, `src/<repo>/main`, the store with stub
`CLAUDE.md` and `README.md`, `repos/<repo>.conf`, both symlinks and the exclude
entries in place. Re-running `wt init` (with or without `--clone`) is safe: it
repairs what is missing and leaves what exists alone. `--migrate` refuses a dirty clone or one with linked
worktrees. `--mine` writes interpreter allows for a repo you own; never use it
on somebody else's checkout.

After the local disk is lost, make sure the store is back (clone it from its
remote), then `wt init --project <proj> --clone <url>` rebuilds everything
local around it. Pushed topics come back with `wt new --track <branch>`, which
finds their notes still in the store.

### new

`wt new <slug>` fetches the base remote, resolves its default branch (the
remote HEAD, else `git remote set-head -a`, else `main` or `master`), creates
`<prefix><slug>` from `base/<default>` (never from the local checkout), adds the
worktree at `src/<repo>/<slug>`, seeds `topics/<slug>.md` and links it in as
`CLAUDE.local.md`. The last line of output is the worktree path.

- `--from <ref>` branches from another ref and records it in the note, which
  makes `wt pr` treat the topic as stacked on that branch.
- `--track <branch>` adopts an existing local or remote branch; the slug
  defaults to its last path component.
- It refuses a slug containing `/`, the default branch's name, an existing
  directory, and a branch that already exists (pointing you at `--track`).
- It warns when free space under `<root>` is less than twice the size of
  `main/build*`, since a per-worktree build directory would not fit.

### sync

Inside a topic worktree, `wt sync` fetches the base remote and rebases onto its
default branch. On conflict it stops, lists the conflicting paths and leaves
the rebase in progress for `git rebase --continue` or `git rebase --abort`. It
refuses in `main` or on the default branch.

### pr

`wt pr` lands a topic: preflight (clean tree, not the default branch), sync,
squash, push, open the PR, log it in the note.

- **Title.** `-t` sets the PR and squash-commit title. A branch with more than
  one commit requires it: the last commit's subject is not a PR title.
- **Squash.** One commit by default (`squash=false` in the conf or
  `--no-squash` keeps them); the pre-squash subjects and bodies ride in the
  commit body.
- **Push.** Plain when it is a fast-forward, `--force-with-lease` when history
  was rewritten, which after a squash is the normal case. A re-run on an open PR
  re-squashes the same way, and the existing PR is reported, not duplicated.
- **Stacked PRs.** `--base <branch>` rebases onto and targets another topic
  branch already on the base remote. A branch that contains another pushed
  topic's commits is refused until `--base` names the parent (or the note's
  `--from` record does), because squashing to the default branch's merge-base
  would fold the parent topic into this PR.
- `--draft` opens a draft (a `WIP:` title prefix on Forgejo); `-b <file>`
  supplies the body; `--dry-run` reports ahead/behind, the squash plan, the
  forge and the commits, and changes nothing.

### rm

`wt rm <slug>` removes a topic after its merge. It refuses when the worktree is
dirty, has commits not on its upstream (or was never pushed), or the branch is
not merged. Merged means an ancestor of `base/<default>`, **or** the forge
reports the head's PR as merged: a squash-merge on the forge rewrites the SHA,
so the ancestor test alone would refuse forever. Then it runs
`git worktree remove`, `git branch -D` and `fetch --prune`, and moves the note
to `topics/archive/`. `--force` discards dirty or unpushed work and deletes an
unmerged branch; an agent should never add it on its own.

### doctor

`wt doctor` checks, per repo: the layout, both symlinks, the conf, the base
remote's HEAD, the exclude entries, the forge credential (token file mode 0600,
`gh auth`, `glab`), free space under `<root>` (flagged below 5 GB) and stale
worktrees. `-a` covers every project.

## Why worktrees, not branch switching

- No stashing when you are mid-change.
- Build caches stay warm per branch. On a large compiled repo a branch switch is
  a rebuild.
- You can review one branch while working on another.
- **Concurrent agent sessions do not fight over one index.** Several sessions
  against a single checkout corrupt each other's state; one worktree per session
  makes parallel work safe. This is the reason that forces the choice.

The cost: a worktree duplicates the working tree but shares the object store,
so a small repo is free and a large one is cheap. Per-worktree build
directories are not cheap, which is why `wt new` warns and `wt doctor` reports
free space.

## Shared repos

A repo somebody else owns gets no interpreter allows, no personal files and no
new top-level directories in your first PR. Conventions live in the conf, notes
in the store, and allows only behind `allow_interp=true`. If a directory of
yours turns out to be useful to the project, offer it in the PR body and let
the owner decide.
