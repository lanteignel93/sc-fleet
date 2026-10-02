#!/usr/bin/env bash
# Offline test suite for the spacecowboy fleet kit — run: bash tests/test_sc.sh
#
# Builds a throwaway fleet under mktemp (a copy of sc + lib, one member, one
# non-member) so nothing here depends on what happens to be in ~/.local/bin.
# Art is forced on with SC_ART=1: colours stay empty because stdout is not a
# tty, so the captured output is exactly the glyphs.
set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../bin"
KIT="$HERE/../lib/sckit.sh"
THEME="$HERE/fixtures/voidrunner.json"
T="$(mktemp -d -t sc-test.XXXXXX)"
export SC_CONFIG_HOME="$T/cfg"  # never read the real ~/.config/sc-fleet
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
check_eq() { [[ "$2" == "$3" ]] && pass || fail "$1: expected [$3] got [$2]"; }
check_grep() { grep -qE -- "$2" <<<"$3" && pass || fail "$1: no match for /$2/ in: $3"; }
check_nogrep() { grep -qE -- "$2" <<<"$3" && fail "$1: unexpected /$2/ in: $3" || pass; }

# --- a throwaway fleet ----------------------------------------------------------------------
mkdir -p "$T/bin" "$T/lib"
cp "$SRC/sc" "$T/bin/sc"; cp "$KIT" "$T/lib/sckit.sh"; cp "$HERE/../lib/scconf.sh" "$T/lib/scconf.sh"

cat > "$T/bin/toolx" <<'MEMBER'
#!/usr/bin/env bash
# toolx — the throwaway member
#
#   toolx                  the default thing
#   toolx echo <words>     echo them back
#   toolx band [verb]      the band; [-m MSG] would prefill, [verb] does not
#   toolx mark             the mark, on a line that
#                          continues below it
#
set -euo pipefail
SC_TOOL='toolx'; SC_TAGLINE='one thing per other thing'; SC_MOTTO='a consequence'
SC_SIGIL=$'\u2501\u2501\u2501\u2501\n\u2500\u25cf\u2500\u2500\n\u2501\u2501\u2501\u2501'
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/sckit.sh"
case "${1:-}" in
  __id) sc_id ;;
  band) sc_band "${2:-verb}" "${3:-}" ;;
  mark) sc_mark ;;
  splash) sc_splash ;;
  echo) shift; printf 'toolx saw: %s\n' "$*" ;;
  *) printf 'toolx default\n' ;;
esac
# sc-fleet — membership marker
MEMBER

cat > "$T/bin/notatool" <<MEMBER
#!/usr/bin/env bash
touch "$T/SENTINEL"
printf 'notatool ran\n'
MEMBER
chmod +x "$T/bin/toolx" "$T/bin/notatool"

# a member that lives elsewhere (dye's situation), and a symlink to one that
# does not: the extra directory adds the first and must not double the second
mkdir -p "$T/extra"
cat > "$T/extra/toolz" <<'MEMBER'
#!/usr/bin/env bash
#   toolz                  lives in the extra directory
#   toolz go <where>       goes there
case "${1:-}" in
  __id) printf 'toolz\tfrom elsewhere\tstill a member\t ─● \t─●─●\t ─● \n' ;;
  echo) shift; printf 'toolz saw: %s\n' "$*" ;;
esac
# sc-fleet — membership marker
MEMBER
chmod +x "$T/extra/toolz"
ln -s "$T/bin/toolx" "$T/extra/toolx"
export SC_BIN_EXTRA="$T/extra"

SC="$T/bin/sc"
export SC_ART=1

# --- 1. the kit loads and defines the vocabulary ---------------------------------------------
( set -e; SC_TOOL=x; . "$KIT" ) >/dev/null 2>&1
check "kit: sources cleanly" test $? -eq 0
for fn in art_on sc_mark sc_splash sc_band sc_id row ok bad dim die warn; do
  out="$(SC_TOOL=x bash -c ". '$KIT'; declare -F $fn >/dev/null && echo yes" 2>&1)"
  check_eq "kit: defines $fn" "$out" "yes"
