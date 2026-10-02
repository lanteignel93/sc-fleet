#!/usr/bin/env bash
# Offline test suite for bin/arm and shell/fleet.zsh
# Run: bash tests/test_arm.sh
#
# Builds a throwaway tmux server on its own socket so the real sessions are
# never touched, plus a fake fleet.zsh under mktemp. No network.
#
# The three assertions that matter are the regressions from 2026-09-21:
# editor and Claude panes are skipped with a stated reason, copy-mode panes
# are skipped, and nothing typed into a directory containing `src` trips
# zsh's `correct 'sc' to 'src'` prompt.

set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM="$HERE/../bin/arm"
FLEETSRC="$HERE/../shell/fleet.zsh"
T="$(mktemp -d -t arm-test.XXXXXX)"
export SC_CONFIG_HOME="$T/cfg"  # never read the real ~/.config/sc-fleet
SOCK="$T/tmux.sock"
trap 'tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"' EXIT

export NO_COLOR=1 ARM_NO_ART=1

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
check_eq()    { [[ "$2" == "$3" ]] && pass || fail "$1: expected [$3] got [$2]"; }
check_grep()  { grep -qE -- "$2" <<<"$3" && pass || fail "$1: no match for /$2/ in: $3"; }
check_nogrep(){ grep -qE -- "$2" <<<"$3" && fail "$1: unexpected /$2/ in: $3" || pass; }
expect_fail() { local d="$1"; shift
                local out; out="$("$@" 2>&1)"; local rc=$?
                [[ $rc -ne 0 ]] && pass || fail "$d: expected failure, got rc=0: $out"
                printf '%s' "$out"; }
run() { "$@" 2>&1; }

have_tmux=1; command -v tmux >/dev/null 2>&1 || have_tmux=0
have_zsh=1;  command -v zsh  >/dev/null 2>&1 || have_zsh=0

# --- 1. fleet contract ------------------------------------------------------
o="$(run "$ARM" __id)"
check_eq "id: field count" "$(awk -F'\t' '{print NF}' <<<"$o")" 6
check_eq "id: name" "$(cut -f1 <<<"$o")" arm
for i in 4 5 6; do
  r="$(cut -f$i <<<"$o")"
  check_eq "id: sigil row $((i-4)) is 4 chars" "${#r}" 4
done
check "marker: last line is the sc-fleet marker" \
  bash -c "tail -1 '$ARM' | grep -q '^# sc-fleet'"
check_nogrep "marker: never printed in output" '^# sc-fleet' "$(run "$ARM" --help)"

# --- 2. kit-less fallback ---------------------------------------------------
mkdir -p "$T/bare"
cp "$ARM" "$T/bare/arm"
o="$(run "$T/bare/arm" --help)"
check_eq "bare: --help exits 0 without lib/" "$?" 0
check_grep "bare: usage survives" 'every shell carrying' "$o"

# --- 3. fleet.zsh is idempotent --------------------------------------------
if [[ $have_zsh -eq 1 ]]; then
  o="$(zsh -f -c '
    autoload -Uz compinit; compinit -u -d '"$T"'/zcompdump 2>/dev/null
    before="$PATH"
    for i in {1..10}; do . '"$FLEETSRC"'; done
    print -r -- "fpathcount=$(print -l $fpath | grep -c zsh_functions)"
    print -r -- "pathsame=$([[ $PATH == $before ]] && echo yes || echo no)"
    for f in wt sc arm; do print -r -- "fn_$f=$(( $+functions[$f] ))"; done
  ' 2>&1)"
  check_grep "fleet: one fpath entry after 10 sources" 'fpathcount=[01]$' "$o"
  check_grep "fleet: PATH untouched" 'pathsame=yes' "$o"
  check_grep "fleet: wt defined"  'fn_wt=1'  "$o"
  check_grep "fleet: sc defined"  'fn_sc=1'  "$o"
  check_grep "fleet: arm defined" 'fn_arm=1' "$o"
  check "fleet: parses under zsh -n" zsh -n "$FLEETSRC"
else
  printf 'SKIP  no zsh: fleet.zsh checks\n' >&2
fi

# --- 4. refusals ------------------------------------------------------------
o="$(TMUX= expect_fail "sweep: refuses outside tmux" env -u TMUX "$ARM" -a)"
check_grep "sweep: names tmux in the refusal" 'tmux' "$o"

o="$(ARM_FLEET="$T/nope.zsh" TMUX=fake expect_fail "sweep: refuses a missing fleet.zsh" \
      env ARM_FLEET="$T/nope.zsh" TMUX=fake "$ARM" -a)"
check_grep "sweep: names install.sh" 'install.sh' "$o"

o="$(expect_fail "unknown verb refuses" "$ARM" bogus)"
check_grep "unknown verb names --help" 'arm --help' "$o"

# --- 5. doctor --------------------------------------------------------------
o="$(ARM_FLEET="$T/nope.zsh" run "$ARM" doctor)"
check_grep "doctor: reports a missing fleet" 'missing' "$o"
o="$(ARM_FLEET="$FLEETSRC" run "$ARM" doctor)"
check_grep "doctor: reports a present fleet" 'fleet' "$o"
check_nogrep "doctor: no 'missing' when present" 'missing' "$o"

# --- 6. pane selection, on a private tmux server ---------------------------
if [[ $have_tmux -eq 1 ]]; then
  # A directory literally containing `src`, which is what triggers zsh's
  # argument autocorrect on the word `sc`.
  mkdir -p "$T/work/src"
  cat > "$T/fake-fleet.zsh" <<'EOF'
