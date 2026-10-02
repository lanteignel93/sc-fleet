#!/usr/bin/env bash
# Offline test suite for install.sh — run: bash tests/test_install.sh
#
# Every case runs with HOME pointed at a throwaway directory, so the real
# ~/.local and rc files are never touched. The smoke test at the end runs the
# installed tools from that HOME; it never calls systemctl and unsets TMUX, so
# nothing reaches the real user manager or real panes.
set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd -P)"
T="$(mktemp -d -t install-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H"
export SC_CONFIG_HOME="$T/cfg" NO_COLOR=1
unset TMUX XDG_DATA_HOME ZDOTDIR
run() { HOME="$H" bash "$REPO/install.sh" "$@"; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
check() { local d="$1"; shift; if "$@"; then pass; else fail "$d"; fi; }
check_eq() { [[ "$2" == "$3" ]] && pass || fail "$1: expected [$3] got [$2]"; }
check_grep() { grep -qE -- "$2" <<<"$3" && pass || fail "$1: no match for /$2/ in: $3"; }
check_nogrep() { grep -qE -- "$2" <<<"$3" && fail "$1: unexpected /$2/" || pass; }

TOOLS="arm crew rig sc tk wt"

# --- 1. --check on an empty home reports and changes nothing ------------------
out="$(run --check 2>&1)"; rc=$?
check_eq "check: gaps exit 1" "$rc" 1
check_grep "check: MISSING lines" '^MISSING ' "$out"
check_grep "check: the stable home link is in the manifest" 'share/sc-fleet ->' "$out"
check_eq "check: creates nothing" "$(find "$H" -mindepth 1 | wc -l | tr -d ' ')" 0

# --- 2. apply ----------------------------------------------------------------
out="$(run 2>&1)"; rc=$?
check_eq "apply: exits 0" "$rc" 0
for t in $TOOLS; do
  check_eq "apply: $t on PATH" "$(readlink -f "$H/.local/bin/$t")" "$REPO/bin/$t"
  check_eq "apply: $t man page" "$(readlink -f "$H/.local/share/man/man1/$t.1")" "$REPO/man/$t.1"
done
for c in "$REPO"/completions/_*; do
  check_eq "apply: completion ${c##*/}" "$(readlink -f "$H/.zsh_functions/${c##*/}")" "$c"
done
check_eq "apply: the stable home link" "$(readlink -f "$H/.local/share/sc-fleet")" "$REPO"
check_eq "apply: bin holds exactly the fleet" "$(ls "$H/.local/bin" | tr '\n' ' ')" "$TOOLS "
check_grep "apply: names the shell line" 'fleet.zsh' "$out"
check "apply: no config written" test ! -e "$H/.config"
check "apply: no rc written" test ! -e "$H/.zshrc"
outside="$(find "$H" -type l -exec sh -c 'case "$1" in "$2"/*) ;; *) echo "$1";; esac' _ {} "$H" \;)"
check_eq "apply: every link it made lives under HOME" "$outside" ""

# --- 3. a re-run is quiet, and --check is then clean --------------------------
out="$(run 2>&1)"
check_nogrep "rerun: links nothing" '^Linked: ' "$out"
out="$(run --check 2>&1)"; rc=$?
check_eq "check: clean after apply" "$rc" 0
check_grep "check: says clean" '^install: clean' "$out"

# --- 4. drift kinds ----------------------------------------------------------
ln -sfn /nonexistent "$H/.local/bin/wt"
mkdir -p "$T/other/bin" "$T/other/lib"; : > "$T/other/lib/sckit.sh"
printf '#!/bin/sh\n' > "$T/other/bin/rig"; chmod +x "$T/other/bin/rig"
ln -sfn "$T/other/bin/rig" "$H/.local/bin/rig"
rm "$H/.local/share/man/man1/tk.1"; printf 'hand-made\n' > "$H/.local/share/man/man1/tk.1"
ln -s "$REPO/lib/sckit.sh" "$H/.local/bin/ghost"
out="$(run --check 2>&1)"; rc=$?
check_eq "drift: exits 1" "$rc" 1
check_grep "drift: a dangling link is WRONG" '^WRONG .*/wt -> /nonexistent' "$out"
check_grep "drift: another fleet copy is FOREIGN" '^FOREIGN .*/rig -> ' "$out"
check_grep "drift: a real file is NOTLINK" '^NOTLINK .*/tk\.1' "$out"
check_grep "drift: a stale link here is ORPHAN" '^ORPHAN .*/ghost' "$out"

out="$(run 2>&1)"
check_eq "repair: wt relinked" "$(readlink -f "$H/.local/bin/wt")" "$REPO/bin/wt"
check_eq "repair: rig taken back from the other copy" "$(readlink -f "$H/.local/bin/rig")" "$REPO/bin/rig"
check_grep "repair: the real file is backed up" '^Backed up: .*tk\.1' "$out"
check "repair: the backup exists" compgen -G "$H/.local/share/man/man1/tk.1.bak.*" >/dev/null
check "repair: an orphan is never removed by apply" test -L "$H/.local/bin/ghost"
out="$(run --check 2>&1)"
check_eq "repair: only the orphan is left" "$(grep -c '^[A-Z]\{5,7\} ' <<<"$out")" 1

# --- 5. smoke: the installed tools run from this HOME --------------------------
P="$H/.local/bin:$PATH"
rm -f "$H/.local/bin/ghost"
out="$(HOME="$H" PATH="$P" sc ls 2>&1)"; rc=$?
check_eq "smoke: sc ls exits 0" "$rc" 0
for t in arm crew rig tk wt; do check_grep "smoke: sc lists $t" "\\b$t\\b" "$out"; done
mkdir -p "$T/board"; printf '# Tasks\n\n## Inbox\n' > "$T/board/tasks.md"
out="$(HOME="$H" PATH="$P" TK_STORE="$T/board" tk new "smoke test" 2>&1)"; rc=$?
check_eq "smoke: tk new exits 0" "$rc" 0
check_grep "smoke: tk wrote the board" 'smoke test' "$(cat "$T/board/tasks.md")"
printf 'box=@defaults\nown=yes\n\nbox=atlas\nrole=dev\n' > "$T/boxes.conf"
out="$(HOME="$H" PATH="$P" RIG_BOXES="$T/boxes.conf" rig boxes --lint 2>&1)"; rc=$?
check_eq "smoke: rig boxes --lint exits 0" "$rc" 0
out="$(HOME="$H" PATH="$P" arm doctor 2>&1)"
check_grep "smoke: arm finds fleet.zsh beside itself" 'fleet\.zsh' "$out"
check_eq "smoke: sc config with no config" "$(HOME="$H" PATH="$P" sc config notes 2>&1 | grep -c unset)" 1

# --- 6. uninstall ------------------------------------------------------------
out="$(run --uninstall 2>&1)"; rc=$?
check_eq "uninstall: exits 0" "$rc" 0
check_eq "uninstall: no link into the checkout is left" \
  "$(find "$H" -type l -exec readlink -f {} \; | grep -c "^$REPO" || true)" 0
check "uninstall: the stable home link is gone" test ! -e "$H/.local/share/sc-fleet"
check "uninstall: the backup is untouched" compgen -G "$H/.local/share/man/man1/tk.1.bak.*" >/dev/null

# --- 7. arguments ------------------------------------------------------------
out="$(run --bogus 2>&1)"; rc=$?
check_eq "args: unknown option exits 1" "$rc" 1
check_grep "args: help prints the synopsis" 'install.sh --check' "$(run --help 2>&1)"

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
