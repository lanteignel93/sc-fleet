# Configuration

The tools carry no site facts. Hosts, paths and forges live in a small config
file that each tool reads at run time, and every key has a neutral default, so
an empty config is a working one.

## Files

```
~/.config/sc-fleet/config         shared: the facts true on every machine you use
~/.config/sc-fleet/config.local   this machine only; untracked; wins over config
~/.config/sc-fleet/leakgate.deny  the leak gate's deny list (tools/leakgate.py)
```

The directory is `$SC_CONFIG_HOME`, else `${XDG_CONFIG_HOME:-~/.config}/sc-fleet`.
A common arrangement is to keep `config` in a private dotfiles repo and symlink
it here, and keep per-machine tweaks in `config.local`.

`sc config` prints every effective value and which file set it; `sc config KEY`
prints one.

## Grammar

```
# comments and blank lines are skipped
notes = ~/notes            # a trailing comment is stripped
wt.root=/data/$USER
wt.forge=forge.example.org forgejo
wt.forge=*gitlab* gitlab   # a repeated key is a list
```

- `tool.key=value`, split on the first `=`; whitespace around key and value is
  trimmed.
- The file is read with grep and awk, **never sourced or evaluated**. The only
  expansion is text substitution of `~/` at the start of a word, `$HOME`,
  `${HOME}`, `$USER` and `${USER}`. `$(...)` stays literal text.
- Scalar keys: the last value wins, `config.local` over `config` over the
  built-in default. An empty value means unset.
- List keys: `config.local`'s entries first, then `config`'s, in file order.
- An environment variable a tool already honours (`WT_ROOT`, `TK_STORE`,
  `RIG_JOURNAL`, ...) still wins over the file.

`lib/scconf.sh` (bash) and `sc_conf()` in `lib/tasks.py` (python) implement
the same grammar; `tests/test_conf.sh` asserts that they agree on every case.

## Keys

| Key | Default | Read by | Meaning |
| --- | --- | --- | --- |
| `notes` | `~/notes` | wt, tk | the notes root other keys follow |
| `wt.root` | `~/wt` | wt | project root: `<root>/<proj>/src/<repo>/{main,<slug>}` |
| `wt.store` | `<notes>/projects` | wt | durable store for per-project notes and conventions |
| `wt.forge` | built-ins only | wt | list: `<host glob> <github\|gitlab\|forgejo>`, first match wins |
| `wt.forgejo_web` | unset | wt | Forgejo base URL for `wt init --new --forge forgejo`; unset refuses |
| `wt.token_file` | `~/.config/forgejo/token` | wt | Forgejo API token file |
| `wt.templates` | `<config home>/wt` | wt | text overlays, e.g. `store-README.md` |
| `tk.store` | `<notes>` | tk, tasks.py | directory holding `tasks.md` |
| `tk.hook_footer` | `Manage via tk.` | tasks.py | last line of `tasks.py hook-context` |
| `rig.pull` | unset | rig | fast-forward puller for your config repos |
| `rig.pull_log` | unset | rig | log the puller writes; scanned for `DIVERGED` lines |
| `rig.journal` | unset | rig | script that commits and syncs a journal repo |
| `rig.journal_repo` | unset | rig | the repo `rig push` hands to `rig.journal` |
| `rig.installer` | unset | rig | link installer with a `--check` mode |
| `rig.timer_installer` | unset | rig | installs the expected systemd user timers |
| `rig.cron_installer` | unset | rig | the same, under cron |

The `wt.forge` built-ins, tried after your rules: `github.com` and `github-*`
ssh aliases are github; `gitlab.com` and `*gitlab*` are gitlab; `codeberg.org`
is forgejo. Anything else is unknown: `wt pr` pushes the branch and leaves the
PR to you, and `wt doctor` says to set `forge=` in that repo's conf.

`wt.templates` placeholders: `{{PROJ}}` (project slug), `{{WRAP}}` (the
project directory) and `{{STORE}}` (its store directory).

A `rig.*` key that is unset is a skipped stage, never a finding: `rig doctor`
shows `not configured (<key>)` and `rig sync` moves on. The script a key names
is run as-is; rig only sequences it and reads its exit code and output. The
installer named by `rig.installer` must print `MISSING`, `WRONG`, `NOTLINK` or
`ORPHAN` lines for gaps under `--check`, the contract `install.sh` itself
follows.

## The roster

`rig` and `crew` share a second file, the roster of machines, at
`~/.config/rig/boxes.conf` (or `$RIG_BOXES`). It has the same grammar in
stanzas opened by `box=`; `box=@defaults` supplies every key a box does not
set. See `man rig` (THE ROSTER) and [`examples/boxes.conf`](../examples/boxes.conf).
It names hosts, so it belongs in private config, never in this repo.

## Example

[`examples/config`](../examples/config) is a complete, commented example with
fictional hosts.