done

# --- 2. gating ------------------------------------------------------------------------------
# a clean environment each time: this suite exports SC_ART for everything else
gate() { SC_TOOL=wt env -u SC_ART -u SC_NO_ART -u WT_ART -u WT_NO_ART \
           bash -c "$1 . '$KIT'; art_on && echo on || echo off"; }
check_eq "gate: off when not a tty"         "$(gate '')"                      "off"
check_eq "gate: SC_ART forces on"           "$(gate 'export SC_ART=1;')"      "on"
check_eq "gate: WT_ART forces on"           "$(gate 'export WT_ART=1;')"      "on"
check_eq "gate: SC_NO_ART suppresses"       "$(gate 'export SC_NO_ART=1;')"   "off"
check_eq "gate: WT_NO_ART beats SC_ART"     "$(gate 'export SC_ART=1 WT_NO_ART=1;')" "off"
check_eq "gate: WT_ART beats SC_NO_ART"     "$(gate 'export SC_NO_ART=1 WT_ART=1;')" "on"

# --- 3. the shared mark fills the width budget -----------------------------------------------
mark="$("$T/bin/toolx" mark)"
check_eq "mark: spans the budget"          "${#mark}"  "72"
check_grep "mark: the brand plate"         '┫ ✦ ┣'    "$mark"
narrow="$(SC_W=40 "$T/bin/toolx" mark)"
check_eq "mark: honours SC_W"              "${#narrow}" "40"

# --- 4. the band ------------------------------------------------------------------------------
band="$("$T/bin/toolx" band new rv-sidecar)"
check_grep "band: carries the cap"         '^    ┫✦┣ toolx ' "$band"
check_grep "band: verb and detail"         'new · rv-sidecar$' "$band"
check "band: inside the budget"            test "${#band}" -le 72
long="$("$T/bin/toolx" band averylongverbname averylongdetailstringhere)"
check "band: long tail still one line"     test "$(wc -l <<<"$long")" -eq 1

# --- 5. sigils are pre-padded to four ---------------------------------------------------------
while IFS=$'\t' read -r _ _ _ r0 r1 r2; do
  check_eq "sigil toolx: row 0 is four wide" "${#r0}" "4"
  check_eq "sigil toolx: row 1 is four wide" "${#r1}" "4"
  check_eq "sigil toolx: row 2 is four wide" "${#r2}" "4"
done < <("$T/bin/toolx" __id)
# Every real fleet member, not just wt: a sigil row that is not exactly four
# characters shears the roster, and bash pads by bytes while every glyph here
# is multibyte. Add a new tool to this list when it joins.
for tool in wt arm crew; do
  [[ -x "$SRC/$tool" ]] || { printf 'SKIP  no %s: sigil check\n' "$tool" >&2; continue; }
  while IFS=$'\t' read -r nm _ _ r0 r1 r2; do
    check_eq "sigil $tool: name matches"       "$nm"    "$tool"
    check_eq "sigil $tool: row 0 is four wide" "${#r0}" "4"
    check_eq "sigil $tool: row 1 is four wide" "${#r1}" "4"
    check_eq "sigil $tool: row 2 is four wide" "${#r2}" "4"
    # sc ls prints the name with %-7s, so a longer name breaks alignment
    check "sigil $tool: name fits the roster column" test "${#nm}" -le 7
  done < <("$SRC/$tool" __id)
done

# --- 6. the id record --------------------------------------------------------------------------
id="$("$T/bin/toolx" __id)"
check_eq "id: six tab-separated fields"    "$(awk -F'\t' '{print NF}' <<<"$id")" "6"
check_grep "id: name first"                '^toolx\b'  "$id"
wtid="$("$SRC/wt" __id)"
check_grep "id: wt answers"                "$(printf '^wt\t')" "$wtid"
check_grep "id: wt tagline"                'one worktree per topic' "$wtid"

