#!/usr/bin/env bash
# rig-disk.sh — the du triage behind `rig doctor --disk`.
#
#   bash rig-disk.sh ROOT OUTDIR BUDGET_SECONDS
#
# Ported from a one-off script that lived in one box's ~/bin; now it lives
# beside the tool that runs it. ONE traversal (du -x -B1: directories only,
# one filesystem), niced and ioniced, under a time budget. Writes exactly two
# files under OUTDIR — the raw gzipped traversal and a markdown report — and
# prints a key=value summary on stdout for rig to render. Deletes nothing,
# ever. No site strings: the root is an argument, the junk patterns are
# generic. A partial traversal (budget hit) is reported as such, never
# passed off as complete.
set -u

ROOT=${1:?usage: rig-disk.sh ROOT OUTDIR BUDGET}
OUTDIR=${2:?usage: rig-disk.sh ROOT OUTDIR BUDGET}
BUDGET=${3:-300}

mkdir -p "$OUTDIR" || exit 1
NAME=$(printf '%s' "$ROOT" | sed 's|^/||; s|/$||; s|/|_|g'); [[ -n "$NAME" ]] || NAME=root
RAW="$OUTDIR/$NAME.du.gz"
REPORT="$OUTDIR/$NAME.md"
ERRS="$OUTDIR/.$NAME.err"
TMP="$OUTDIR/.$NAME.junk.$$"
trap 'rm -f "$ERRS" "$TMP"' EXIT

# --- the one traversal --------------------------------------------------------
run_du() {
  local pre=(nice -n 19)
  command -v ionice >/dev/null 2>&1 && pre+=(ionice -c 3)
  timeout -k 5 "$BUDGET" "${pre[@]}" du -x -B1 "$ROOT" 2>"$ERRS"
}
START=$(date +%s)
run_du | gzip > "$RAW"
DU_RC=${PIPESTATUS[0]}
ELAPSED=$(( $(date +%s) - START ))
PARTIAL=no; [[ $DU_RC -eq 124 || $DU_RC -eq 137 ]] && PARTIAL=yes
NDIRS=$(zcat "$RAW" | wc -l | tr -d ' ')
NDENIED=$(grep -c 'Permission denied' "$ERRS" 2>/dev/null || true); NDENIED=${NDENIED:-0}
read -r AVAIL USED < <(df -Pm "$ROOT" 2>/dev/null | awk 'NR==2{print $4, $3}')
AVAIL=${AVAIL:-}; USED=${USED:-}

# --- helpers over the raw file ------------------------------------------------
# du lines are "<bytes>\t<path>"; paths may carry spaces, so the path is the
# line with the byte count stripped, never awk's $2.
human() {
  awk 'function h(b){ split("B K M G T P",u," "); for(i=1;b>=1024&&i<6;i++) b/=1024; return sprintf("%.1f%s",b,u[i]) }
       { p=$0; sub(/^[0-9]+\t/, "", p); printf "%10s  %s\n", h($1), p }'
}

# top_at_depth N: every directory exactly N levels below the root, largest first
top_at_depth() {
  zcat "$RAW" | awk -v root="$ROOT" -v d="$1" '
    { path=$0; sub(/^[0-9]+\t/, "", path)
      if (path == root) next
      base = (root == "/") ? 1 : length(root) + 1
      rel = substr(path, base + 1)
      n = gsub(/\//, "/", rel)
      if (n + 1 == d) print $1 "\t" path }' | sort -rn
}

# junk_scan REGEX: directories whose basename matches, largest first, into TMP
junk_scan() {
  # The root is never junk, whatever it is called: a root named tmp or
  # scratch matches the tmp-old-backup pattern by name and was counted whole.
  zcat "$RAW" | awk -v re="$1" -v root="$ROOT" '
    { path=$0; sub(/^[0-9]+\t/, "", path)
      if (path == root) next
      n = split(path, seg, "/")
      if (seg[n] ~ re) print $1 "\t" path }' | sort -rn > "$TMP"
}

# token ;; regex ;; label — the token is what rig shows and greps, the label
# is for the report. ";;" never occurs in the regexes.
JUNK=(
  'trash;;^(#recycle|[.]Trash-.*|[$]RECYCLE[.]BIN|[.]recycle)$;;Recycle bins / trash'
  'pycache;;^__pycache__$;;__pycache__'
  'jupyter-ckpt;;^[.]ipynb_checkpoints$;;Jupyter checkpoints'
  'node_modules;;^node_modules$;;node_modules'
  'caches;;^([.]cache|pip|[.]pip_cache|pkgs)$;;Caches (.cache, pip, conda pkgs)'
  'ml-artifacts;;^(wandb|mlruns|lightning_logs|checkpoints|catboost_info|tensorboard|tb_logs)$;;ML run artifacts'
  'venvs;;^([.]?venv|env)$;;Virtualenvs (venv, .venv, env)'
  'conda-envs;;^envs$;;Conda envs'
  'git;;^[.]git$;;.git directories'
  'tmp-old-backup;;^(tmp|temp|scratch|old|OLD|backup|backups|bak|archive_old|deprecated)$;;tmp / scratch / old / backup-named dirs'
)

# --- the report ---------------------------------------------------------------
SUMMARY_JUNK=""
{
  echo "# Disk triage: $ROOT"
  echo
  echo "- Date: $(date '+%Y-%m-%d %H:%M')"
  echo "- Traversal: $((ELAPSED / 60))m $((ELAPSED % 60))s$( [[ $PARTIAL == yes ]] && printf ' — PARTIAL, budget of %ss hit' "$BUDGET" )"
  echo "- Directories seen: $NDIRS (permission denied: $NDENIED)"
  echo
  echo '```'
  df -h "$ROOT" 2>/dev/null | tail -1
  echo '```'
  for spec in "1 25" "2 40" "3 40"; do
    set -- $spec
    echo
    echo "## Top $2 directories at depth $1"
    echo '```'
    top_at_depth "$1" | head -n "$2" | human
    echo '```'
  done
  echo
  echo "## Junk / prune candidates (review before touching anything)"
  for e in "${JUNK[@]}"; do
    tok=${e%%;;*}; rest=${e#*;;}; re=${rest%%;;*}; label=${rest#*;;}
    junk_scan "$re"
    total=$(awk '{s+=$1} END{print s+0}' "$TMP"); n=$(wc -l < "$TMP" | tr -d ' ')
    (( total > 0 )) || continue
    SUMMARY_JUNK+="junk=1 label=$tok total=$total n=$n"$'\n'
    printf '\n### %s — total %s in %s dir(s)\n' "$label" "$(printf '%s\t-\n' "$total" | human | awk '{print $1}')" "$n"
    echo '```'
    head -n 15 "$TMP" | human
    echo '```'
  done
  echo
  echo "Raw traversal: $RAW  (zcat it for ad-hoc queries)"
} > "$REPORT"

# --- the summary rig renders --------------------------------------------------
echo "root=$ROOT"
echo "name=$NAME"
echo "raw=$RAW"
echo "report=$REPORT"
echo "elapsed=$ELAPSED"
echo "dirs=$NDIRS"
echo "denied=$NDENIED"
echo "partial=$PARTIAL"
echo "avail_mb=$AVAIL"
echo "used_mb=$USED"
top_at_depth 1 | head -n 5 | awk -F'\t' '{print "top1=" $1 " " $2}'
top_at_depth 2 | head -n 5 | awk -F'\t' '{print "top2=" $1 " " $2}'
printf '%s' "$SUMMARY_JUNK"
echo "end=ok"
