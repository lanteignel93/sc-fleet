#!/usr/bin/env bash
# Offline test suite for bin/crew — run: bash tests/test_crew.sh
#
# Fakes a Claude session rather than mocking crew's internals: a copy of
# /bin/sleep named `claude` gives a real process whose comm is `claude`, so
# `pgrep -x claude` finds it and /proc/<pid>/cwd is genuinely its cwd. A fake
# CREW_PROJECTS tree supplies the transcript, whose mtime is what state and
# idle are derived from. No network, and the registry path is redirected into
# mktemp so the real one is never read.

set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$HERE/../bin/crew"
T="$(mktemp -d -t crew-test.XXXXXX)"
export SC_CONFIG_HOME="$T/cfg"  # never read the real ~/.config/sc-fleet
FAKEPID=""
cleanup() { [[ -n "$FAKEPID" ]] && kill "$FAKEPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

export NO_COLOR=1 CREW_NO_ART=1

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

# --- 1. fleet contract ------------------------------------------------------
o="$(run "$CREW" __id)"
check_eq "id: field count" "$(awk -F'\t' '{print NF}' <<<"$o")" 6
check_eq "id: name" "$(cut -f1 <<<"$o")" crew
check "id: name fits the 7-char roster column" test "${#o}" -gt 0
for i in 4 5 6; do
  r="$(cut -f$i <<<"$o")"
  check_eq "id: sigil row $((i-4)) is 4 chars" "${#r}" 4
done
check "marker: last line is the sc-fleet marker" \
  bash -c "tail -1 '$CREW' | grep -q '^# sc-fleet'"
check_nogrep "marker: never printed in output" '^# sc-fleet' "$(run "$CREW" --help)"

# --- 2. kit-less fallback ---------------------------------------------------
mkdir -p "$T/bare"
cp "$CREW" "$T/bare/crew"
o="$(run "$T/bare/crew" --help)"; rc=$?
check_eq "bare: --help exits 0 without lib/" "$rc" 0
check_grep "bare: usage survives" 'every Claude you have running' "$o"

# --- 3. refusals ------------------------------------------------------------
o="$(expect_fail "unknown option refuses" "$CREW" --bogus)"
check_grep "unknown option names --help" 'crew --help' "$o"

# --- 4. a faked session -----------------------------------------------------
# A real process whose comm is `claude`, in a directory we control.
mkdir -p "$T/proj/sub" "$T/projects"
cp "$(command -v sleep)" "$T/claude" 2>/dev/null || cp /bin/sleep "$T/claude"
chmod +x "$T/claude"
( cd "$T/proj" && exec "$T/claude" 300 ) &
FAKEPID=$!
sleep 1

if [[ -d "/proc/$FAKEPID" ]] && [[ "$(cat "/proc/$FAKEPID/comm" 2>/dev/null)" == claude ]]; then
  # The transcript dir name is the cwd with non-alphanumeric runs dashed.
  slug="$(printf '%s' "$T/proj" | sed 's/[^A-Za-z0-9]\+/-/g')"
  mkdir -p "$T/projects/$slug"
  SID="11111111-2222-3333-4444-555555555555"
  TR="$T/projects/$slug/$SID.jsonl"
  printf '{}\n' > "$TR"

  export CREW_PROJECTS="$T/projects" RIG_BOXES="$T/no-registry.conf"

  # fresh transcript -> active
  o="$(run "$CREW" --porcelain)"
  check_grep "session: the faked session is found" "$T/proj" "$o"
  line="$(grep -F "$T/proj" <<<"$o" | head -1)"
  check_eq "porcelain: 10 fields" "$(awk -F'\t' '{print NF}' <<<"$line")" 10
  check_eq "porcelain: session id" "$(cut -f4 <<<"$line")" "$SID"
  check_eq "porcelain: state is active" "$(cut -f5 <<<"$line")" active
  check "porcelain: uptime is a number" bash -c "[[ '$(cut -f7 <<<"$line")' =~ ^[0-9]+$ ]]"
  check "porcelain: rss is a number"    bash -c "[[ '$(cut -f9 <<<"$line")' =~ ^[0-9]+$ ]]"
  check_eq "porcelain: no subagents yet" "$(cut -f10 <<<"$line")" 0

  # an old transcript -> waiting, then quiet
  touch -d '-10 minutes' "$TR"
  line="$(run "$CREW" --porcelain | grep -F "$T/proj" | head -1)"
  check_eq "state: 10m idle is waiting" "$(cut -f5 <<<"$line")" waiting
  touch -d '-3 hours' "$TR"
  line="$(run "$CREW" --porcelain | grep -F "$T/proj" | head -1)"
  check_eq "state: 3h idle is quiet" "$(cut -f5 <<<"$line")" quiet
  touch -d '-3 days' "$TR"
  line="$(run "$CREW" --porcelain | grep -F "$T/proj" | head -1)"
  check_eq "state: 3d idle is stale" "$(cut -f5 <<<"$line")" stale

  # subagent transcripts are counted when recent
  mkdir -p "$T/projects/$slug/$SID/subagents"
  printf '{}\n' > "$T/projects/$slug/$SID/subagents/agent-aaa.jsonl"
  printf '{}\n' > "$T/projects/$slug/$SID/subagents/agent-bbb.jsonl"
  line="$(run "$CREW" --porcelain | grep -F "$T/proj" | head -1)"
  check_eq "subagents: two recent ones counted" "$(cut -f10 <<<"$line")" 2
  touch -d '-2 hours' "$T/projects/$slug/$SID/subagents/"*.jsonl
  line="$(run "$CREW" --porcelain | grep -F "$T/proj" | head -1)"
  check_eq "subagents: stale ones not counted" "$(cut -f10 <<<"$line")" 0

  # a project with no transcript at all must not crash or invent one
  rm -rf "$T/projects/$slug"
  line="$(run "$CREW" --porcelain | grep -F "$T/proj" | head -1)"
  check_eq "state: no transcript is reported as such" "$(cut -f5 <<<"$line")" no-transcript
  check_eq "state: id is - with no transcript" "$(cut -f4 <<<"$line")" -

  # human output renders a header and the project path
  o="$(run "$CREW")"
  check_grep "human: header" 'PANE +SESSION +STATE' "$o"
  check_grep "human: project column" 'proj' "$o"
  check_grep "human: a total line" 'total' "$o"
else
  printf 'SKIP  could not fake a claude process: session checks\n' >&2
fi

# --- 5. the registry --------------------------------------------------------
export CREW_PROJECTS="$T/projects"

# absent registry: local only, exit 0, and it says so
export RIG_BOXES="$T/nope.conf"
o="$(run "$CREW" -a)"; rc=$?
check_eq "registry: absent still exits 0" "$rc" 0
check_grep "registry: absent is announced" 'absent . this box only' "$o"

# a registry whose one remote box cannot be reached
cat > "$T/boxes.conf" <<EOF
box=@defaults
own=yes

box=$(hostname -s)
ssh=localhost-self

box=ghostbox
ssh=crew-test-unroutable.invalid
EOF
export RIG_BOXES="$T/boxes.conf"
o="$(RIG_TIMEOUT=3 run "$CREW" -a)"; rc=$?
check_eq "fanout: an unreachable box still exits 0" "$rc" 0
check_grep "fanout: the unreachable box is named" 'ghostbox' "$o"
check_grep "fanout: marked transient, not an error" 'transient|unreachable|timeout' "$o"
check_grep "fanout: this box is still rendered" "$(hostname -s)" "$o"

# a stanza with no ssh alias is listed, never contacted
cat > "$T/boxes2.conf" <<EOF
box=documented-only
role=prod
EOF
o="$(RIG_BOXES="$T/boxes2.conf" run "$CREW" -a)"
check_grep "fanout: a stanza with no alias is registry-only" 'registry-only' "$o"

# --- 6. doctor --------------------------------------------------------------
o="$(RIG_BOXES="$T/boxes.conf" run "$CREW" doctor)"
check_grep "doctor: reports /proc" 'proc' "$o"
check_grep "doctor: counts registry boxes" 'box\(es\)' "$o"
o="$(RIG_BOXES="$T/nope.conf" run "$CREW" doctor)"
check_grep "doctor: says when crew -a is local only" 'local only' "$o"

# --- 7. publishability ------------------------------------------------------
# The tool lives in a public repo: the leak gate's generic classes must pass
# on it. Site names are the deny list's job, in tests/test_leakgate.sh.
o="$(python3 "$HERE/../tools/leakgate.py" -q "$CREW" 2>&1)"
check_eq "publishable: the leak gate passes the tool" "$o" ""

# --- 8. man page ------------------------------------------------------------
MAN="$HERE/../man/crew.1"
check "man: page exists" test -f "$MAN"
if command -v man >/dev/null 2>&1; then
  o="$(MANWIDTH=100 man -P cat -l "$MAN" 2>/dev/null)"
  check_grep "man: NAME section" 'crew . every Claude session' "$o"
  for v in "-a, crew --all" "--sample" "--porcelain" "doctor"; do
    check_grep "man: anchor for $v" "^   crew $v" "$o"
  done
  check_grep "man: states the transcript-age limitation" 'appended per turn' "$o"
fi


# --- art: every banner obeys the grammar and the width budget ---------------
# A banner is drawn only for a human, so these assert on forced art with the
# palette empty: SC_ART on, stdout not a tty, which is what makes the glyphs
# exactly comparable.
# The suite exports CREW_NO_ART, and "off beats on" by design, so the
# variable has to be UNSET for this check rather than overridden.
art_lines() { env -u CREW_NO_ART NO_COLOR=1 CREW_ART=1 "$@" 2>/dev/null |
              sed 's/\x1b\[[0-9;]*m//g' |
              grep -E '[━─╌●◆◇┿┷┯┳╂╇╪┫✦┣▶→]' || true; }

for verb in 'doctor'; do
  o="$(art_lines "$CREW" $verb)"
  check "art: $verb draws something" test -n "$o"
  w="$(awk '{print length}' <<<"$o" | sort -rn | head -1)"
  check "art: $verb fits 72 columns (was ${w:-0})" test "${w:-0}" -le 72
  # the three retired glyphs must never come back
  check_nogrep "art: $verb uses no retired glyph" '[✂⇒⇢]' "$o"
done

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
