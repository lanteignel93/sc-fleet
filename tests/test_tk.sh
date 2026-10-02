#!/usr/bin/env bash
# Offline test suite for bin/tk — run: bash tests/test_tk.sh
#
# Every case runs against a throwaway board under mktemp via TK_STORE, so the
# real board is never touched. Art is forced on with TK_ART
# where a band is expected; colours stay empty because stdout is not a tty.
set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin"
LIB="$HERE/../lib"
TK="$BIN/tk"
T="$(mktemp -d -t tk-test.XXXXXX)"
export SC_CONFIG_HOME="$T/cfg"  # never read the real ~/.config/sc-fleet
trap 'rm -rf "$T"' EXIT

export TK_STORE="$T/board"
mkdir -p "$TK_STORE"
BOARD="$TK_STORE/tasks.md"
fresh() { printf '# Work tasks\n\n## Inbox\n\n## Research\n\n## Backlog\n' > "$BOARD"; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
check_eq() { [[ "$2" == "$3" ]] && pass || fail "$1: expected [$3] got [$2]"; }
check_grep() { grep -qE -- "$2" <<<"$3" && pass || fail "$1: no match for /$2/ in: $3"; }
check_nogrep() { grep -qE -- "$2" <<<"$3" && fail "$1: unexpected /$2/" || pass; }
rc_of() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# --- 1. fleet membership ----------------------------------------------------
check "member: marker present"  grep -qm1 '^# sc-fleet' "$TK"
id="$("$TK" __id)"
check_eq "member: six tsv fields" "$(awk -F'\t' '{print NF}' <<<"$id")" "6"
check_grep "member: name first"   '^tk\b'                "$id"
check_grep "member: tagline"      'one queue, one active' "$id"
while IFS=$'\t' read -r _ _ _ r0 r1 r2; do
  check_eq "member: sigil row 0 is four wide" "${#r0}" "4"
  check_eq "member: sigil row 1 is four wide" "${#r1}" "4"
  check_eq "member: sigil row 2 is four wide" "${#r2}" "4"
done <<<"$id"
check_grep "member: listed by sc"  'tk'  "$(SC_ART=1 "$BIN/sc" ls)"

# --- 2. read-only verbs -----------------------------------------------------
fresh
check_eq "path: prints the board"  "$("$TK" path)"  "$BOARD"
check_eq "doctor: exits 0"         "$(rc_of "$TK" doctor)" "0"
out="$(TK_ART=1 "$TK" ls)"
check_nogrep "ls: read-only, no band"      '┫✦┣'  "$out"
check_nogrep "doctor: read-only, no band"  '┫✦┣'  "$(TK_ART=1 "$TK" doctor)"

# --- 3. new, and the band -----------------------------------------------------
fresh
out="$(TK_ART=1 "$TK" new "alpha task" --section Inbox --due 2026-12-01)"
check_grep "new: band prints"        '┫✦┣ tk '            "$out"
check_grep "new: band names the verb" 'new · alpha task'  "$out"
check_grep "new: engine output kept"  'added to Inbox'    "$out"
check_grep "new: lands on the board"  '^- \[ \] alpha task' "$(cat "$BOARD")"
check_grep "new: due date written"    '2026-12-01'        "$(cat "$BOARD")"

# --- 4. ls -a is translated to the engine's --all ---------------------------
check_grep "ls -a: shows the whole board" 'alpha task' "$("$TK" ls -a)"
check_grep "ls -a: carries line numbers"  '[0-9]+ +- \[ \]' "$("$TK" ls -a)"

# --- 5. the state machine ---------------------------------------------------
check_grep "start: marks in progress" '^- \[/\] alpha task' \
  "$("$TK" start "alpha" >/dev/null; cat "$BOARD")"
check_grep "done: marks complete"     '^- \[x\] alpha task' \
  "$("$TK" done "alpha" >/dev/null; cat "$BOARD")"
check_grep "done: stamps the date"    '✅ [0-9]{4}-[0-9]{2}-[0-9]{2}' "$(cat "$BOARD")"

fresh
"$TK" new "beta task" --section Research >/dev/null
"$TK" move "beta" --to Backlog >/dev/null
check_grep "move: lands in the new section" 'Backlog' \
  "$(awk '/^## Backlog/{f=1} f&&/beta task/{print "Backlog"}' "$BOARD")"

fresh
"$TK" new "gamma task" --section Inbox --due 2026-10-01 >/dev/null
"$TK" defer "gamma" 2026-11-15 >/dev/null
check_grep "defer: rewrites the due date" '2026-11-15' "$(cat "$BOARD")"

fresh
"$TK" new "delta task" --section Inbox >/dev/null
"$TK" cancel "delta" >/dev/null
check_grep "cancel: marks cancelled" '^- \[-\] delta task' "$(cat "$BOARD")"

# --- 6. refusals: the band never claims what did not happen -----------------
fresh
out="$(TK_ART=1 "$TK" done "no such task anywhere" 2>&1)"
check_eq "refuse: no match exits 1"     "$(rc_of "$TK" done "no such task anywhere")" "1"
check_nogrep "refuse: no match, no band" '┫✦┣' "$out"
check_eq "refuse: unknown verb exits 1" "$(rc_of "$TK" frobnicate)" "1"
check_grep "refuse: unknown verb message" 'unknown subcommand frobnicate' \
  "$("$TK" frobnicate 2>&1)"

# --- 7. prune: a dry run changes nothing, so it gets no band ----------------
fresh
"$TK" new "epsilon" --section Inbox >/dev/null
"$TK" done "epsilon" >/dev/null
check_nogrep "prune --dry-run: no band" '┫✦┣' "$(TK_ART=1 "$TK" prune --dry-run 2>&1)"

# --- 8. gating --------------------------------------------------------------
fresh
check_nogrep "gate: TK_NO_ART wins"  '┫✦┣' \
  "$(TK_ART=1 TK_NO_ART=1 "$TK" new "zeta" 2>&1)"
check_nogrep "gate: silent on a pipe" '┫✦┣' \
  "$(env -u TK_ART -u SC_ART "$TK" new "eta" 2>&1)"

# --- 9. it still runs on a box with no kit ----------------------------------
mkdir -p "$T/bare/bin" "$T/bare/lib"
cp "$TK" "$T/bare/bin/tk"; cp "$LIB/tasks.py" "$T/bare/lib/tasks.py"
fresh
out="$("$T/bare/bin/tk" new "theta" --section Inbox 2>&1)"; rc=$?
check "fallback: runs with no lib/"  test $rc -eq 0
check_grep "fallback: engine still used" 'added to Inbox' "$out"
check_nogrep "fallback: no band without the kit" '┫✦┣' "$out"

# --- 9b. art: the queue strip is data, not chrome ---------------------------
fresh
"$TK" new "one"   --section Inbox >/dev/null
"$TK" new "two"   --section Inbox >/dev/null
"$TK" new "three" --section Inbox >/dev/null
"$TK" start "one" >/dev/null
"$TK" done  "two" >/dev/null

strip="$(TK_ART=1 "$TK" ls | grep -F '▶' | tail -1)"
check_grep "art: strip counts the active"  '1 active'  "$strip"
check_grep "art: strip counts the queued"  '1 queued'  "$strip"
check_grep "art: strip counts the closed"  '1 closed'  "$strip"
check_grep "art: active drawn as a diamond" '◆'        "$strip"
check_grep "art: queued drawn as a square"  '▪'        "$strip"
check_grep "art: sits on a heavy trunk"     '━━'       "$strip"

# read-only verbs carry the strip but never a band: the strip is data
lsout="$(TK_ART=1 "$TK" ls)"
check_grep   "art: ls carries the strip"    '▶'        "$lsout"
check_nogrep "art: ls still has no band"    '┫✦┣'      "$lsout"

# a state change carries both
chg="$(TK_ART=1 "$TK" done "three")"
check_grep "art: a change bands"            '┫✦┣ tk '  "$chg"
check_grep "art: a change restrips"         '2 closed' "$chg"

# machine contracts stay undecorated
check_nogrep "art: --json is never decorated" '▶'      "$(TK_ART=1 "$TK" ls --json 2>/dev/null)"
check_nogrep "art: gated off like everything" '▶'      "$(TK_NO_ART=1 "$TK" ls)"

# the splash is a diagram, and only on --help
help_out="$(TK_ART=1 "$TK" --help 2>/dev/null)"
check_grep "art: help draws the logo"       '╭─▪──▪'   "$help_out"
check_grep "art: help carries the mark"     '┫ ✦ ┣'    "$help_out"
check_nogrep "art: bare tk draws no logo"   '╭─▪──▪'   "$(TK_ART=1 "$TK" ls)"

# --- 10. TK_STORE really is the switch --------------------------------------
mkdir -p "$T/other"
printf '# Work tasks\n\n## Inbox\n' > "$T/other/tasks.md"
check_eq "store: TK_STORE redirects" "$(TK_STORE="$T/other" "$TK" path)" "$T/other/tasks.md"
TK_STORE="$T/other" "$TK" new "iota" --section Inbox >/dev/null
check_grep "store: writes to the other board" 'iota' "$(cat "$T/other/tasks.md")"
check_nogrep "store: leaves the first board alone" 'iota' "$(cat "$BOARD")"

# --- 11. the board follows config when TK_STORE is unset ----------------------
mkdir -p "$T/cfgk" "$T/notesk"
printf '# Work tasks\n\n## Inbox\n' > "$T/notesk/tasks.md"
printf 'notes=%s\n' "$T/notesk" > "$T/cfgk/config"
check_eq "conf: notes sets the board" "$(env -u TK_STORE SC_CONFIG_HOME="$T/cfgk" "$TK" path)" "$T/notesk/tasks.md"
printf 'tk.store=%s\n' "$T/other" >> "$T/cfgk/config"
check_eq "conf: tk.store beats notes" "$(env -u TK_STORE SC_CONFIG_HOME="$T/cfgk" "$TK" path)" "$T/other/tasks.md"
check_eq "conf: TK_STORE beats config" "$(TK_STORE="$T/notesk" SC_CONFIG_HOME="$T/cfgk" "$TK" path)" "$T/notesk/tasks.md"
check_eq "conf: neutral default is ~/notes" "$(env -u TK_STORE SC_CONFIG_HOME="$T/none" HOME="$T/fh" "$TK" path)" "$T/fh/notes/tasks.md"

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