# --- 7. the roster ------------------------------------------------------------------------------
ls_out="$("$SC" ls)"
check_grep "roster: lists the member"      'toolx'     "$ls_out"
check_grep "roster: shows the tagline"     'one thing per other thing' "$ls_out"
check_nogrep "roster: hides the non-member" 'notatool' "$ls_out"
check "roster: never ran the non-member"   test ! -e "$T/SENTINEL"
check_grep "roster: a member in the extra directory is listed" 'toolz' "$ls_out"
check_eq "roster: a symlink to a member is one entry, not two" "$(grep -c 'toolx' <<<"$ls_out")" "1"
check_eq "roster: extra directory unset means this directory only" "$(SC_BIN_EXTRA= "$SC" ls | grep -c toolz)" "0"
check_eq "dispatch: an extra-directory member runs" "$("$SC" toolz echo hi)" "toolz saw: hi"
r="$("$SC" __roster)"
check_eq "roster: __roster has three fields per line" "$(awk -F'\t' 'NF!=3' <<<"$r" | wc -l | tr -d ' ')" "0"
check_grep "roster: __roster ends with sc itself" $'^sc\t' "$r"

# --- 7b. the project logo ---------------------------------------------------
bare="$(SC_ART=1 "$SC")"
check_grep "logo: wordmark"                '█▀▀▀▀ █▀▀▀█ ▄▀▀▀▄' "$bare"
check_grep "logo: the cowboy's hat"       '\(_{13}\)' "$bare"
check_grep "logo: his bandana"             'vvvvv'    "$bare"
check_grep "logo: his boots"               '\(___\) \(___\)' "$bare"
check_grep "logo: the terminal runs sc"    '\| \| \$ sc' "$bare"
check_grep "logo: the saguaro"             '\| \|\| \|_\| \|' "$bare"
check_grep "logo: roster still follows"    'toolx'    "$bare"

# the compact logo the menu uses under 40 rows: the wordmark under the stars
small="$(SC_TOOL=x bash -c ". '$KIT'; SC_ART=1 sc_logo_small")"
check_eq "logo: small is four lines" "$(wc -l <<<"$small" | tr -d ' ')" "4"
check_grep "logo: small carries the wordmark" '█▀▀▀▀ █▀▀▀█ ▄▀▀▀▄' "$small"
check_nogrep "logo: small has no scene" 'vvvvv' "$small"

# the menu's header wears the theme: the function captures sc's stdout, so
# the kit must be re-sourced with colour on when the menu will draw
hdr="$(SC_COLOR=1 "$SC" __header)"
check_grep "menu header: coloured when the menu will draw" $'\e\\[38;2;' "$hdr"
check_grep "menu header: carries the wordmark" '█▀▀▀▀ █▀▀▀█ ▄▀▀▀▄' "$hdr"
check_nogrep "menu header: plain through a pipe with no terminal" $'\e' "$("$SC" __header)"
check_nogrep "menu header: NO_COLOR wins over the forced colour" $'\e' "$(NO_COLOR=1 SC_COLOR=1 "$SC" __header)"

# asked for by name, so it draws even into a pipe
named="$("$SC" logo)"
check_grep "logo: sc logo works piped"     '█▀▀▀▀ █▀▀▀█ ▄▀▀▀▄' "$named"
check_nogrep "logo: sc logo omits roster"  'toolx'    "$named"
check_nogrep "logo: no colour codes in a pipe" $'\e' "$named"
colour="$(SC_COLOR=1 SC_THEME=/nonexistent "$SC" logo)"
check_grep "logo: coloured when colour is on" $'\e\\[38;2;' "$colour"

# gating still applies to the bare invocation
quiet="$(SC_NO_ART=1 "$SC" 2>&1)"
check_nogrep "logo: SC_NO_ART hides it"    '█▀▀▀▀'    "$quiet"
check_grep "logo: roster survives no-art"  'toolx'    "$quiet"

# nothing in the banner may run past the column budget
widest="$(printf '%s\n' "$named" | awk '{ n = length($0); if (n > m) m = n } END { print m+0 }')"
check "logo: inside the 72 column budget"  test "$widest" -le 72


# --- 8. dispatch ---------------------------------------------------------------------------------
check_eq "dispatch: forwards args"  "$("$SC" toolx echo a b c)" "toolx saw: a b c"
check_eq "dispatch: bare tool same" "$("$T/bin/toolx" echo a b c)" "$("$SC" toolx echo a b c)"

