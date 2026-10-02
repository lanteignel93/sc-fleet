# sckit.sh — spacecowboy: the shared terminal identity for the sc fleet.
#
# A tool joins the fleet by carrying a "# sc-fleet" marker line, setting four
# facts, and sourcing this file:
#
#   SC_TOOL='wt'
#   SC_TAGLINE='one worktree per topic'
#   SC_MOTTO='every checkout a sibling'
#   SC_SIGIL=$' ╭◆ \n━┠─◆\n ╰◆ '        # 3 rows, each padded to 4 characters
#   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/sckit.sh"
#
# That path is for a tool in this checkout's bin/. A member living in another
# repo sources ${XDG_DATA_HOME:-~/.local/share}/sc-fleet/lib/sckit.sh, the
# stable link install.sh keeps pointed at the checkout (docs/members.md).
#
# Everything else — palette, gating, the shared mark, the chrome — lives here,
# so adding a tool never means re-deciding what lime means.
#
# Sigil rows are pre-padded because bash printf pads field widths by bytes, not
# by display width, and every glyph here is multibyte.

# --- palette: truecolor, defined once for every tool -------------------------
# The builtin values are the voidrunner palette, the kit-less fallback that keeps
# every box readable. When a theme bundle is worn (`dye <name>` re-points
# ~/.config/theme/current), its sckit.sh overrides them, so the fleet wears
# whatever the editor and the terminal wear. SC_THEME points elsewhere for
# tests; SC_COLOR=1 forces colour through a pipe. tests/test_sc.sh pins the
# builtins to tests/fixtures/voidrunner.json and checks the override path.
if [[ ( -t 1 || -n "${SC_COLOR:-}" ) && -z "${NO_COLOR:-}" ]]; then
  A_LIME=$'\e[38;2;189;254;88m'    # your work
  A_SEA=$'\e[38;2;94;238;175m'     # success, arrival
  A_LAV=$'\e[38;2;229;204;255m'    # remote, forge, elsewhere
  A_FG=$'\e[38;2;192;192;192m'     # ordinary text
  A_DIM=$'\e[38;2;88;88;88m'       # structure
  A_WARN=$'\e[38;2;255;255;186m'
  A_ERR=$'\e[38;2;222;166;160m'
  A_B=$'\e[1m'; A_0=$'\e[0m'
  # Palette roles the logo is drawn in (lib/mkart.py), as r;g;b. Builtins are
  # voidrunner's, like the A_* above; a worn bundle overrides them too.
  SC_RGB_cursor='189;254;88' SC_RGB_fg='192;192;192' SC_RGB_fg2='158;158;158'
  SC_RGB_bright='241;241;241' SC_RGB_dim='88;88;88' SC_RGB_border='88;88;88'
  SC_RGB_lime='189;254;88' SC_RGB_mint='94;238;175' SC_RGB_peach='255;217;186'
  SC_RGB_rose='222;166;160' SC_RGB_butter='255;255;186'
  # shellcheck source=/dev/null
  [[ -r "${SC_THEME:-$HOME/.config/theme/current/sckit.sh}" ]] && . "${SC_THEME:-$HOME/.config/theme/current/sckit.sh}"
else
  A_LIME="" A_SEA="" A_LAV="" A_FG="" A_DIM="" A_WARN="" A_ERR="" A_B="" A_0=""
fi

SC_W="${SC_W:-72}"      # width budget: fits an 80-column terminal with room
SC_M='    '             # left margin, shared with the status row

# --- gating: art is for a human at a terminal, never for a pipe --------------
# SC_ART=1 or <TOOL>_ART=1 forces it through a pipe, which is what makes the
# banners testable and screenshottable. Precedence: the most specific setting
# wins, and at the same level "off" beats "on", so SC_NO_ART=1 in a CI
# environment cannot be undone by a stray SC_ART somewhere else.
art_on() {
  local t="${SC_TOOL:-sc}"; t="${t^^}"
  local on="${t}_ART" off="${t}_NO_ART"
  [[ -n "${!off:-}" ]] && return 1
  [[ -n "${!on:-}" ]] && return 0
  [[ -n "${SC_NO_ART:-}" ]] && return 1
  [[ -n "${SC_ART:-}" ]] && return 0
  [[ -t 1 ]]
}

