# sc-fleet

```
    █▀▀▀▀ █▀▀▀█ ▄▀▀▀▄ █▀▀▀▀ █▀▀▀▀   █▀▀▀▀ █▀▀▀█ █   █ █▀▀▀▄ █▀▀▀█ █   █
    ▀▀▀▀█ █▀▀▀▀ █▀▀▀█ █     █▀▀▀    █     █   █ █▄▀▄█ █▀▀▀▄ █   █  ▀█▀
    ▀▀▀▀▀ ▀     ▀   ▀ ▀▀▀▀▀ ▀▀▀▀▀   ▀▀▀▀▀ ▀▀▀▀▀ ▀   ▀ ▀▀▀▀  ▀▀▀▀▀   ▀
```

A small fleet of command-line tools for working across several Linux machines
with git, tmux and Claude Code: worktrees per topic, per-box sync against git
upstreams, a roll call of running agent sessions, a markdown task board, and
one dispatcher over all of them. Each tool has one job, one man page and the
same terminal grammar.

Site specifics (hosts, paths, forges) live in your config, never in the tools.

| Tool | What it is for |
| --- | --- |
| `sc` | the dispatcher: an fzf menu of every tool's verbs, the roster, `sc config` |
| `wt` | one git worktree per topic, every checkout a sibling, PRs on GitHub, GitLab or Forgejo |
| `rig` | what this box is and whether it is current: `status`, `sync`, `push`, `doctor` across a roster of machines |
| `crew` | every Claude Code session you have running, here or on every box in the roster |
| `arm` | re-source the fleet's shell surface in this shell, or in every tmux pane |
| `tk` | a task board in one markdown file (Obsidian Tasks emoji grammar), with deterministic recurrence |

## Requirements

- Linux, bash 4.3 or newer, python 3.8 or newer, git, GNU coreutils, a UTF-8
  locale (the art is measured in characters).
- zsh for the shell surface (`shell/fleet.zsh`, completions, `arm`).
- Optional, each used only where it applies: fzf (menus, `wt cd`), tmux
  (`arm -a`), gh / glab / a Forgejo token (`wt pr`), systemd user timers
  (`rig` timer checks), ssh aliases for the machines in your roster.

## Install

```sh
git clone https://github.com/lanteignel93/sc-fleet.git ~/src/sc-fleet/main
~/src/sc-fleet/main/install.sh
```

`install.sh` links the tools into `~/.local/bin`, the man pages into
`~/.local/share/man/man1` and the completions into `~/.zsh_functions`, and
points `~/.local/share/sc-fleet` at the checkout. It writes nothing else: no
config, no rc file. Then add one line to `.zshrc`, after `compinit`:

```sh
[[ -r ~/.local/share/sc-fleet/shell/fleet.zsh ]] && . ~/.local/share/sc-fleet/shell/fleet.zsh
```

`install.sh --check` reports what is missing or wrong without changing
anything; `install.sh --uninstall` removes only its own links. Updating is
`git pull` in the checkout, then `install.sh` if a tool was added, then `arm`
(or `arm -a` for every tmux pane) so running shells pick it up.

## Configure

Everything works with an empty config. To point the tools at your machines,
write `~/.config/sc-fleet/config`:

```
notes=~/notes
wt.root=/data/$USER
wt.forge=forge.example.org forgejo
```

`sc config` shows every effective value and the file it came from. The full key
list, the grammar and the per-machine `config.local` override are in
[docs/configuration.md](docs/configuration.md); [examples/](examples) has a
commented config and a roster for `rig` and `crew`.

## Use

```sh
sc                  # the menu: pick a tool, then a verb
wt new fix-parser   # a worktree and branch for one topic
wt pr               # push and open the PR on whichever forge the remote is
rig                 # is this box current
rig status -a       # is every box current
crew                # which agent sessions are running, and what each is doing
tk                  # what is due
```

Every tool has `--help` and a man page (`man wt`, or `wt help pr` to open it at
a verb).

## Develop

```sh
bash tests/run.sh
```

Every suite is offline: temp directories, a throwaway `HOME` where it matters,
never the real config, tmux server or user manager.

A new tool joins by carrying a marker line and answering one hidden verb; see
[docs/members.md](docs/members.md). [docs/design.md](docs/design.md) records
why the tools are shaped the way they are.

### The leak gate

`tools/leakgate.py` refuses addresses, host names, e-mail addresses and home
paths in anything committed, and refuses the names in a private deny list
(`~/.config/sc-fleet/leakgate.deny`) that this repo cannot carry. Enable the
hooks with `git config core.hooksPath .githooks`; `tools/prepublish.sh` runs
every check before a release.

## License

MIT. See [LICENSE](LICENSE).
