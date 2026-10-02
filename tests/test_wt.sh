#!/usr/bin/env bash
# Offline test suite for bin/wt — run: bash tests/test_wt.sh
#
# Builds a throwaway $WT_ROOT / $WT_STORE under mktemp, a file:// bare repo as
# origin, and exercises every subcommand plus the refusals. No network, no
# forge: the file:// host resolves to "unknown", so `wt pr` pushes and stops.
set -uo pipefail
# Widths and glyphs are counted in characters, which needs a UTF-8 locale;
# a non-interactive ssh session is often POSIX.
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$HERE/../bin/wt"
T="$(mktemp -d -t wt-test.XXXXXX)"
export SC_CONFIG_HOME="$T/cfg"  # never read the real ~/.config/sc-fleet
trap 'rm -rf "$T"' EXIT

export WT_ROOT="$T/wtroot" WT_STORE="$T/store" WT_TOKEN_FILE="$T/no-token" NO_COLOR=1 WT_NO_ART=1
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
mkdir -p "$WT_ROOT" "$WT_STORE" "$T/remote"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
check() { # desc cond...
  local d="$1"; shift
  if "$@"; then pass; else fail "$d"; fi
}
check_eq() { [[ "$2" == "$3" ]] && pass || fail "$1: expected [$3] got [$2]"; }
check_grep() { grep -qE -- "$2" <<<"$3" && pass || fail "$1: no match for /$2/ in: $3"; }
check_nogrep() { grep -qE -- "$2" <<<"$3" && fail "$1: unexpected /$2/" || pass; }
expect_fail() { # desc cmd...
  local d="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  [[ $rc -ne 0 ]] && pass || fail "$d: expected failure, got rc=0: $out"
  printf '%s' "$out"
}
run() { "$@" 2>&1; }   # capture both streams for assertions

# --- fixtures ---------------------------------------------------------------
git init -q --bare -b main "$T/remote/demo.git"
git clone -q "file://$T/remote/demo.git" "$T/seed"
( cd "$T/seed" && echo hello > README.md && git add . && git commit -q -m "initial" && git push -q -u origin main )
DEMO_URL="file://$T/remote/demo.git"

# --- 1. init --clone from nothing --------------------------------------------
out="$(run "$WT" init --project demo --clone "$DEMO_URL" -y)"
MAIN="$WT_ROOT/demo/src/demo/main"
check "init: main is a clone"           test -d "$MAIN/.git"
check "init: CLAUDE.md symlink"          test -L "$WT_ROOT/demo/CLAUDE.md"
check_eq "init: CLAUDE.md target"        "$(readlink "$WT_ROOT/demo/CLAUDE.md")" "$WT_STORE/demo/CLAUDE.md"
check_eq "init: docs target"             "$(readlink "$WT_ROOT/demo/docs")" "$WT_STORE/demo"
check "init: store README"               test -f "$WT_STORE/demo/README.md"
check "init: store CLAUDE.md stub"       test -f "$WT_STORE/demo/CLAUDE.md"
check "init: conf written"               test -f "$WT_STORE/demo/repos/demo.conf"
check_grep "init: squash default true"   '^squash=true$' "$(cat "$WT_STORE/demo/repos/demo.conf")"
check_grep "init: base origin"           '^base=origin$' "$(cat "$WT_STORE/demo/repos/demo.conf")"
check_grep "init: allow_interp false"    '^allow_interp=false$' "$(cat "$WT_STORE/demo/repos/demo.conf")"
EXCL="$MAIN/.git/info/exclude"
check "init: exclude CLAUDE.local.md"    grep -qxF CLAUDE.local.md "$EXCL"
check "init: exclude .claude/"           grep -qxF .claude/ "$EXCL"
check "init: no allows without --mine"   test ! -e "$MAIN/.claude/settings.local.json"
check_grep "init: token reported missing" 'MISSING' "$out"
out2="$(run "$WT" init --project demo -y)"
check_grep "init: idempotent (conf present)" 'present' "$out2"

