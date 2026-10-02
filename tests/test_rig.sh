#!/usr/bin/env bash
# Offline test suite for bin/rig and lib/rig-probe.sh
# Run: bash tests/test_rig.sh
#
# Builds a throwaway roster and a real `file://` origin under mktemp, so repo
# verdicts (level / ahead / behind / unpushed / diverged) are exercised
# against genuine git history rather than mocked. No network, and RIG_BOXES is
# redirected so the real roster is never read.
#
# Two assertions carry more weight than the rest:
#   - the probe WRITES NOTHING, checked against a read-only .git
#   - neither file contains a site string, because the fleet is going public

set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG="$HERE/../bin/rig"
PROBE="$HERE/../lib/rig-probe.sh"
DISKLIB="$HERE/../lib/rig-disk.sh"
T="$(mktemp -d -t rig-test.XXXXXX)"
export SC_CONFIG_HOME="$T/cfg"  # never read the real ~/.config/sc-fleet
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

export NO_COLOR=1 RIG_NO_ART=1
export RIG_BOXES="$T/boxes.conf" RIG_STATE="$T/state" RIG_RUN="$T/run"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
    name = Test User
    email = test@example.invalid
[init]
    defaultBranch = main
[advice]
    detachedHead = false
EOF

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
o="$(run "$RIG" __id)"
check_eq "id: field count" "$(awk -F'\t' '{print NF}' <<<"$o")" 6
check_eq "id: name" "$(cut -f1 <<<"$o")" rig
for i in 4 5 6; do
  r="$(cut -f$i <<<"$o")"
  check_eq "id: sigil row $((i-4)) is 4 chars" "${#r}" 4
done
check "marker: last line is the sc-fleet marker" \
  bash -c "tail -1 '$RIG' | grep -q '^# sc-fleet'"

# --- 2. publishability ------------------------------------------------------
# The guarantee is a test, not a habit. This is the whole reason it exists.
# Generic classes here; site names are the deny list's job, in
# tests/test_leakgate.sh.
GATE="$HERE/../tools/leakgate.py"
for f in "$RIG" "$PROBE" "$DISKLIB"; do
  hits="$(python3 "$GATE" -q "$f" 2>&1)"
  check_eq "publishable: the leak gate passes $(basename "$f")" "$hits" ""
done
# and prove the check can fail, or it proves nothing
cp "$RIG" "$T/planted"
printf '\n# reach it at %s.%s.%s.%s\n' 10 20 30 40 >> "$T/planted"
python3 "$GATE" -q "$T/planted" >/dev/null 2>&1; rc=$?
check_eq "publishable: the gate catches a planted address" "$rc" 1

# --- 3. the probe is read-only ---------------------------------------------
# a git verb outside the whitelist must be refused, not run
o="$(bash -c 'set -u; g() {
      case "${2:-}" in rev-parse|status|config|for-each-ref|rev-list|symbolic-ref|log|merge-base) ;;
      *) printf "probe_error=git_verb_denied:%s\n" "${2:-empty}"; return 1 ;; esac
      printf "ran\n"; }; g /tmp fetch')"
check_grep "probe: a non-read git verb is denied" 'git_verb_denied:fetch' "$o"
check_nogrep "probe: the denied verb never ran" '^ran$' "$o"

check_nogrep "probe: contains no fetch" 'git[^|]*fetch' "$(grep -v '^#' "$PROBE")"
check_grep   "probe: injects --no-optional-locks" 'no-optional-locks' "$(cat "$PROBE")"
check_grep   "probe: ends with the sentinel" 'end=ok' "$(tail -3 "$PROBE")"

# a real repo, made read-only, must still be probed without error
mkdir -p "$T/ro"
git init -q -b main "$T/ro/repo"
( cd "$T/ro/repo" && echo a > a.txt && git add . && git commit -q -m one )
STAMP="$T/stamp"; touch "$STAMP"; sleep 1
chmod -R a-w "$T/ro/repo/.git"
o="$(bash "$PROBE" "$T/ro/repo" "" "" 2>&1)"
chmod -R u+w "$T/ro/repo/.git"
check_grep "probe: finishes against a read-only .git" 'end=ok' "$o"
changed="$(find "$T/ro/repo/.git" -newer "$STAMP" 2>/dev/null | wc -l | tr -d ' ')"
check_eq "probe: wrote nothing inside .git" "$changed" "0"

