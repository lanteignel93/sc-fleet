#!/usr/bin/env bash
# Offline test suite for the fleet config readers — run: bash tests/test_conf.sh
#
# lib/scconf.sh (bash) and sc_conf() in tasks.py (python) read the same files
# with the same grammar. Every case asserts the expected value AND that the two
# readers agree, so they cannot drift. Config lives under mktemp via
# SC_CONFIG_HOME; the real ~/.config/sc-fleet is never read.
set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"
T="$(mktemp -d -t conf-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# shellcheck source=../lib/scconf.sh
. "$LIB/scconf.sh"
export SC_CONFIG_HOME="$T/cfg"
mkdir -p "$SC_CONFIG_HOME"
U="${USER:-$(id -un)}"

cat > "$SC_CONFIG_HOME/config" <<EOF
# fleet config
notes = ~/notes-root          # trailing comment
wt.root=/data/\$USER
wt.store=\${HOME}/store
wt.forge=github.com github
wt.forge=*gitlab* gitlab
rig.push_delegate=~/journal ~/bin/sync.sh
url=https://example.org/a=b#frag
empty=
dup=first
dup=second
  spaced.key   =   spaced value
tilde=~
evil=\$(touch $T/pwned)
not a line
EOF
cat > "$SC_CONFIG_HOME/config.local" <<'EOF'
dup=local
wt.forge=forge.example.org forgejo
empty=
EOF

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
check_eq() { [[ "$2" == "$3" ]] && pass || fail "$1: expected [$3] got [$2]"; }

py() {  # FUNC KEY [DEFAULT]
  python3 - "$LIB" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import tasks
fn, key = sys.argv[2], sys.argv[3]
if fn == "all":
    print("\n".join(tasks.sc_conf_all(key)), end="")
elif fn == "home":
    print(tasks.sc_conf_home(), end="")
else:
    print(tasks.sc_conf(key, sys.argv[4] if len(sys.argv) > 4 else ""), end="")
PY
}

# case DESC KEY DEFAULT EXPECTED : scalar, both readers
case_one() {
  check_eq "bash: $1" "$(sc_conf "$2" "$3")" "$4"
  check_eq "python: $1" "$(py one "$2" "$3")" "$4"
}
# case_all DESC KEY EXPECTED : list, both readers
case_all() {
  check_eq "bash: $1" "$(sc_conf_all "$2" | sed -e '$a\' | sed '/^$/d')" "$3"
  check_eq "python: $1" "$(py all "$2")" "$3"
}

# --- 1. scalars --------------------------------------------------------------
case_one "tilde at the start of a value"     notes          DEF "$HOME/notes-root"
case_one "\$USER expands"                     wt.root        DEF "/data/$U"
case_one "\${HOME} expands"                   wt.store       DEF "$HOME/store"
case_one "last value wins, local over config" dup           DEF "local"
case_one "split on the first ="              url            DEF "https://example.org/a=b#frag"
case_one "empty value means unset"           empty          DEF "DEF"
case_one "key and value whitespace trimmed"  spaced.key     DEF "spaced value"
case_one "a bare ~ is home"                  tilde          DEF "$HOME"
case_one "absent key gives the default"      nope.key       DEF "DEF"
case_one "absent key, no default, is empty"  nope.key       ""  ""

# --- 2. lists ----------------------------------------------------------------
case_all "local entries first, then config's" wt.forge \
  "$(printf 'forge.example.org forgejo\ngithub.com github\n*gitlab* gitlab')"
case_all "~/ expands at the start of every word" rig.push_delegate "$HOME/journal $HOME/bin/sync.sh"
case_all "absent list key is empty" nope.key ""

# --- 3. read, never evaluated -------------------------------------------------
out="$(sc_conf evil)"
check_eq "bash: command substitution is text" "$out" "\$(touch $T/pwned)"
check_eq "python: command substitution is text" "$(py one evil)" "\$(touch $T/pwned)"
[[ -e "$T/pwned" ]] && fail "a config value was executed" || pass

# --- 4. the config home ------------------------------------------------------
check_eq "home: SC_CONFIG_HOME wins" "$(sc_conf_home)" "$T/cfg"
check_eq "home: python agrees" "$(py home x)" "$T/cfg"
check_eq "home: XDG_CONFIG_HOME next" "$(SC_CONFIG_HOME= XDG_CONFIG_HOME=/x sc_conf_home)" "/x/sc-fleet"
check_eq "home: python XDG" "$(SC_CONFIG_HOME= XDG_CONFIG_HOME=/x py home x)" "/x/sc-fleet"
check_eq "home: ~/.config last" "$(SC_CONFIG_HOME= XDG_CONFIG_HOME= sc_conf_home)" "$HOME/.config/sc-fleet"
check_eq "home: python ~/.config" "$(SC_CONFIG_HOME= XDG_CONFIG_HOME= py home x)" "$HOME/.config/sc-fleet"

# --- 5. no files at all ------------------------------------------------------
check_eq "bash: missing files give the default" "$(SC_CONFIG_HOME="$T/none" sc_conf notes D)" "D"
check_eq "python: missing files give the default" "$(SC_CONFIG_HOME="$T/none" py one notes D)" "D"

# --- 6. the reader prints nothing when sourced ---------------------------------
check_eq "sourcing is silent" "$(bash -c ". '$LIB/scconf.sh'")" ""

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