# --- 2. URL parsing / forge detection ----------------------------------------
# A site's own forge hosts come from the wt.forge config list, never from wt
# itself; the public forges are built in. All hosts here are fictional.
mkdir -p "$SC_CONFIG_HOME"
cat > "$SC_CONFIG_HOME/config" <<'EOF'
wt.forge=git.example.net gitlab
wt.forge=forge.example.org forgejo
wt.forge=*.corp.example forgejo
wt.forge=bad.example rm-rf
EOF
check_eq "parse ssh://"   "$("$WT" __parse ssh://forgejo@forge.example.org/acme/widget)" "forge.example.org acme widget forgejo"
check_eq "parse scp .git" "$("$WT" __parse forgejo@forge.example.org:acme-core/acme.git)" "forge.example.org acme-core acme forgejo"
check_eq "parse gh alias" "$("$WT" __parse git@github-acme:acme/widget-research.git)" "github-acme acme widget-research github"
check_eq "parse https"    "$("$WT" __parse https://github.com/octo/demo)" "github.com octo demo github"
check_eq "parse gitlab"   "$("$WT" __parse git@git.example.net:ops/ops_tools.git)" "git.example.net ops ops_tools gitlab"
check_eq "parse port"     "$("$WT" __parse ssh://git@gitlab.example.com:2222/grp/sub/proj.git)" "gitlab.example.com grp/sub proj gitlab"
check_eq "forge: glob rule"        "$("$WT" __parse git@build.corp.example:a/b.git | awk '{print $4}')" "forgejo"
check_eq "forge: codeberg built in" "$("$WT" __parse https://codeberg.org/a/b | awk '{print $4}')" "forgejo"
check_eq "forge: bad kind ignored"  "$("$WT" __parse git@bad.example:a/b.git | awk '{print $4}')" "unknown"
check_eq "forge: no config, site host unknown" \
  "$(SC_CONFIG_HOME="$T/nocfg" "$WT" __parse forgejo@forge.example.org:acme/acme.git | awk '{print $4}')" "unknown"
printf 'wt.forge=forge.example.org gitlab\n' > "$SC_CONFIG_HOME/config.local"
check_eq "forge: config.local first" "$("$WT" __parse forgejo@forge.example.org:acme/acme.git | awk '{print $4}')" "gitlab"
rm -f "$SC_CONFIG_HOME/config.local"

# --- 2b. roots, store and templates from config -------------------------------
mkdir -p "$T/cfg2/wt" "$T/r2" "$T/notes2"
printf 'notes=%s\nwt.root=%s\n' "$T/notes2" "$T/r2" > "$T/cfg2/config"
printf '# {{PROJ}} overlay\nstore {{STORE}} wrap {{WRAP}} $(id)\n' > "$T/cfg2/wt/store-README.md"
out="$(cd "$T" && env -u WT_ROOT -u WT_STORE SC_CONFIG_HOME="$T/cfg2" "$WT" init --project cfgdemo --clone "$DEMO_URL" -y 2>&1)"
check "conf: wt.root sets the root"            test -d "$T/r2/cfgdemo"
check "conf: notes sets the store"             test -d "$T/notes2/projects/cfgdemo"
check_eq "conf: template overlay rendered" "$(head -1 "$T/notes2/projects/cfgdemo/README.md")" "# cfgdemo overlay"
check_grep "conf: placeholders filled" "store $T/notes2/projects/cfgdemo wrap $T/r2/cfgdemo" "$(cat "$T/notes2/projects/cfgdemo/README.md")"
check_grep "conf: template text is never run" '\$\(id\)' "$(cat "$T/notes2/projects/cfgdemo/README.md")"
# no config, no env: the neutral defaults, under a throwaway HOME
FH="$T/fakehome"; mkdir -p "$FH"
out="$(cd "$T" && env -u WT_ROOT -u WT_STORE HOME="$FH" SC_CONFIG_HOME="$T/cfg3" \
  "$WT" init --project plain --clone "$DEMO_URL" -y 2>&1)"
check "conf: neutral root is ~/wt"             test -d "$FH/wt/plain"
check "conf: neutral store is ~/notes/projects" test -d "$FH/notes/projects/plain"
check_nogrep "conf: neutral README has no journal table" 'Three exits' "$(cat "$FH/notes/projects/plain/README.md")"
o="$(expect_fail "conf: forgejo create needs wt.forgejo_web" bash -c "cd '$WT_ROOT/demo' && env -u WT_FORGE_WEB '$WT' init --project demo2 --new demo2 --forge forgejo --org acme -y")"
check_grep "conf: refusal names the key" 'wt.forgejo_web' "$o"