out="$("$SC" nosuch 2>&1)"; rc=$?
check "refuse: unknown tool exits nonzero" test $rc -ne 0
check_grep "refuse: unknown tool message"  'no tool named nosuch' "$out"

out="$("$SC" notatool 2>&1)"; rc=$?
check "refuse: non-member exits nonzero"   test $rc -ne 0
check_grep "refuse: non-member message"    'not a fleet tool' "$out"
check "refuse: non-member never executed"  test ! -e "$T/SENTINEL"

# --- 8b. the menu is derived from the header blocks ---------------------------------------------
# Same doctrine as the roster: no manifest. A verb is in the menu because its
# header line is; the fixture's header is the whole spec of what the parser
# must handle (bare tool, <required>, [optional], a continuation line).
m="$("$SC" __menu)"
check_grep "menu: the bare tool is an entry"            $'^toolx\ttoolx\tthe default thing\t0$' "$m"
check_grep "menu: a required placeholder needs args"    $'^toolx\ttoolx echo <words>\techo them back\t1$' "$m"
check_grep "menu: a flag-only verb runs as picked"      $'^toolx\ttoolx band \\[verb\\]\t.*\t0$' "$m"
check_grep "menu: a continuation line joins the entry"  $'^toolx\ttoolx mark\tthe mark, on a line that continues below it\t0$' "$m"
check_grep "menu: sc contributes its own verbs"         $'^sc\tsc ls\tthe roster\t0$' "$m"
check_nogrep "menu: a non-member is never listed"       'notatool' "$m"
check_eq "menu: every line has four fields" "$(awk -F'\t' 'NF!=4' <<<"$m" | wc -l | tr -d ' ')" "0"
m1="$("$SC" __menu toolx)"
check_eq "menu: a tool alone filters to it" "$(cut -f1 <<<"$m1" | sort -u | tr '\n' ' ')" "toolx "
check_grep "usage: the header block for the preview"    '^  toolx echo <words>' "$("$SC" __usage toolx)"
out="$("$SC" __usage notatool 2>&1)"; rc=$?
check "usage: a non-member is refused" test $rc -ne 0
"$SC" __pick </dev/null >/dev/null 2>&1; rc=$?
check_eq "pick: no terminal means no menu, exit 2" "$rc" "2"
check_grep "bare sc through a pipe is still the roster" 'toolx' "$("$SC" 2>/dev/null)"

# the real fleet's headers parse the way the doctrine says
real="$("$SRC/sc" __menu)"
check_grep "menu(real): rig doctor runs as picked"      $'\trig doctor \\[--disk\\]\t.*\t0$' "$real"
check_grep "menu(real): rig push prefills for its message" $'\trig push \\[-m MSG\\]\t.*\t1$' "$real"
check_grep "menu(real): wt new prefills for its slug"   $'\twt new <slug>.*\t1$' "$real"
check_grep "menu(real): wt ls runs as picked"           $'\twt ls \\[-a\\].*\t0$' "$real"
check_grep "menu(real): wt carries descriptions now"    $'\twt sync\trebase this topic' "$real"
check_grep "menu(real): tk carries descriptions now"    $'\ttk doctor\tis the board' "$real"
check_grep "menu: the extra-directory member's verbs are in"  $'^toolz\ttoolz go <where>\tgoes there\t1$' "$m"
if command -v dye >/dev/null 2>&1 && grep -qm1 '^# sc-fleet' "$(readlink -f "$(command -v dye)")"; then
  realx="$(SC_BIN_EXTRA="$HOME/.local/bin" "$SRC/sc" __menu dye)"
  check_grep "menu(real): dye joins through ~/.local/bin"  $'^dye\tdye <name>\tflip: re-point.*\t1$' "$realx"
fi
check_eq "menu(real): every line has four fields" "$(awk -F'\t' 'NF!=4' <<<"$real" | wc -l | tr -d ' ')" "0"