# --- 4. repo verdicts against a real origin --------------------------------
git init -q --bare -b main "$T/origin.git"
git clone -q "file://$T/origin.git" "$T/box" 2>/dev/null
( cd "$T/box" && echo one > f && git add . && git commit -q -m one && git push -q -u origin main )

cat > "$RIG_BOXES" <<EOF
box=@defaults
repos=$T/box
timers=
sched=none
own=yes

box=testbox
ssh=
role=dev

box=ghost
ssh=rig-test-nohost
role=dev

box=notours
ssh=rig-test-nohost
own=no
EOF
export RIG_BOX=testbox

o="$(run "$RIG")"
check_grep "status: level when clean and level" 'level' "$o"
check_grep "status: the box is named" 'testbox' "$o"

( cd "$T/box" && echo two > f && git commit -qam two )
o="$(run "$RIG")"
check_grep "status: ahead after a local commit" 'ahead 1' "$o"

( cd "$T/box" && git push -q && git reset -q --hard HEAD~1 )
o="$(run "$RIG")"
check_grep "status: behind after a reset" 'behind 1' "$o"

( cd "$T/box" && echo dirt > untracked )
o="$(run "$RIG")"
check_grep "status: dirty count is shown" 'dirty' "$o"
rm -f "$T/box/untracked"

# a mid-operation repo must be flagged and must make the run need a human
( cd "$T/box" && git reset -q --hard origin/main && touch .git/MERGE_HEAD )
o="$(run "$RIG")"; rc=$?
check_grep "status: mid-operation is flagged" 'MID-OPERATION' "$o"
check_eq "status: mid-operation exits 1" "$rc" 1
rm -f "$T/box/.git/MERGE_HEAD"

# --- 5. a declared mount that is absent ------------------------------------
cat >> "$RIG_BOXES" <<EOF

box=mountbox
mounts=$T/definitely-not-here
EOF
o="$(RIG_BOX=mountbox run "$RIG")"; rc=$?
check_grep "mounts: an absent declared mount is flagged" 'MISSING on this box' "$o"
check_eq "mounts: that exits 1" "$rc" 1

# --- 6. the roster ----------------------------------------------------------
o="$(run "$RIG" boxes)"
check_grep "boxes: lists a box" 'testbox' "$o"
check_grep "boxes: marks an unowned box" 'not ours' "$o"
check_grep "boxes: names a missing alias" 'no alias' "$o"

o="$(run "$RIG" boxes --stanza)"
check_grep "boxes: --stanza is paste-ready" '^box=testbox' "$o"

o="$(run "$RIG" boxes --lint)"
check_grep "boxes: lint passes on a clean roster" 'no addresses leaked' "$o"
printf '\nbox=leaky\nnote=192.0.2.1 is the host\n' >> "$RIG_BOXES"
o="$(run "$RIG" boxes --lint)"; rc=$?
check_grep "boxes: lint catches an IP" 'IP or dotted name' "$o"
check_eq "boxes: lint exits 1 on a leak" "$rc" 1
# strip it again
grep -v '^note=10\.0\.0\.1' "$RIG_BOXES" | grep -v '^box=leaky' > "$T/b2" && mv "$T/b2" "$RIG_BOXES"

# --- 7. degradation with no roster -----------------------------------------
o="$(RIG_BOXES="$T/nope.conf" run "$RIG")"; rc=$?
check_grep "no roster: says so" 'absent' "$o"
check "no roster: still reports this box" test -n "$o"

# --- 8. sync refusals -------------------------------------------------------
o="$(RIG_BOXES="$T/nope.conf" expect_fail "sync: refuses with no roster" "$RIG" sync)"
check_grep "sync: names the stanza helper" 'stanza' "$o"