# --- 3. new -------------------------------------------------------------------
out="$(cd "$WT_ROOT/demo" && run "$WT" new feat-a)"
WTA="$WT_ROOT/demo/src/demo/feat-a"
check "new: worktree dir"                test -d "$WTA"
check_eq "new: branch"                   "$(git -C "$WTA" symbolic-ref --short HEAD)" "feat-a"
check_eq "new: last line is the path"    "$(printf '%s\n' "$out" | tail -1)" "$WTA"
check "new: note seeded"                 test -f "$WT_STORE/demo/topics/feat-a.md"
check_grep "new: note carries branch"    'branch:\*\* `feat-a`' "$(cat "$WT_STORE/demo/topics/feat-a.md")"
check "new: CLAUDE.local.md symlink"     test -L "$WTA/CLAUDE.local.md"
check_eq "new: symlink resolves to note" "$(readlink -f "$WTA/CLAUDE.local.md")" "$(readlink -f "$WT_STORE/demo/topics/feat-a.md")"
check_eq "new: symlink invisible to git" "$(git -C "$WTA" status --porcelain)" ""
check "new: worktree registered"         grep -q "feat-a" <(git -C "$MAIN" worktree list)

# prefix from conf
sed -i 's|^prefix=.*|prefix=ll/feature/|' "$WT_STORE/demo/repos/demo.conf"
( cd "$WT_ROOT/demo" && "$WT" new feat-b >/dev/null 2>&1 )
check_eq "new: prefix applied"           "$(git -C "$WT_ROOT/demo/src/demo/feat-b" symbolic-ref --short HEAD)" "ll/feature/feat-b"
check "new: dir is the slug"             test -d "$WT_ROOT/demo/src/demo/feat-b"
sed -i 's|^prefix=.*|prefix=|' "$WT_STORE/demo/repos/demo.conf"
# --prefix per call
( cd "$WT_ROOT/demo" && "$WT" new --prefix ll/fix/ hotfix >/dev/null 2>&1 )
check_eq "new: --prefix per call"        "$(git -C "$WT_ROOT/demo/src/demo/hotfix" symbolic-ref --short HEAD)" "ll/fix/hotfix"

o="$(expect_fail "new: prefix without separator" bash -c "cd '$WT_ROOT/demo' && '$WT' new --prefix ll/feature nosep")"; check_grep "new: separator message" 'trailing separator' "$o"
check "new: no worktree left behind"     test ! -e "$WT_ROOT/demo/src/demo/nosep"

# --- 4. refusals ----------------------------------------------------------------
o="$(expect_fail "new: slug with slash"   bash -c "cd '$WT_ROOT/demo' && '$WT' new a/b")";   check_grep "new: slash message" 'contains "/"' "$o"
o="$(expect_fail "new: default branch"    bash -c "cd '$WT_ROOT/demo' && '$WT' new main")";  check_grep "new: main message" 'default branch' "$o"
expect_fail "new: existing dir"           bash -c "cd '$WT_ROOT/demo' && '$WT' new feat-a" >/dev/null
o="$(expect_fail "pr: refuses in main"    bash -c "cd '$MAIN' && '$WT' pr")";                check_grep "pr: main message" 'main is not a topic' "$o"
expect_fail "sync: refuses in main"       bash -c "cd '$MAIN' && '$WT' sync" >/dev/null
expect_fail "rm: refuses main"            bash -c "cd '$WT_ROOT/demo' && '$WT' rm main" >/dev/null
expect_fail "new: outside WT_ROOT"        bash -c "cd '$T' && '$WT' new zzz" >/dev/null

# --- 5. sync ------------------------------------------------------------------
( cd "$T/seed" && echo more >> README.md && git commit -qam "upstream moves" && git push -q )
( cd "$WTA" && echo a > a.txt && git add a.txt && git commit -qm "feat-a: add a" )
out="$(cd "$WTA" && run "$WT" sync)"
check "sync: base is ancestor after rebase" git -C "$WTA" merge-base --is-ancestor origin/main HEAD
check_eq "sync: one commit on top"       "$(git -C "$WTA" rev-list --count origin/main..HEAD)" "1"
check_grep "sync: reports replay"        '1 commits replayed' "$out"
out="$(cd "$WTA" && run "$WT" sync)"
check_grep "sync: up to date second time" 'up to date' "$out"

