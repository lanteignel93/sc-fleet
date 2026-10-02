#!/usr/bin/env bash
# Run every suite; exit 1 if any failed. Each suite is self-contained and
# offline: temp dirs under mktemp, a throwaway HOME where it matters, never
# the real config, tmux server or user manager.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
failed=()
for t in test_*.sh test_*.py; do
  [[ -f "$t" ]] || continue
  case "$t" in *.py) cmd=(python3 "$t") ;; *) cmd=(bash "$t") ;; esac
  if out="$("${cmd[@]}" 2>&1)"; then
    printf '  ok    %-20s %s\n' "$t" "$(tail -n 1 <<<"$out")"
  else
    printf '  FAIL  %-20s %s\n' "$t" "$(tail -n 1 <<<"$out")"
    grep -E '^FAIL' <<<"$out" | sed 's/^/        /' | head -n 20
    failed+=("$t")
  fi
done
if (( ${#failed[@]} )); then
  printf 'tests: %d suite(s) failed: %s\n' "${#failed[@]}" "${failed[*]}"
  exit 1
fi
printf 'tests: all suites passed\n'
