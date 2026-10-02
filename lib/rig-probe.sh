#!/usr/bin/env bash
# rig-probe.sh — read-only box facts, shipped to a box on stdin.
#
# Invoked as `ssh <box> /bin/bash -s -- <repos> <mounts> <timers> < this file`.
# It is never installed remotely, so `rig` does not have to exist on the far
# side. `/bin/bash -s` also bypasses the login shell, so a box in the middle
# of a broken dotfile still answers.
#
# READ-ONLY BY CONSTRUCTION, in three layers, because any one alone is a
# promise rather than a property:
#
#   1. every git call goes through g(), which whitelists read subcommands and
#      injects --no-optional-locks, so there is no index refresh and therefore
#      no write. That also matters on an NFS home.
#   2. NO FETCH, ever. Fetching writes refs. This probe reports SHAs; all
#      ancestry arithmetic happens on the CALLER, which fetches once locally.
#   3. tests/test_rig.sh greps this file against a command whitelist.
#
# Output is `key=value` lines under LC_ALL=C, ending with `end=ok`. That
# sentinel is load-bearing: a stream truncated because ssh died mid-write is
# caught by the MISSING SENTINEL, not by an exit code.
#
# Contains no hostnames, mounts or site paths: everything specific arrives in
# argv. That is what keeps the tool publishable.

set -u
export LC_ALL=C GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true

REPOS="${1:-}"; MOUNTS="${2:-}"; TIMERS="${3:-}"

say() { printf '%s\n' "$*"; }

# g <dir> <verb> [args...] — read-only git, or a refusal the caller can see.
g() {
  case "${2:-}" in
    rev-parse|status|config|for-each-ref|rev-list|symbolic-ref|log|merge-base) ;;
    *) say "probe_error=git_verb_denied:${2:-empty}"; return 1 ;;
  esac
  local d="$1"; shift
  git --no-optional-locks -C "$d" "$@" 2>/dev/null
}

say "probe=1"
say "host=$(hostname -s 2>/dev/null || echo '?')"
say "user=$(id -un 2>/dev/null || echo '?')"
say "os=$( . /etc/os-release 2>/dev/null; printf '%s-%s' "${ID:-?}" "${VERSION_ID:-?}" )"
say "kernel=$(uname -r 2>/dev/null || echo '?')"
say "epoch=$(date +%s)"

# HOME identity, hashed. Two boxes on one export match without this file ever
# naming the export — the roster is public, so the source string stays out.
if command -v findmnt >/dev/null 2>&1; then
  read -r _fs _src <<<"$(findmnt -no FSTYPE,SOURCE --target "$HOME" 2>/dev/null || echo '? ?')"
else
  _fs='?'; _src='?'
fi
say "home_fs=${_fs:-?}"
say "home_id=$(printf '%s' "${_src:-?}" | cksum 2>/dev/null | cut -d' ' -f1)"

# Scheduler capability is probed, never assumed: some boxes have no user
# manager at all, which is why a cron fallback exists.
if systemctl --user show-environment >/dev/null 2>&1; then
  say "systemd_user=yes"
  say "linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo '?')"
else
  say "systemd_user=no"
  say "linger=n/a"
fi

# Capacity, because two of this tool's reasons for existing were a full
# scratch disk and a memory reap.
if command -v df >/dev/null 2>&1; then
  for d in "$HOME" /tmp; do
    [[ -d "$d" ]] || continue
    say "space=${d} avail_mb=$(df -Pm "$d" 2>/dev/null | awk 'NR==2{print $4}')"
  done
fi
if [[ -r /proc/meminfo ]]; then
  say "mem_total_mb=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)"
  say "mem_avail_mb=$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)"
fi

# --- repos ------------------------------------------------------------------
# Reported, never judged. "behind" and "ahead" are the caller's arithmetic,
# because only the caller has fetched.
_seen_repos=""
for r in $REPOS; do
  d="${r/#\~/$HOME}"
  if [[ ! -d "$d/.git" ]] && [[ ! -f "$d/.git" ]]; then
    say "repo=${r} state=absent"
    continue
  fi
  real="$(readlink -f "$d" 2>/dev/null || printf '%s' "$d")"
  # One repo reached by two names is one repo. A roster that lists both
  # spellings of a per-box path (the dots live under different names on
  # different boxes) must not report it twice.
  case " $_seen_repos " in *" $real "*) continue ;; esac
  _seen_repos+="$real "
  br="$(g "$d" symbolic-ref --short HEAD || echo DETACHED)"
  head="$(g "$d" rev-parse HEAD)"
  up="$(g "$d" rev-parse '@{u}' || echo -)"
  upname="$(g "$d" rev-parse --abbrev-ref '@{u}' || echo -)"
  dirty="$(g "$d" status --porcelain | wc -l | tr -d ' ')"
  mid=no
  gitdir="$(g "$d" rev-parse --git-dir || echo "$d/.git")"
  case "$gitdir" in /*) ;; *) gitdir="$d/$gitdir" ;; esac
  for m in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD; do
    [[ -e "$gitdir/$m" ]] && mid=yes
  done
  fh="$gitdir/FETCH_HEAD"
  if [[ -f "$fh" ]]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$fh" 2>/dev/null || echo 0) ) / 3600 ))
  else
    age=-
  fi
  say "repo=${r} real=${real} branch=${br:-?} head=${head:--} tracked=${up:--} upname=${upname:--} dirty=${dirty:-0} midop=${mid} fetch_h=${age}"
done

# --- mounts -----------------------------------------------------------------
# A path the caller asked about, answered yes or no. The tool carries no list.
for m in $MOUNTS; do
  say "mount=${m} present=$([[ -e "$m" ]] && echo yes || echo no)"
done

# --- timers -----------------------------------------------------------------
if systemctl --user show-environment >/dev/null 2>&1; then
  for t in $TIMERS; do
    en="$(systemctl --user is-enabled "$t.timer" 2>/dev/null || echo absent)"
    ac="$(systemctl --user is-active "$t.timer" 2>/dev/null || echo inactive)"
    res="$(systemctl --user show -p Result --value "$t.service" 2>/dev/null || echo '?')"
    last="$(systemctl --user show -p ExecMainExitTimestamp --value "$t.service" 2>/dev/null || echo '')"
    lastsec=0
    [[ -n "$last" ]] && lastsec="$(date -d "$last" +%s 2>/dev/null || echo 0)"
    say "timer=${t} enabled=${en} active=${ac} result=${res} last=${lastsec}"
  done
  say "failed_units=$(systemctl --user --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')"
else
  # cron fallback: count crontab lines naming any expected timer
  n=0
  if [[ -n "$TIMERS" ]]; then
    ct="$(crontab -l 2>/dev/null || true)"
    for t in $TIMERS; do n=$(( n + $(grep -cF -- "$t" <<<"$ct" || true) )); done
  fi
  say "cron_lines=$n"
fi

# --- the fleet on PATH -------------------------------------------------------
# Observed, not judged: the caller compares against its own expected set.
say "bin=$(ls -1 "$HOME/.local/bin" 2>/dev/null | tr '\n' ',' )"

say "end=ok"