# conflict path
( cd "$T/seed" && echo conflict-upstream > c.txt && git add c.txt && git commit -qm "upstream c" && git push -q )
( cd "$WTA" && echo conflict-local > c.txt && git add c.txt && git commit -qm "local c" )
o="$(expect_fail "sync: conflict exits 1" bash -c "cd '$WTA' && '$WT' sync")"
check_grep "sync: names CONFLICT"        'CONFLICT' "$o"
check_grep "sync: lists the path"        'c\.txt' "$o"
( cd "$WTA" && git rebase --abort )
( cd "$WTA" && git reset -q --hard HEAD~1 )   # drop the conflicting local commit
( cd "$WTA" && "$WT" sync >/dev/null 2>&1 )

# --- 6. pr: squash by default -----------------------------------------------------
( cd "$WTA" && echo b > b.txt && git add b.txt && git commit -qm "feat-a: add b" \
             && echo c2 > c2.txt && git add c2.txt && git commit -qm "feat-a: add c2" )
check_eq "pr: 3 commits before"          "$(git -C "$WTA" rev-list --count origin/main..HEAD)" "3"
head_before="$(git -C "$WTA" rev-parse HEAD)"
out="$(cd "$WTA" && run "$WT" pr --dry-run -t "Feat A")"
check_grep "pr: dry-run shows squash plan" '3 commits → 1' "$out"
check_eq "pr: dry-run touches nothing"   "$(git -C "$WTA" rev-parse HEAD)" "$head_before"
check "pr: dry-run pushed nothing"       test -z "$(git -C "$T/remote/demo.git" branch --list feat-a)"

out="$(cd "$WTA" && run "$WT" pr -t "Feat A: everything")"
check_eq "pr: squashed to one"           "$(git -C "$WTA" rev-list --count origin/main..HEAD)" "1"
check_eq "pr: title is the subject"      "$(git -C "$WTA" log -1 --format=%s)" "Feat A: everything"
check_grep "pr: body carries subjects"   'feat-a: add a' "$(git -C "$WTA" log -1 --format=%b)"
check_grep "pr: body says squashed from" 'Squashed from 3 commits' "$(git -C "$WTA" log -1 --format=%b)"
check_eq "pr: pushed to origin"          "$(git -C "$T/remote/demo.git" rev-parse feat-a)" "$(git -C "$WTA" rev-parse HEAD)"
check_grep "pr: reports new upstream"    'new upstream' "$out"
check_grep "pr: unknown forge stops cleanly" 'branch pushed' "$out"
# second run: one more commit → re-squash + force-with-lease
( cd "$WTA" && echo d > d.txt && git add d.txt && git commit -qm "feat-a: fixup d" )
out="$(cd "$WTA" && run "$WT" pr -t "Feat A: everything")"
check_eq "pr: re-squashed to one"        "$(git -C "$WTA" rev-list --count origin/main..HEAD)" "1"
check_grep "pr: force-with-lease on rewrite" 'force-with-lease' "$out"
check_eq "pr: origin follows"            "$(git -C "$T/remote/demo.git" rev-parse feat-a)" "$(git -C "$WTA" rev-parse HEAD)"

# --- 7. pr: --no-squash and squash=false -------------------------------------------
( cd "$WT_ROOT/demo" && "$WT" new feat-c >/dev/null 2>&1 )
WTC="$WT_ROOT/demo/src/demo/feat-c"
( cd "$WTC" && echo 1 > one && git add one && git commit -qm "c1" && echo 2 > two && git add two && git commit -qm "c2" )
( cd "$WTC" && "$WT" pr --no-squash -t "C" >/dev/null 2>&1 )
check_eq "pr: --no-squash keeps commits" "$(git -C "$T/remote/demo.git" rev-list --count main..feat-c)" "2"

