#!/usr/bin/env bash
# prepublish.sh — is this checkout safe to make public? Prints READY or
# NOT READY with every failed check. Changes nothing and never pushes.
#
#   tree      no uncommitted or untracked changes
#   identity  every author and committer is this repo's user.email, and that
#             address is a GitHub noreply one
#   history   no `sync: <box>` auto-commits, which name a host
#   gate      leakgate --strict over the tree and over all history
#   secrets   gitleaks over the tree and over all history
#   tests     tests/run.sh, which includes the throwaway-HOME install smoke test
#   remotes   none, or only the public repo named by $SC_PUBLISH_REMOTE
#             (default github.com/lanteignel93/sc-fleet)
set -uo pipefail

top="$(git rev-parse --show-toplevel)" || exit 2
cd "$top"
WANT_REMOTE="${SC_PUBLISH_REMOTE:-github.com/lanteignel93/sc-fleet}"
GL="$(command -v gitleaks || true)"; [[ -n "$GL" ]] || GL="$HOME/.local/bin/gitleaks"
bad=0
say() { printf '  %-9s %-4s %s\n' "$1" "$2" "$3"; }
ok() { say "$1" ok "$2"; }
no() { say "$1" FAIL "$2"; bad=$((bad+1)); }

if [[ -z "$(git status --porcelain)" ]]; then ok tree "clean"; else no tree "$(git status --porcelain | wc -l | tr -d ' ') uncommitted path(s)"; fi

me="$(git config user.email || true)"
if [[ "$me" != *@users.noreply.github.com ]]; then
  no identity "user.email is not a GitHub noreply address"
elif ! git rev-parse -q --verify HEAD >/dev/null; then
  no identity "no commits yet"
else
  others="$(git log --all --format='%ae%n%ce' | sort -u | grep -vxF -- "$me" || true)"
  if [[ -z "$others" ]]; then ok identity "every commit is $me"
  else no identity "$(wc -l <<<"$others" | tr -d ' ') other address(es) in history"; fi
fi

n="$(git log --all --oneline --grep '^sync: ' | wc -l | tr -d ' ')"
if [[ "$n" == 0 ]]; then ok history "no sync: auto-commits"; else no history "$n sync: commit(s)"; fi

if o="$(python3 tools/leakgate.py --strict -q 2>&1)"; then ok gate "tree clean"; else no gate "tree: $(tail -n 1 <<<"$o")"; fi
if o="$(python3 tools/leakgate.py --history --strict -q 2>&1)"; then ok gate "history clean"; else no gate "history: $(tail -n 1 <<<"$o")"; fi

if [[ -x "$GL" ]]; then
  if "$GL" dir --no-banner --redact --config .gitleaks.toml . >/dev/null 2>&1; then ok secrets "gitleaks tree clean"; else no secrets "gitleaks tree: run gitleaks dir -v ."; fi
  if "$GL" git --no-banner --redact --config .gitleaks.toml . >/dev/null 2>&1; then ok secrets "gitleaks history clean"; else no secrets "gitleaks history: run gitleaks git -v ."; fi
else
  no secrets "gitleaks not installed"
fi

if o="$(bash tests/run.sh 2>&1)"; then ok tests "$(tail -n 1 <<<"$o")"; else no tests "$(tail -n 1 <<<"$o")"; fi

remotes="$(git remote -v | awk '{print $2}' | sort -u)"
if [[ -z "$remotes" ]]; then
  ok remotes "none yet"
else
  # scp, ssh:// and https forms all normalise to host/owner/repo
  stray="$(sed -E 's#^ssh://##; s#^https://##; s#^[^@/]+@##; s#:#/#; s#\.git$##' <<<"$remotes" |
           grep -vxF -- "$WANT_REMOTE" || true)"
  if [[ -z "$stray" ]]; then ok remotes "only $WANT_REMOTE"; else no remotes "unexpected remote(s): $(tr '\n' ' ' <<<"$stray")"; fi
fi

echo
if [[ $bad -eq 0 ]]; then echo "READY: nothing here would leak; publishing is still a human's call"; exit 0; fi
echo "NOT READY: $bad check(s) failed"
exit 1
