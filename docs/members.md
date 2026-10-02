# Fleet members

A member is any executable that carries the marker and answers `__id`. Nothing
lists the members: `sc`, `install.sh` and `rig` all derive the set from the
marker, so a new tool is part of the fleet the moment it exists.

## The contract

1. **The marker.** A line that starts with `# sc-fleet` anywhere in the file.
   By convention it is the last line. `sc` greps for it *before* running
   anything, so it never executes a neighbouring script just to ask what it is.
2. **The four facts and the kit.**

   ```bash
   SC_TOOL='wt'
   SC_TAGLINE='one worktree per topic'
   SC_MOTTO='every checkout a sibling'
   SC_SIGIL=$' ╭◆ \n━┠─◆\n ╰◆ '        # 3 rows, each padded to 4 characters
   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/sckit.sh"
   ```

   Sigil rows are padded by hand because bash pads field widths by bytes, not
   display width.
3. **`__id`.** A hidden verb that calls `sc_id`, which prints one
   tab-separated record: tool, tagline, motto, sigil row 1, row 2, row 3.
4. **The header block.** Verbs are declared in the comment block at the top,
   one per line, in one grammar:

   ```
   #   rig doctor [--disk]    what is missing here
   ```

   The command is the verb plus anything shaped like arguments (`[...]`,
   `<...>`, `-flags`), and the description is what follows. A more deeply
   indented next line continues the entry. `sc`'s menu reads these lines, and
   the tool's own usage should print the same ones, so the two cannot drift.
   A required `<placeholder>` or a bracketed VALUE word (`[-m MSG]`) puts the
   picked command on the prompt for editing; a flag-only verb runs as picked.
5. **A man page**, `man/<tool>.1`, linked by `install.sh` when present.
   `<tool> help <verb>` opening the page at that verb is the convention.

## The kit (`lib/sckit.sh`)

Sourcing it defines, and prints nothing:

| Name | What |
| --- | --- |
| `A_LIME A_SEA A_LAV A_FG A_DIM A_WARN A_ERR A_B A_0` | truecolor escapes, empty when stdout is not a terminal or `NO_COLOR` is set |
| `art_on` | true when banners should draw (a terminal, or `SC_ART` / `<TOOL>_ART` set; `*_NO_ART` wins at the same level) |
| `sc_mark`, `sc_splash`, `sc_band VERB [DETAIL]` | the shared mark, the splash and the one-line band a state change prints |
| `sc_logo`, `sc_logo_small` | the fleet logo |
| `sc_id` | the `__id` record |
| `row LABEL VALUE [NOTE]` | one aligned status row |
| `ok`, `bad`, `dim` | colour a fragment |
| `die MSG`, `warn MSG` | the `refuse` and `warn` lines on stderr; `die` exits 1 |

`SC_W` is the width budget (default 72) and `SC_M` the left margin.

The config reader, `lib/scconf.sh`, is separate on purpose, so a tool that runs
without the kit can still read its config. See [configuration.md](configuration.md).

## Members from other repos

`sc` looks for members in its own `bin/` and in every directory of
`SC_BIN_EXTRA` (default `~/.local/bin`), deduplicated by real path. A tool kept
in another repository joins by carrying the marker and being on that path. It
cannot use the relative kit path above, so it sources the stable link instead:

```bash
. "${XDG_DATA_HOME:-$HOME/.local/share}/sc-fleet/lib/sckit.sh"
```

`install.sh` keeps that link pointed at the checkout, so moving the checkout
is one re-run of the installer, not an edit in every repo.

## The theme interface

The kit's built-in palette is a fallback that keeps every machine readable.
When a theme bundle is worn, the kit sources `~/.config/theme/current/sckit.sh`
(or `$SC_THEME`), which may set any of:

```bash
SC_RGB_cursor  SC_RGB_fg  SC_RGB_fg2  SC_RGB_bright  SC_RGB_dim  SC_RGB_border
SC_RGB_lime  SC_RGB_mint  SC_RGB_peach  SC_RGB_rose  SC_RGB_butter
```

each as `'R;G;B'`. The escapes are derived from those after the bundle loads.
A bundle may also replace the logo block. This file is the whole interface
between the fleet and a theme switcher; `tests/test_sc.sh` pins the built-in
values to `tests/fixtures/voidrunner.json` and checks that an override wins.

## Checklist for a new tool

- `bin/<tool>`, executable, marker on the last line, the four facts, `__id`.
- Header block verbs in the grammar above; `usage` prints them.
- `man/<tool>.1`; `completions/_<tool>` if it takes verbs.
- `tests/test_<tool>.sh`, offline, everything under `mktemp`, exporting
  `SC_CONFIG_HOME` so the real config is never read.
- Site facts (hosts, paths, forges) go in config keys with neutral defaults,
  never in the tool. `tools/leakgate.py` refuses a commit that carries them.