sed -i 's|^squash=.*|squash=false|' "$WT_STORE/demo/repos/demo.conf"
( cd "$WT_ROOT/demo" && "$WT" new feat-d >/dev/null 2>&1 )
WTD="$WT_ROOT/demo/src/demo/feat-d"
( cd "$WTD" && echo 1 > one && git add one && git commit -qm "d1" && echo 2 > two && git add two && git commit -qm "d2" )
( cd "$WTD" && "$WT" pr -t "D" >/dev/null 2>&1 )
check_eq "pr: squash=false keeps commits" "$(git -C "$T/remote/demo.git" rev-list --count main..feat-d)" "2"
sed -i 's|^squash=.*|squash=true|' "$WT_STORE/demo/repos/demo.conf"

expect_fail "pr: dirty tree refused"      bash -c "cd '$WTD' && touch dirty && '$WT' pr" >/dev/null
rm -f "$WTD/dirty"

# --- 7b. pr --base: a stacked PR targets another pushed topic ------------------------------------
( cd "$WT_ROOT/demo" && "$WT" new lonely >/dev/null 2>&1 )          # never pushed
( cd "$WT_ROOT/demo" && "$WT" new stack-top --from feat-c >/dev/null 2>&1 )
( cd "$WT_ROOT/demo/src/demo/stack-top" && echo s > s && git add s && git commit -qm "on top of feat-c" )
o="$(expect_fail "pr --base: unpushed base refused" bash -c "cd '$WT_ROOT/demo/src/demo/stack-top' && '$WT' pr --base lonely -t x")"
check_grep "pr --base: names the missing base"  'not on origin' "$o"
out="$(cd "$WT_ROOT/demo/src/demo/stack-top" && run "$WT" pr --dry-run --base feat-c -t "stacked")"
check_grep "pr --base: dry-run shows the stacked base" 'stacked — rebases onto' "$out"
check_grep "pr --base: ahead counted against the base" 'ahead 1 / behind 0 of origin/feat-c' "$out"
out="$(cd "$WT_ROOT/demo/src/demo/stack-top" && run "$WT" pr --base feat-c --no-squash -t "stacked")"
check_eq "pr --base: one commit over feat-c on origin" "$(git -C "$T/remote/demo.git" rev-list --count feat-c..stack-top)" "1"
( cd "$WT_ROOT/demo" && "$WT" rm lonely --force >/dev/null 2>&1; "$WT" rm stack-top --force >/dev/null 2>&1 )

# --- 7c. stacked branches are detected; a blind squash is refused --------------------------------
( cd "$WT_ROOT/demo" && "$WT" new stack-from --from feat-c >/dev/null 2>&1 )
check_grep "new --from: recorded in the note"   '\*\*from:\*\* `feat-c`' "$(cat "$WT_STORE/demo/topics/stack-from.md")"
( cd "$WT_ROOT/demo/src/demo/stack-from" && echo f > f && git add f && git commit -qm "over feat-c" )
out="$(cd "$WT_ROOT/demo/src/demo/stack-from" && run "$WT" pr --dry-run -t t)"
check_grep "pr: stacked base taken from the note" 'stacked +on origin/feat-c' "$out"
check_grep "pr: stacked dry-run counts vs feat-c"  'ahead 1 / behind 0 of origin/feat-c' "$out"
( cd "$WT_ROOT/demo" && "$WT" new stack-blind >/dev/null 2>&1 )
( cd "$WT_ROOT/demo/src/demo/stack-blind" && git reset -q --hard origin/feat-c && echo g > g && git add g && git commit -qm "over feat-c, no note" )
o="$(expect_fail "pr: stacked without a base is refused" bash -c "cd '$WT_ROOT/demo/src/demo/stack-blind' && '$WT' pr -t t")"
check_grep "pr: refusal names the parent"      'it is stacked; say which: wt pr --base feat-c' "$o"
check "pr: refusal left history alone"          test "$(git -C "$WT_ROOT/demo/src/demo/stack-blind" rev-list --count origin/feat-c..HEAD)" = 1
( cd "$WT_ROOT/demo" && "$WT" new needs-title >/dev/null 2>&1 )
( cd "$WT_ROOT/demo/src/demo/needs-title" && echo 1 > a && git add a && git commit -qm a1 && echo 2 > b && git add b && git commit -qm a2 )
o="$(expect_fail "pr: two commits without -t refused" bash -c "cd '$WT_ROOT/demo/src/demo/needs-title' && '$WT' pr")"
check_grep "pr: says why a title is needed"     '2 commits need a PR title' "$o"
o="$(expect_fail "pr: --no-squash without -t refused too" bash -c "cd '$WT_ROOT/demo/src/demo/needs-title' && '$WT' pr --no-squash")"
check_grep "pr: same refusal with --no-squash"  '2 commits need a PR title' "$o"
check "pr: nothing pushed on refusal"           test -z "$(git -C "$T/remote/demo.git" branch --list needs-title)"
( cd "$WT_ROOT/demo" && for w in stack-from stack-blind needs-title; do "$WT" rm $w --force >/dev/null 2>&1; done )