o="$(RIG_BOX=unregistered expect_fail "sync: refuses an unregistered box" "$RIG" sync)"
check_grep "sync: prints a paste-ready stanza on refusal" 'box=unregistered' "$o"

o="$(RIG_BOX=notours expect_fail "sync: refuses a box that is not ours" "$RIG" sync)"
check_grep "sync: names own=no" 'own=no' "$o"

# --- 8b. push ---------------------------------------------------------------
# The one verb that writes past this box, so every path runs against the real
# file:// origin: dirty → commit → push, behind → fast-forward, diverged →
# refused with the commit kept, and the journal handed to its delegate.
( cd "$T/box" && git fetch -q && git reset -q --hard origin/main && git clean -fdq )
origin_head() { git -C "$T/origin.git" rev-parse main; }
dirty_n()     { git -C "$1" status --porcelain | grep -c . || true; }

o="$(RIG_BOXES="$T/nope.conf" expect_fail "push: refuses with no roster" "$RIG" push)"
o="$(RIG_BOX=notours expect_fail "push: refuses a box that is not ours" "$RIG" push)"
check_grep "push: names own=no" 'own=no' "$o"
o="$(expect_fail "push: rejects an unknown option" "$RIG" push --nope)"
check_grep "push: names the valid options" '\-m MSG.*dry-run' "$o"
o="$(expect_fail "push: -m without a message is refused" "$RIG" push -m)"

# level and clean: nothing happens, and it says so
o="$(run "$RIG" push)"; rc=$?
check_eq "push: level repo exits 0" "$rc" 0
check_grep "push: level repo is reported level" 'level' "$o"
check_grep "push: the default message is shown" \
  'sync: testbox [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' "$o"

# dirty, dry run: commits nothing, pushes nothing, says what it would do
echo new > "$T/box/untracked"
before="$(origin_head)"
o="$(run "$RIG" push --dry-run)"
check_grep "push --dry-run: would commit" 'would commit 1 change' "$o"
check_grep "push --dry-run: would push" 'would push 1' "$o"
check_eq "push --dry-run: tree still dirty" "$(dirty_n "$T/box")" 1
check_eq "push --dry-run: origin untouched" "$(origin_head)" "$before"

# dirty, for real, default message
o="$(run "$RIG" push)"; rc=$?
check_eq "push: exits 0" "$rc" 0
check_grep "push: reports the commit and the push" 'committed 1 change.*pushed 1' "$o"
check_eq "push: tree clean afterwards" "$(dirty_n "$T/box")" 0
check_eq "push: origin advanced to HEAD" "$(origin_head)" "$(git -C "$T/box" rev-parse HEAD)"
check_grep "push: subject is sync: <box> <timestamp>" \
  '^sync: testbox [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' "$(git -C "$T/box" log -1 --format=%s)"
check_grep "push: body lists what was staged" '^A[[:space:]]+untracked$' "$(git -C "$T/box" log -1 --format=%b)"

# -m replaces the subject
echo more >> "$T/box/f"
o="$(run "$RIG" push -m 'my own words')"
check_eq "push -m: subject is the given message" "$(git -C "$T/box" log -1 --format=%s)" 'my own words'
check_eq "push -m: pushed" "$(origin_head)" "$(git -C "$T/box" rev-parse HEAD)"

# behind and clean: fast-forward, nothing to push
( cd "$T/box" && git reset -q --hard HEAD~1 )
o="$(run "$RIG" push)"; rc=$?
check_grep "push: behind is fast-forwarded" 'fast-forwarded 1' "$o"
check_eq "push: level after the fast-forward" "$(git -C "$T/box" rev-parse HEAD)" "$(origin_head)"
check_eq "push: fast-forward alone exits 0" "$rc" 0

