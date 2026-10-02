# Changelog

## 0.1.0 (2026-10-02)

First public release. The tools had been in daily use on a few machines
before this; the history starts fresh here.

- `sc`: the dispatcher, roster, fzf menu derived from each member's header,
  and `sc config` to show the effective configuration.
- `arm`: re-source the fleet's shell surface in this shell or every tmux pane.
- `crew`: every Claude Code session running, locally or across the roster.
- `wt`: one worktree per topic, every checkout a sibling, PRs on GitHub,
  GitLab or Forgejo.
- `rig`: per-box state against git upstreams; `sync`, `push`, `doctor`
  (with `--disk` triage) and `boxes`.
- `tk`: the task board over `lib/tasks.py`, an Obsidian Tasks emoji-grammar
  engine with deterministic recurrence.
- Site facts live in `~/.config/sc-fleet/config` with neutral defaults; the
  tools carry none.
- `install.sh` with `--check` and `--uninstall`.
- `tools/leakgate.py`: refuses site strings in commits, messages and pushes,
  with a private deny list; `tools/prepublish.sh` gates a release.

### Deferred to 0.2

- A pluggable `rig` stage protocol: stages as marked executables with
  read-only `check` and an `apply`, re-checked after apply. In 0.1 the
  installers rig sequences are named by `rig.*` config keys instead.