# --- 8. rm ----------------------------------------------------------------------
o="$(expect_fail "rm: not merged refused" bash -c "cd '$WT_ROOT/demo' && '$WT' rm feat-a")"
check_grep "rm: says not merged"         'not merged' "$o"
( cd "$T/seed" && git fetch -q && git merge -q --no-ff origin/feat-a -m "merge feat-a" && git push -q )
out="$(cd "$WT_ROOT/demo" && run "$WT" rm feat-a)"
check "rm: worktree gone"                test ! -e "$WTA"
check "rm: branch gone"                  test -z "$(git -C "$MAIN" branch --list feat-a)"
check "rm: note archived"                test -f "$WT_STORE/demo/topics/archive/feat-a.md"
check "rm: note moved not copied"        test ! -e "$WT_STORE/demo/topics/feat-a.md"
check_grep "rm: reports ancestor"        'ancestor of origin/main' "$out"

( cd "$WT_ROOT/demo" && "$WT" new feat-e >/dev/null 2>&1 && touch "$WT_ROOT/demo/src/demo/feat-e/untracked" )
o="$(expect_fail "rm: dirty refused"     bash -c "cd '$WT_ROOT/demo' && '$WT' rm feat-e")"
check_grep "rm: dirty message"           'uncommitted' "$o"
( cd "$WT_ROOT/demo" && "$WT" rm feat-e --force >/dev/null 2>&1 )
check "rm: --force removes dirty"        test ! -e "$WT_ROOT/demo/src/demo/feat-e"

( cd "$WT_ROOT/demo" && "$WT" new feat-f >/dev/null 2>&1 )
( cd "$WT_ROOT/demo/src/demo/feat-f" && echo f > f && git add f && git commit -qm "never pushed" )
o="$(expect_fail "rm: unpushed refused"  bash -c "cd '$WT_ROOT/demo' && '$WT' rm feat-f")"
check_grep "rm: unpushed message"        'never pushed' "$o"
( cd "$WT_ROOT/demo" && "$WT" rm feat-f --force >/dev/null 2>&1 )
check "rm: --force removes unpushed"     test ! -e "$WT_ROOT/demo/src/demo/feat-f"

# --- 9. ls / path -----------------------------------------------------------------
porc="$("$WT" ls -a --porcelain)"
check_grep "ls: lists main"              $'^demo\tdemo\tmain\tmain\t' "$porc"
check_grep "ls: lists feat-c"            $'^demo\tdemo\tfeat-c\tfeat-c\t' "$porc"
table="$(cd "$WT_ROOT/demo" && "$WT" ls)"
check_grep "ls: header"                  'PROJECT +REPO +SLUG +BRANCH' "$table"
check_grep "ls: feat-c ahead"            'feat-c +feat-c +\+2/-[0-9]+' "$table"
check_grep "ls: main vs origin/main"     'main +main +(=|\+0/-[0-9]+)' "$table"
check_eq "path: unique match"            "$("$WT" path feat-c)" "$WTC"
check_eq "path: match on branch"         "$("$WT" path ll/fix/hotfix)" "$WT_ROOT/demo/src/demo/hotfix"
expect_fail "path: ambiguous without tty" "$WT" path feat >/dev/null
check_eq "cd (no wrapper): prints the path"  "$("$WT" cd feat-c 2>/dev/null)" "$WTC"
check_grep "cd (no wrapper): explains"       'zsh wrapper' "$("$WT" cd feat-c 2>&1 >/dev/null)"
expect_fail "path: no match"              "$WT" path nothing-like-this >/dev/null