# --- the shared mark ---------------------------------------------------------
# The brand: a heavy rail broken by two bars with the mark burned between
# them. Every tool prints it; it is the only drawing the whole fleet has in
# common. Its compressed form is the "┫✦┣" cap on the band. ✦ is the family
# mark and never a node — ◆ ● ◇ keep their meanings in the diagrams.
sc_mark() {
  art_on || return 0
  local inner=$(( SC_W - ${#SC_M} - 5 ))
  (( inner < 8 )) && inner=8
  local l=$(( inner / 2 )) r=$(( inner - inner / 2 )) lb rb
  printf -v lb '%*s' "$l" ''; lb="${lb// /━}"
  printf -v rb '%*s' "$r" ''; rb="${rb// /━}"
  printf '%s\n' "${SC_M}${A_DIM}${lb}┫${A_0} ${A_LIME}✦${A_0} ${A_DIM}┣${rb}${A_0}"
}

# sc_splash — the mark, then this tool's sigil. Bare invocation and --help.
sc_splash() {
  art_on || return 0
  local -a s=(); local line
  while IFS= read -r line; do s+=("$line"); done <<<"${SC_SIGIL:-}"
  printf '\n'; sc_mark; printf '\n'
  printf '%s\n' "${SC_M}${A_LIME}${s[0]:-    }${A_0}   ${A_B}${A_LIME}${SC_TOOL}${A_0}"
  printf '%s\n' "${SC_M}${A_LIME}${s[1]:-    }${A_0}   ${A_FG}${SC_TAGLINE:-}${A_0}"
  printf '%s\n' "${SC_M}${A_LIME}${s[2]:-    }${A_0}   ${A_DIM}${SC_MOTTO:-}${A_0}"
  printf '\n'
}

# sc_band VERB [DETAIL] — one line, printed by verbs that change something.
sc_band() {
  art_on || return 0
  local verb="${1:-}" detail="${2:-}" tail bar fill
  tail="$verb"; [[ -n "$detail" ]] && tail+=" · $detail"
  fill=$(( SC_W - ${#SC_M} - 4 - ${#SC_TOOL} - ${#tail} - 3 ))
  (( fill < 3 )) && fill=3
  printf -v bar '%*s' "$fill" ''; bar="${bar// /─}"
  printf '%s\n' "${SC_M}${A_DIM}┫✦┣${A_0} ${A_B}${A_LIME}${SC_TOOL}${A_0} ${A_DIM}${bar}${A_0}  ${A_SEA}${tail}${A_0}"
}

# --- the project logo (tier 3) ----------------------------------------------
# The project logo (tier 3). Generated from the drawing in lib/mkart.py, never
# hand-edited: change it there and paste the output back over this block. A
# tool prints sc_mark; only the dispatcher and a README use this.
SC_ART_ROLES=(border bright butter cursor dim fg fg2 lime mint peach rose)
# One foreground escape per role, from SC_RGB_<role> (the builtins above, or
# the worn bundle's). Empty without colour, so the rows print as plain ASCII.
for _r in "${SC_ART_ROLES[@]}"; do _v="SC_RGB_$_r"
  if [[ -n "$A_0" ]]; then printf -v "F_$_r" '\e[38;2;%sm' "${!_v}"; else printf -v "F_$_r" %s ""; fi
done; unset _r _v
# The scene: ${F_*} expand here, when the kit is sourced.
SC_LOGO_SCENE=(
  "     ${F_cursor}.-~~-.             ${F_dim}.               ${F_bright}*                 _..._${A_0}"
  "  ${F_fg}--${F_cursor}(      )${F_fg}--   ${F_bright}*                         *            .'  .-'${A_0}"
  "     ${F_cursor}\`-..-'                  ___ ${F_dim}.                     ${F_bright}/   /${A_0}"
  "                        ${F_cursor}____|___|____         ${F_dim}.        ${F_bright}|  |${A_0}"
  "              ${F_dim}.        ${F_cursor}(_____________)                 ${F_bright}\\   '.${A_0}"
  "                           ${F_peach}| o o |                      ${F_bright}'._  '-.${A_0}"
  " ${F_dim}.                         ${F_peach}|  -  |          ${F_dim}.              ${F_bright}''${A_0}"
  "       ${F_lime}_                 ${F_fg}__${F_rose}\\vvvvv/${F_fg}__${A_0}"
  "      ${F_lime}| |               ${F_fg}/  |     |  \\      .-----------------.${A_0}"
  "    ${F_lime}_ | |  _           ${F_fg}/   |  ${F_fg2}|  ${F_fg}|   \\     | .-------------. |${A_0}"
  "   ${F_lime}| || | | |         ${F_peach}(_)  ${F_fg}|  ${F_fg2}|  ${F_fg}|  ${F_peach}(_)    ${F_fg}| | ${F_lime}\$ sc        ${F_fg}| |${A_0}"
  "   ${F_lime}| || |_| |              ${F_border}|__${F_butter}|${F_border}__|         ${F_fg}| | ${F_mint}> _         ${F_fg}| |${A_0}"
  "    ${F_lime}\\_| |__/               ${F_dim}|  |  |         ${F_fg}| '-------------' |${A_0}"
  "      ${F_lime}| |                  ${F_dim}|  |  |         ${F_fg}'--------.--------'${A_0}"
  "      ${F_lime}| |                 ${F_dim}_|  |  |_              ${F_fg}___|___${A_0}"
  "      ${F_lime}| |                ${F_border}(___) (___)            ${F_fg}'-------'${A_0}"
  "${F_dim}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${A_0}"
  "   ${F_border}.      '         .            ,          .         '     .${A_0}"
)
SC_LOGO_WORD_A=(
  "█▀▀▀▀ █▀▀▀█ ▄▀▀▀▄ █▀▀▀▀ █▀▀▀▀   "
  "▀▀▀▀█ █▀▀▀▀ █▀▀▀█ █     █▀▀▀    "
  "▀▀▀▀▀ ▀     ▀   ▀ ▀▀▀▀▀ ▀▀▀▀▀   "
)
SC_LOGO_WORD_B=(
  "█▀▀▀▀ █▀▀▀█ █   █ █▀▀▀▄ █▀▀▀█ █   █"
  "█     █   █ █▄▀▄█ █▀▀▀▄ █   █  ▀█▀"
  "▀▀▀▀▀ ▀▀▀▀▀ ▀   ▀ ▀▀▀▀  ▀▀▀▀▀   ▀"
)
SC_LOGO_W=67

# sc_logo — the full banner: a night in the desert (a ringed planet, the moon,
# a saguaro, the cowboy and his terminal), the name beneath it. Coloured in the
# worn theme's roles; plain ASCII without colour. Only the dispatcher and a
# README use this; a tool prints sc_mark instead, the same identity at one line.
sc_logo() {
  art_on || return 0
  local l i
  for l in "${SC_LOGO_SCENE[@]}"; do printf '%s\n' "${SC_M}${l}"; done
  printf '\n'
  for i in "${!SC_LOGO_WORD_A[@]}"; do
    printf '%s\n' "${SC_M}${A_B}${F_lime}${SC_LOGO_WORD_A[i]}${F_cursor}${SC_LOGO_WORD_B[i]}${A_0}"
  done
  return 0
}

# sc_logo_small — the wordmark under the stars, four lines, for a terminal too
# short to hold the scene above a list (the menu switches to it under 40 rows).
SC_LOGO_LINES=$(( ${#SC_LOGO_SCENE[@]} + 1 + ${#SC_LOGO_WORD_A[@]} ))
SC_LOGO_SMALL_LINES=$(( 1 + ${#SC_LOGO_WORD_A[@]} ))
sc_logo_small() {
  art_on || return 0
  local i
  printf '%s\n' "${SC_M}${SC_LOGO_SCENE[-1]}"
  for i in "${!SC_LOGO_WORD_A[@]}"; do
    printf '%s\n' "${SC_M}${A_B}${F_lime}${SC_LOGO_WORD_A[i]}${F_cursor}${SC_LOGO_WORD_B[i]}${A_0}"
  done
  return 0
}

# sc_id — the hidden __id record the dispatcher reads to build its roster.
# Tab separated so the sigil rows keep their padding.
sc_id() {
  local -a s=(); local line
  while IFS= read -r line; do s+=("$line"); done <<<"${SC_SIGIL:-}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${SC_TOOL:-}" "${SC_TAGLINE:-}" "${SC_MOTTO:-}" \
    "${s[0]:-    }" "${s[1]:-    }" "${s[2]:-    }"
}

# --- shared output vocabulary ------------------------------------------------
row()  { local l="$1" v="${2:-}"; shift 2 || true
         printf '%s%-9s%s %-42s %s\n' "$A_DIM" "$l" "$A_0" "$v" "${*:-}"; }
ok()   { printf '%s%s%s' "$A_SEA" "$*" "$A_0"; }
bad()  { printf '%s%s%s' "$A_ERR" "$*" "$A_0"; }
dim()  { printf '%s%s%s' "$A_DIM" "$*" "$A_0"; }
die()  { printf '%srefuse%s    %s\n' "$A_ERR" "$A_0" "$*" >&2; exit 1; }
warn() { printf '%swarn%s      %s\n' "$A_WARN" "$A_0" "$*" >&2; }