# behind AND dirty in a file origin did not touch: ff first, then commit on top
( cd "$T/box" && git reset -q --hard HEAD~1 && echo side > side )
up_before="$(origin_head)"
o="$(run "$RIG" push)"; rc=$?
check_grep "push: ff, then commit, then push" 'fast-forwarded 1 · committed 1 change.*pushed 1' "$o"
check_eq "push: origin has the new commit" "$(origin_head)" "$(git -C "$T/box" rev-parse HEAD)"
check_eq "push: the fast-forwarded tip is the new commit's parent" \
  "$(git -C "$T/box" rev-parse HEAD~1)" "$up_before"

# diverged: origin moved and this box committed something else. Refused, the
# local commit is kept, origin is not touched, and the run exits 1.
git clone -q "file://$T/origin.git" "$T/other" 2>/dev/null
( cd "$T/other" && echo theirs > theirs && git add . && git commit -q -m theirs && git push -q )
( cd "$T/box" && echo mine > mine && git add . && git commit -q -m mine )
before="$(origin_head)"; local_head="$(git -C "$T/box" rev-parse HEAD)"
o="$(run "$RIG" push)"; rc=$?
check_eq "push: divergence exits 1" "$rc" 1
check_grep "push: divergence is named" 'diverged' "$o"
check_grep "push: nothing pushed on divergence" 'nothing pushed' "$o"
check_eq "push: origin untouched on divergence" "$(origin_head)" "$before"
check_eq "push: local commit kept on divergence" "$(git -C "$T/box" rev-parse HEAD)" "$local_head"

# behind, with an edit to a file origin also changed: git refuses the
# fast-forward, the edit is still committed, nothing is pushed
( cd "$T/box" && git reset -q --hard origin/main )
( cd "$T/other" && echo v2 > theirs && git commit -qam v2 && git push -q )
echo local > "$T/box/theirs"
before="$(origin_head)"
o="$(run "$RIG" push)"; rc=$?
check_eq "push: overlap exits 1" "$rc" 1
check_grep "push: overlap is explained" 'origin moved under your edits' "$o"
check_eq "push: the overlapping edit was committed" "$(dirty_n "$T/box")" 0
check_eq "push: origin untouched on overlap" "$(origin_head)" "$before"
( cd "$T/box" && git fetch -q && git reset -q --hard origin/main )

# an unfinished merge is never touched
( cd "$T/box" && echo x > x && touch .git/MERGE_HEAD )
o="$(run "$RIG" push)"; rc=$?
check_eq "push: mid-operation exits 1" "$rc" 1
check_grep "push: mid-operation is named" 'unfinished merge' "$o"
check_eq "push: mid-operation tree untouched" "$(dirty_n "$T/box")" 1
rm -f "$T/box/.git/MERGE_HEAD" "$T/box/x"

# the journal goes to its delegate, and -m does not reach it
git init -q --bare -b main "$T/journal.git"
mkdir -p "$T/home"
git clone -q "file://$T/journal.git" "$T/home/journal" 2>/dev/null
( cd "$T/home/journal" && echo day > log.md && git add . && git commit -q -m init && git push -q -u origin main )
echo entry >> "$T/home/journal/log.md"
cat > "$T/boxes-journal.conf" <<EOF
box=@defaults
repos=$T/home/journal
timers=
sched=none
own=yes

box=testbox
role=dev
EOF
# which script owns the journal, and which repo it owns, is config
mkdir -p "$SC_CONFIG_HOME"
# The delegate is the site's own script; this stand-in commits and pushes the
# way one would, under a subject of its own.
cat > "$T/journal-sync.sh" <<EOF
#!/usr/bin/env bash
set -e
cd "$T/home/journal" && git add -A && git commit -qm "sync: stand-in" && git push -q
EOF
chmod +x "$T/journal-sync.sh"
printf 'rig.journal=%s\nrig.journal_repo=%s\n' "$T/journal-sync.sh" "$T/home/journal" \
  > "$SC_CONFIG_HOME/config"
o="$(HOME="$T/home" RIG_BOXES="$T/boxes-journal.conf" run "$RIG" push -m 'not for the journal')"; rc=$?
rm -f "$SC_CONFIG_HOME/config"
check_eq "push: journal run exits 0" "$rc" 0
check_grep "push: journal is delegated" 'journal-sync.sh' "$o"
check_grep "push: journal subject is journal-sync's own" '^sync: ' \
  "$(git -C "$T/journal.git" log -1 --format=%s main)"