# --- 10. init --migrate ----------------------------------------------------------------
mkdir -p "$WT_ROOT/old/src"
git clone -q "$DEMO_URL" "$WT_ROOT/old/src/demo"
out="$(cd "$WT_ROOT/old" && run "$WT" init --migrate -y)"
check "migrate: main exists"             test -d "$WT_ROOT/old/src/demo/main/.git"
check "migrate: old path is now a dir"   test ! -e "$WT_ROOT/old/src/demo/.git"
check "migrate: conf written"            test -f "$WT_STORE/old/repos/demo.conf"
check_grep "migrate: reported"           'src/demo → src/demo/main' "$out"
out="$(cd "$WT_ROOT/old" && run "$WT" init --migrate -y)"
check_grep "migrate: idempotent"         'already new layout' "$out"
mkdir -p "$WT_ROOT/dirty/src"
git clone -q "$DEMO_URL" "$WT_ROOT/dirty/src/demo" && touch "$WT_ROOT/dirty/src/demo/x"
o="$(expect_fail "migrate: dirty refused" bash -c "cd '$WT_ROOT/dirty' && '$WT' init --migrate -y")"
check_grep "migrate: dirty message"      'dirty' "$o"

# --- 11. init --new --remote, --mine ---------------------------------------------------
git init -q --bare -b main "$T/remote/fresh.git"
out="$(run "$WT" init --project fresh --new fresh --remote "file://$T/remote/fresh.git" --mine -y)"
FM="$WT_ROOT/fresh/src/fresh/main"
check "new repo: main initialised"       test -d "$FM/.git"
check_eq "new repo: on main"             "$(git -C "$FM" symbolic-ref --short HEAD)" "main"
check_eq "new repo: origin set"          "$(git -C "$FM" remote get-url origin)" "file://$T/remote/fresh.git"
check_eq "new repo: pushed"              "$(git -C "$T/remote/fresh.git" rev-parse main)" "$(git -C "$FM" rev-parse HEAD)"
check "new repo: --mine writes allows"   test -f "$FM/.claude/settings.local.json"
check_grep "new repo: allows content"    'Bash\(python3 \*\)' "$(cat "$FM/.claude/settings.local.json")"
check_grep "new repo: conf allow_interp" '^allow_interp=true$' "$(cat "$WT_STORE/fresh/repos/fresh.conf")"
check_eq "new repo: allows excluded"     "$(git -C "$FM" status --porcelain)" ""
( cd "$WT_ROOT/fresh" && "$WT" new first >/dev/null 2>&1 )
check "new repo: wt new works"           test -d "$WT_ROOT/fresh/src/fresh/first"

# --- 12. --clone adds a sibling repo; multi-repo needs --repo -------------------------------
out="$(cd "$WT_ROOT/demo" && run "$WT" init --clone "file://$T/remote/fresh.git" -y)"
check "sibling: cloned"                  test -d "$WT_ROOT/demo/src/fresh/main/.git"
check "sibling: conf"                    test -f "$WT_STORE/demo/repos/fresh.conf"
o="$(expect_fail "sibling: new needs --repo" bash -c "cd '$WT_ROOT/demo' && '$WT' new amb")"
check_grep "sibling: lists repos"        'several repos' "$o"
( cd "$WT_ROOT/demo" && "$WT" new --repo fresh amb >/dev/null 2>&1 )
check "sibling: --repo works"            test -d "$WT_ROOT/demo/src/fresh/amb"
( cd "$WT_ROOT/demo/src/fresh" && "$WT" new amb2 >/dev/null 2>&1 )
check "sibling: cwd under src/<repo> picks it" test -d "$WT_ROOT/demo/src/fresh/amb2"

# --- 13. --track an existing remote branch ----------------------------------------------------
( cd "$WT_ROOT/demo" && "$WT" new --repo demo --track feat-c >/dev/null 2>&1 ) || true
o="$(expect_fail "track: local branch already checked out" bash -c "cd '$WT_ROOT/demo/src/demo' && '$WT' new --track feat-c")"
( cd "$WT_ROOT/demo/src/demo" && "$WT" rm feat-c --force >/dev/null 2>&1 )
out="$(cd "$WT_ROOT/demo/src/demo" && run "$WT" new --track feat-c)"
check "track: worktree from remote branch" test -d "$WT_ROOT/demo/src/demo/feat-c"
check_eq "track: upstream set"           "$(git -C "$WT_ROOT/demo/src/demo/feat-c" rev-parse --abbrev-ref '@{u}')" "origin/feat-c"