# fake fleet payload: proves the source landed, changes nothing else
export ARM_TEST_MARK=armed
EOF
  tmux -S "$SOCK" new-session -d -s t -x 120 -y 40 -c "$T/work" 2>/dev/null
  sleep 1
  tmux -S "$SOCK" split-window -d -t t -c "$T/work" 2>/dev/null
  sleep 1
  # pane 2 runs a pager, standing in for nvim/claude: not a shell
  tmux -S "$SOCK" send-keys -t t.2 'less /etc/hostname' Enter 2>/dev/null
  sleep 2

  # arm inspects the DEFAULT tmux server via $TMUX, so point it at ours.
  TM="$(tmux -S "$SOCK" display-message -p '#{socket_path},#{pid},0' 2>/dev/null)"

  o="$(TMUX="$TM" ARM_FLEET="$T/fake-fleet.zsh" run "$ARM" ls)"
  check_grep "ls: header present" 'PANE' "$o"
  check_grep "ls: a shell pane would be armed" 'would arm' "$o"
  check_grep "ls: the pager pane is skipped with a reason" 'skip . running (less|pager)' "$o"

  # copy mode must be skipped
  tmux -S "$SOCK" copy-mode -t t.1 2>/dev/null; sleep 1
  o="$(TMUX="$TM" ARM_FLEET="$T/fake-fleet.zsh" run "$ARM" ls)"
  check_grep "ls: copy-mode pane is skipped" 'in copy mode' "$o"
  tmux -S "$SOCK" send-keys -X -t t.1 cancel 2>/dev/null; sleep 1

  # the sweep sends a source line, and only a source line
  o="$(TMUX="$TM" ARM_FLEET="$T/fake-fleet.zsh" run "$ARM" -s)"
  check_grep "sweep: reports a total" 'total' "$o"
  check_grep "sweep: armed at least one pane" 'armed' "$o"
  sleep 2
  cap="$(tmux -S "$SOCK" capture-pane -p -S -20 -t t.1 2>/dev/null)"
  # Guard the nogrep assertions below: they pass vacuously on empty input,
  # so prove there IS pane content before drawing conclusions from absence.
  check "sweep: captured pane content is non-empty" test -n "$cap"
  check_grep "sweep: sent a source of the fleet file" 'source .*fake-fleet' "$cap"
  check_nogrep "sweep: no autocorrect prompt in a dir containing src" 'nyae' "$cap"
  check_nogrep "sweep: never types a bare tool name" '^[^ ]*❯ (sc|arm|wt) ' "$cap"

  # restart mode: the pane's shell is exec'd, so a (non-exported: the environment
  # survives exec, shell state does not) variable set before is gone after
  tmux -S "$SOCK" send-keys -t t.1 'ARM_TEST_VAR=before' Enter 2>/dev/null; sleep 1
  o="$(TMUX="$TM" ARM_FLEET="$T/fake-fleet.zsh" run "$ARM" -s -x)"
  check_grep "restart: reports restarted panes" 'restarted' "$o"
  check_grep "restart: the pager pane is still skipped" 'skipped' "$o"
  sleep 3
  # quoted: an empty [] is a glob to zsh and the line would die with 'no matches found'
  tmux -S "$SOCK" send-keys -t t.1 'echo "ARM_TEST_VAR=[$ARM_TEST_VAR]"' Enter 2>/dev/null; sleep 2
  cap="$(tmux -S "$SOCK" capture-pane -p -S -30 -t t.1 2>/dev/null)"
  check_grep "restart: sent an exec of the shell" 'exec zsh' "$cap"
  check_grep "restart: the shell really restarted (variable gone)" 'ARM_TEST_VAR=\[\]' "$cap"
  o="$(TMUX="$TM" run "$ARM" -x 2>&1 || true)"
  check_grep "restart: -x without a sweep refuses" 'needs a sweep' "$o"
else
  printf 'SKIP  no tmux: pane-selection checks\n' >&2
fi

# --- 7. man page ------------------------------------------------------------
MAN="$HERE/../man/arm.1"
check "man: page exists" test -f "$MAN"
if command -v man >/dev/null 2>&1; then
  o="$(MANWIDTH=100 man -P cat -l "$MAN" 2>/dev/null)"
  check_grep "man: NAME section" 'arm . re-arm running shells' "$o"
  # every verb needs its own .SS so `arm help <verb>` can anchor on it
  for v in "-a, arm --all" "ls" "doctor"; do
    check_grep "man: anchor for $v" "^   arm $v" "$o"
  done
  check_grep "man: documents the autocorrect hazard" 'nyae' "$o"
  check_grep "man: documents the bootstrap escape hatch" 'rehash' "$o"
fi


# --- art: every banner obeys the grammar and the width budget ---------------
# A banner is drawn only for a human, so these assert on forced art with the
# palette empty: SC_ART on, stdout not a tty, which is what makes the glyphs
# exactly comparable.
# The suite exports ARM_NO_ART, and "off beats on" by design, so the
# variable has to be UNSET for this check rather than overridden.
art_lines() { env -u ARM_NO_ART NO_COLOR=1 ARM_ART=1 "$@" 2>/dev/null |
              sed 's/\x1b\[[0-9;]*m//g' |
              grep -E '[━─╌●◆◇┿┷┯┳╂╇╪┫✦┣▶→]' || true; }

for verb in 'doctor'; do
  o="$(art_lines "$ARM" $verb)"
  check "art: $verb draws something" test -n "$o"
  w="$(awk '{print length}' <<<"$o" | sort -rn | head -1)"
  check "art: $verb fits 72 columns (was ${w:-0})" test "${w:-0}" -le 72
  # the three retired glyphs must never come back
  check_nogrep "art: $verb uses no retired glyph" '[✂⇒⇢]' "$o"
done

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