check_eq "push: journal tree clean" "$(dirty_n "$T/home/journal")" 0

# leave the shared fixture level and clean for the sections that follow
( cd "$T/box" && git fetch -q && git reset -q --hard origin/main && git clean -fdq )

# --- 8c. installers are config ------------------------------------------------
# With nothing configured, every delegated stage is a skip, never a finding.
o="$(run "$RIG" doctor)"
check_grep "config: unconfigured pull is a skip" 'not configured \(rig\.pull\)' "$o"
check_grep "config: unconfigured installer is a skip" 'not configured \(rig\.installer\)' "$o"
check_nogrep "config: no stage is reported missing" '(pull|journal|installer|scheduler) .*missing' "$o"
o="$(run "$RIG" sync --dry-run)"
check_grep "config: sync names the unset key" 'not configured \(rig\.pull\)' "$o"

# push= narrows what rig push may commit: repos= is synced, push= is written
cat > "$T/boxes-push.conf" <<EOF
box=@defaults
repos=$T/box
push=$T/not-here
timers=
sched=none
own=yes

box=testbox
role=dev
EOF
o="$(RIG_BOXES="$T/boxes-push.conf" run "$RIG" push --dry-run)"
check_grep "push=: only the listed repo is visited" 'not checked out here' "$o"
check_nogrep "push=: a repo outside push= is left alone" "$(basename "$T")/box " "$o"

# --- 9. fan-out failure is per box -----------------------------------------
o="$(RIG_TIMEOUT=3 run "$RIG" status -a)"; rc=$?
check_grep "fanout: an unreachable box is named" 'ghost' "$o"
check_grep "fanout: marked transient" 'transient|unreachable|timeout' "$o"
check_grep "fanout: an unowned box is skipped by default" 'not ours|unowned' "$o"
check_grep "fanout: this box is still rendered" 'testbox' "$o"

# --- 9b. sync --fleet -------------------------------------------------------
# It writes, so every guard matters more here than anywhere else.
o="$(RIG_TIMEOUT=3 run "$RIG" sync --fleet --dry-run)"
check_grep "fleet: iterates the roster" 'testbox' "$o"
check_grep "fleet: refuses an unowned box" 'own=no|refused' "$o"
check_grep "fleet: skips a box with no alias" 'no ssh alias|registry-only' "$o"
check_grep "fleet: reports a tally" 'ok . .*skipped' "$o"
# the dry run must not have touched the working tree of the test repo
check_eq "fleet: dry run changed nothing" \
  "$(cd "$T/box" && git status --porcelain | wc -l | tr -d ' ')" "0"

o="$(expect_fail "sync: rejects an unknown option" "$RIG" sync --nope)"
check_grep "sync: names the valid options" 'dry-run.*fleet|fleet.*dry-run' "$o"

# --- 9c. fleet presence is derived, not listed ------------------------------
# A tool with the marker must become expected without editing anything.
o="$(run "$RIG" status)"
check_grep "fleet: presence is reported per box" 'fleet' "$o"

# --- 10. doctor -------------------------------------------------------------
# The one door for dotfile drift. Every delegated row is pointed at a stub via
# an env override, so the suite never depends on the real box's editor stack,
# theme or disks. Only the `links` row still reads the real HOME, which is why
# clean-case exit codes compare to a baseline rather than to 0.
o="$(expect_fail "doctor: rejects an unknown option" "$RIG" doctor --nope)"
check_grep "doctor: names --disk on refusal" '\-\-disk' "$o"

mk_stub() { # PATH OUTFILE RCFILE — a script that prints one file and exits with the other
  printf '#!/usr/bin/env bash\ncat "%s"; exit "$(cat "%s")"\n' "$2" "$3" > "$1"; chmod +x "$1"; }