# --- 14. doctor runs ------------------------------------------------------------------------
out="$(run "$WT" doctor -a)"
check_grep "doctor: covers demo"         'demo / demo' "$out"
check_grep "doctor: covers fresh"        'fresh / fresh' "$out"
check_grep "doctor: unknown forge flagged" 'unknown forge' "$out"

# --- 14b. prefix inference skips bot branches ------------------------------------------------
( cd "$T/seed" && git checkout -q -b claude/auto-1 && git commit -q --allow-empty -m x && git push -q -u origin claude/auto-1 \
              && git checkout -q -b claude/auto-2 main && git commit -q --allow-empty -m x && git push -q -u origin claude/auto-2 \
              && git checkout -q -b ll/feature/real main && git commit -q --allow-empty -m x && git push -q -u origin ll/feature/real \
              && git checkout -q main )
mkdir -p "$WT_ROOT/infer/src"; git clone -q "$DEMO_URL" "$WT_ROOT/infer/src/demo"
( cd "$WT_ROOT/infer" && "$WT" init --migrate -y >/dev/null 2>&1 )
check_grep "infer: ll/feature/ beats claude/" '^prefix=ll/feature/$' "$(cat "$WT_STORE/infer/repos/demo.conf")"

# --- 15. help ------------------------------------------------------------------------------
check_grep "help: synopsis"              'wt init' "$("$WT" help)"
check_grep "help: --help alias"          'wt doctor' "$("$WT" --help)"
check_grep "help new: man section"       'Create a topic' "$("$WT" help new)"
check_grep "help pr: man section"        'force-with-lease' "$("$WT" help pr)"
check "help new: stops at next command"  test -z "$("$WT" help new | grep -E '^   wt ls')"

# --- 16. art: the weight grammar -------------------------------------------
# The banners are pure presentation, so drive them directly instead of running
# every subcommand again with the art switched on.
cat > "$T/art.sh" <<ART
. "$HERE/../lib/sckit.sh"
C_DIM="\$A_DIM" C_OK="\$A_SEA" C_WARN="\$A_ERR" C_PATH="\$A_LAV" C_ART="\$A_SEA" C_0="\$A_0" C_MINE="\$A_LIME"
eval "\$(sed -n '/^chain() {/,/^# ------.*\$/p' "$WT" | head -n -2)"
art_logo; art_new topic/demo main; art_sync; art_pr 4 1; art_pr 2 x; art_rm demo
art_init /data/x repo "\$HOME/store"
ART
art_out="$(SC_TOOL=wt env -u WT_NO_ART WT_ART=1 bash "$T/art.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"

check_grep "art: heavy trunk"              '━━●━'    "$art_out"
check_grep "art: light topic"              '╭─◆'     "$art_out"
check_grep "art: dashed means gone"        '╭╌◆╌╌◆'  "$art_out"
check_grep "art: weight-change junction"   '┷|┿'     "$art_out"
check_grep "art: landed node"              '●'       "$art_out"
check_grep "art: elsewhere node"           '◇'       "$art_out"
check_grep "art: durable clone is heavy"   '┣━━ main/' "$art_out"
check_grep "art: the family mark"          '┫ ✦ ┣'   "$art_out"
check_grep "art: becomes arrow"            '→'       "$art_out"
check_grep "art: destination arrow"        '▶'       "$art_out"

# retired glyphs: one dingbat that can render double width, and two arrows
# that meant the same thing as the two above
check_nogrep "art: no scissors"            '✂'       "$art_out"
check_nogrep "art: no double arrow"        '⇒'       "$art_out"
check_nogrep "art: no dashed arrow"        '⇢'       "$art_out"

widest="$(printf '%s\n' "$art_out" | awk '{ n = length($0); if (n > m) m = n } END { print m+0 }')"
check "art: inside the 72 column budget"   test "$widest" -le 72

# and the gating still holds: no art in the suite's default environment
check_nogrep "art: silent with WT_NO_ART"  '╭─◆'     "$("$WT" help)"

# --- summary ---------------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