# --- 9. a tool still runs without the kit ----------------------------------------------------------
mkdir -p "$T/bare"
cp "$SRC/wt" "$T/bare/wt"
out="$("$T/bare/wt" --help 2>&1)"; rc=$?
check "fallback: wt runs with no lib/"     test $rc -eq 0
check_grep "fallback: usage intact"        'wt init'  "$out"
check_nogrep "fallback: no marker leak"    '^sc-fleet' "$out"

# --- 10. the palette has not drifted from the theme --------------------------------------------------
drift="$(python3 - "$KIT" "$THEME" <<'PY'
import json, re, sys
kit, theme = open(sys.argv[1], encoding="utf-8").read(), json.load(open(sys.argv[2], encoding="utf-8"))
ov = theme["overrides"]
want = {"A_LIME": ov["claude"], "A_SEA": ov["success"], "A_LAV": ov["remember"],
        "A_FG": ov["text"], "A_ERR": ov["error"], "A_WARN": ov["warning"]}
bad = []
for name, hexv in want.items():
    m = re.search(re.escape(name) + r"=\$'\\e\[38;2;(\d+);(\d+);(\d+)m'", kit)
    if not m:
        bad.append(name + ": not found in the kit"); continue
    got = "#%02x%02x%02x" % tuple(int(g) for g in m.groups())
    if got != hexv.lower():
        bad.append("%s: kit %s, theme %s" % (name, got, hexv.lower()))
print("; ".join(bad))
PY
)"
check_eq "palette: builtins match voidrunner.json" "$drift" ""

# --- 11. the kit wears the bundle when readable, the builtins otherwise ------------------------
printf '%s\n' "  A_LIME=\$'\\e[38;2;1;2;3m'" > "$T/pal.sh"
got="$(SC_COLOR=1 SC_THEME="$T/pal.sh" bash -c '. "$1"; printf "%s" "$A_LIME" | od -An -c | tr -d " \n"' _ "$KIT")"
check_eq "bundle: SC_THEME palette wins"     "$got" '033[38;2;1;2;3m'
got="$(SC_COLOR=1 SC_THEME=/nonexistent bash -c '. "$1"; printf "%s" "$A_LIME" | od -An -c | tr -d " \n"' _ "$KIT")"
check_eq "bundle: builtin when unreadable"   "$got" '033[38;2;189;254;88m'
printf '%s\n' "  SC_RGB_cursor='1;2;3'" > "$T/pal_logo.sh"
got="$(SC_COLOR=1 SC_ART=1 SC_THEME="$T/pal_logo.sh" bash -c '. "$1"; sc_logo' _ "$KIT")"
check_grep "bundle: the logo wears its roles" '38;2;1;2;3m' "$got"

# --- sc config ---------------------------------------------------------------
mkdir -p "$SC_CONFIG_HOME"
out="$(SC_CONFIG_HOME="$T/nocfg" "$SC" config)"
check_grep "config: no files says defaults" 'built-in defaults' "$out"
printf 'notes=~/n1\nwt.forge=a.example gitlab\nwt.forge=b.example forgejo\n' > "$SC_CONFIG_HOME/config"
printf 'notes=~/n2\n' > "$SC_CONFIG_HOME/config.local"
out="$("$SC" config)"
check_grep "config: lists a key with its source" '^notes +~/n2 +config.local' "$out"
check_grep "config: a list shows every value" 'a.example gitlab  \|  b.example forgejo' "$out"
check_eq "config: KEY prints value and source" "$("$SC" config notes)" "$(printf 'notes\t%s\tconfig.local' "$HOME/n2")"
check_eq "config: list KEY prints one per line" "$("$SC" config wt.forge | wc -l)" "2"
check_grep "config: unset KEY says so" 'unset' "$("$SC" config nope.key)"
check_eq "config: unset KEY exits 0" "$("$SC" config nope.key >/dev/null 2>&1; echo $?)" "0"
check_grep "config: in sc's usage" 'sc config' "$("$SC" --help 2>&1)"
rm -f "$SC_CONFIG_HOME/config" "$SC_CONFIG_HOME/config.local"

# --- summary -------------------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