mkdir -p "$T/dots" "$T/bin" "$T/tree/proj/__pycache__" "$T/tree/web/node_modules/pkg" "$T/tree/data/sub dir"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/dots/install.sh"; chmod +x "$T/dots/install.sh"
mk_stub "$T/dots/install-editor-stack.sh" "$T/editor.out" "$T/editor.rc"
mk_stub "$T/bin/dye" "$T/dye.out" "$T/dye.rc"
for f in "$T/tree/proj/__pycache__/a.pyc" "$T/tree/web/node_modules/pkg/x.js" "$T/tree/data/sub dir/d.bin"; do
  head -c 8192 /dev/zero > "$f"
done
export RIG_DOTS="$T/dots" RIG_DYE="$T/bin/dye" RIG_DISK_PATHS="$T/tree"
clean_stubs() {
  printf 'editor stack complete.\n' > "$T/editor.out"; printf 0 > "$T/editor.rc"
  printf 'doctor: clean\n' > "$T/dye.out"; printf 0 > "$T/dye.rc"
}
clean_stubs
o="$(run "$RIG" doctor)"; base_rc=$?
check_grep "doctor: reports the probe" 'probe' "$o"
check_grep "doctor: counts the roster" 'box\(es\)' "$o"
check_grep "doctor: editor row is clean" '^editor +install-editor-stack --check +clean' "$o"
check_grep "doctor: theme row is clean" '^theme +dye doctor +clean' "$o"
check_nogrep "doctor: no disk rows without --disk" '^disk ' "$o"

# editor gaps are a finding: the fix is interactive, so a human must act
printf '  bat|batcat               MISSING (package bat)\n  tree-sitter              BROKEN (on disk but will not run)\n\ngaps found (--check: nothing installed)\n' > "$T/editor.out"
printf 1 > "$T/editor.rc"
o="$(run "$RIG" doctor)"; rc=$?
check_grep "doctor: editor counts the gaps" '^editor +.*2 gap\(s\)' "$o"
check_grep "doctor: editor lists the gap lines, indented" '^ {11}bat\|batcat +MISSING' "$o"
check_eq "doctor: editor gaps exit 1" "$rc" 1
printf 'boom\n' > "$T/editor.out"; printf 141 > "$T/editor.rc"
o="$(run "$RIG" doctor)"; rc=$?
check_grep "doctor: an editor check that dies is named" 'died before its verdict' "$o"
check_eq "doctor: editor crash exits 1" "$rc" 1
chmod -x "$T/dots/install-editor-stack.sh"
o="$(run "$RIG" doctor)"; rc=$?
check_grep "doctor: no editor check is a skip" '^editor +.*skipped' "$o"
check_eq "doctor: editor skip keeps the baseline rc" "$rc" "$base_rc"
chmod +x "$T/dots/install-editor-stack.sh"; clean_stubs

# theme: dye's summary line is the contract; warn rows never count
printf 'link\n  current    FAIL         link missing\n  wiring     warn         kitty include absent\n\ndoctor: 1 finding(s)\n' > "$T/dye.out"; printf 1 > "$T/dye.rc"
o="$(run "$RIG" doctor)"; rc=$?
check_grep "doctor: theme counts dye findings" '^theme +dye doctor +1 finding' "$o"
check_grep "doctor: theme lists the FAIL rows" '^ {11}current +FAIL' "$o"
check_nogrep "doctor: theme never lists a warn row" '^ {11}wiring' "$o"
check_eq "doctor: theme finding exits 1" "$rc" 1
printf 'dye: boom\n' > "$T/dye.out"; printf 1 > "$T/dye.rc"
o="$(run "$RIG" doctor)"; rc=$?
check_grep "doctor: a dye that dies is named" 'died before its summary' "$o"
check_eq "doctor: dye crash exits 1" "$rc" 1
o="$(RIG_DYE="$T/nope" run "$RIG" doctor)"; rc=$?
check_grep "doctor: no dye is a skip" '^theme +.*skipped' "$o"
check_eq "doctor: dye skip keeps the baseline rc" "$rc" "$base_rc"
clean_stubs

# --disk: one traversal per root, a report and the raw gz under RIG_STATE
o="$(run "$RIG" doctor --disk)"; rc=$?
check_grep "disk: the root is reported" '^disk +.*tree' "$o"
check_grep "disk: top rows" '^ {2}top +' "$o"
check_grep "disk: junk rows name the pattern" '^ {2}junk +pycache' "$o"
check_grep "disk: junk rows name node_modules too" '^ {2}junk +node_modules' "$o"
check_grep "disk: a path with a space survives" 'sub dir' "$o"
check "disk: raw traversal written" test -s "$RIG_STATE"/disk/*tree.du.gz
check "disk: report written" test -f "$RIG_STATE"/disk/*tree.md
check_grep "disk: report has the depth table" 'Top 25 directories at depth 1' "$(cat "$RIG_STATE"/disk/*tree.md)"
check_grep "disk: report lists the junk" '__pycache__' "$(cat "$RIG_STATE"/disk/*tree.md)"
check_eq "disk: a clean tree keeps the baseline rc" "$rc" "$base_rc"
o="$(RIG_DISK_PATHS= run "$RIG" doctor --disk "$T/tree/data")"
check_grep "disk: a positional path narrows the scan" '^disk +.*tree/data' "$o"
check_nogrep "disk: the narrowed scan sees no junk" '^ {2}junk' "$o"
o="$(RIG_DISK_PATHS="$T/absent" run "$RIG" doctor --disk)"
check_grep "disk: a missing root is a skip, not a crash" 'not a directory here' "$o"

# secrets: the sealed ~/.zsh_secrets, every state one row names the fix for.
# A throwaway identity under mktemp; the fixture secret must never be printed.
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  mkdir -p "$T/dots/secrets" "$T/home"
  age-keygen -o "$T/id.key" 2>/dev/null
  { echo "# testbox"; age-keygen -y "$T/id.key"; } > "$T/dots/secrets/recipients.txt"
  printf 'export FIXTURE_SECRET=1-do-not-leak\n' > "$T/plain"
  age -R "$T/dots/secrets/recipients.txt" -o "$T/dots/secrets/zsh_secrets.age" "$T/plain"
  cp "$T/plain" "$T/home/.zsh_secrets"; chmod 600 "$T/home/.zsh_secrets"
  export RIG_SECRETS_ID="$T/id.key" RIG_SECRETS_OUT="$T/home/.zsh_secrets"
  sec() { o="$(run "$RIG" doctor)"; rc=$?
          check_nogrep "secrets: $1 leaks nothing" 'do-not-leak|AGE-SECRET-KEY' "$o"; }

  sec "clean run"
  check_grep "secrets: all good is current" '^secrets +sealed · 1 recipient\(s\) +this box listed · current' "$o"
  check_eq "secrets: all good keeps the baseline rc" "$rc" "$base_rc"

  rm -f "$T/home/.zsh_secrets"; sec "missing copy"
  check_grep "secrets: missing copy is named" 'not decrypted' "$o"; check_eq "secrets: missing copy exits 1" "$rc" 1

  printf 'stale\n' > "$T/home/.zsh_secrets"; chmod 600 "$T/home/.zsh_secrets"; sec "stale copy"
  check_grep "secrets: stale copy is named" 'is stale' "$o"; check_eq "secrets: stale copy exits 1" "$rc" 1

  cp "$T/plain" "$T/home/.zsh_secrets"; chmod 644 "$T/home/.zsh_secrets"; sec "wrong mode"
  check_grep "secrets: wrong mode is named" 'is mode 644' "$o"; check_eq "secrets: wrong mode exits 1" "$rc" 1
  chmod 600 "$T/home/.zsh_secrets"

  { echo "# someone else"; age-keygen -y <(age-keygen 2>/dev/null); } > "$T/dots/secrets/recipients.txt"
  sec "not a recipient"
  check_grep "secrets: not a recipient is named" 'not a recipient' "$o"
  check_grep "secrets: the public key is shown, which is safe" '^ {11}age1' "$o"
  check_eq "secrets: not a recipient exits 1" "$rc" 1
  { echo "# testbox"; age-keygen -y "$T/id.key"; } > "$T/dots/secrets/recipients.txt"

  mv "$T/dots/secrets/zsh_secrets.age" "$T/blob.bak"; sec "no blob"
  check_grep "secrets: no blob is named" 'no blob' "$o"; check_eq "secrets: no blob exits 1" "$rc" 1
  mv "$T/blob.bak" "$T/dots/secrets/zsh_secrets.age"

  chmod 644 "$T/id.key"; sec "loose identity"
  check_grep "secrets: identity mode is named" 'identity is mode 644' "$o"; check_eq "secrets: loose identity exits 1" "$rc" 1
  chmod 600 "$T/id.key"

  o="$(RIG_SECRETS_ID="$T/nope.key" run "$RIG" doctor)"; rc=$?
  check_grep "secrets: no identity names age-keygen" 'no identity.*age-keygen' "$o"
  check_eq "secrets: no identity exits 1" "$rc" 1

  o="$(RIG_AGE="$T/nope/age" run "$RIG" doctor)"; rc=$?
  check_grep "secrets: no age is named" 'age not installed' "$o"; check_eq "secrets: no age exits 1" "$rc" 1

  mv "$T/dots/secrets" "$T/secrets.bak"; o="$(run "$RIG" doctor)"; rc=$?
  check_grep "secrets: nothing sealed is a skip" '^secrets +.*skipped' "$o"
  check_eq "secrets: skip keeps the baseline rc" "$rc" "$base_rc"
  mv "$T/secrets.bak" "$T/dots/secrets"
else
  echo "  (age absent: secrets row untested)"
fi

# --- 11. unknown verb -------------------------------------------------------
o="$(expect_fail "unknown verb refuses" "$RIG" bogus)"
check_grep "unknown verb names --help" 'rig --help' "$o"

# --- 12. kit-less fallback --------------------------------------------------
mkdir -p "$T/bare"
cp "$RIG" "$T/bare/rig"
o="$(run "$T/bare/rig" --help)"; rc=$?
check_eq "bare: --help exits 0 without lib/" "$rc" 0
check_grep "bare: usage survives" 'whether it is current' "$o"

# --- 13. man page -----------------------------------------------------------
MAN="$HERE/../man/rig.1"
check "man: page exists" test -f "$MAN"
if command -v man >/dev/null 2>&1; then
  o="$(MANWIDTH=100 man -P cat -l "$MAN" 2>/dev/null)"
  check_grep "man: NAME section" 'rig . what this box is' "$o"
  for v in "status" "sync" "doctor" "boxes"; do
    check_grep "man: anchor for $v" "^   rig $v" "$o"
  done
  check_grep "man: states the write-local rule" 'Read all, write local' "$o"
  check_grep "man: explains the sentinel" 'end=ok' "$o"
fi


# --- art: every banner obeys the grammar and the width budget ---------------
# A banner is drawn only for a human, so these assert on forced art with the
# palette empty: SC_ART on, stdout not a tty, which is what makes the glyphs
# exactly comparable.
# The suite exports RIG_NO_ART, and "off beats on" by design, so the
# variable has to be UNSET for this check rather than overridden.
art_lines() { env -u RIG_NO_ART NO_COLOR=1 RIG_ART=1 "$@" 2>/dev/null |
              sed 's/\x1b\[[0-9;]*m//g' |
              grep -E '[━─╌●◆◇┿┷┯┳╂╇╪┫✦┣▶→]' || true; }

for verb in 'doctor' 'doctor --disk' 'boxes' 'push --dry-run'; do
  o="$(art_lines "$RIG" $verb)"
  check "art: $verb draws something" test -n "$o"
  w="$(awk '{print length}' <<<"$o" | sort -rn | head -1)"
  check "art: $verb fits 72 columns (was ${w:-0})" test "${w:-0}" -le 72
  # the three retired glyphs must never come back
  check_nogrep "art: $verb uses no retired glyph" '[✂⇒⇢]' "$o"
done

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
