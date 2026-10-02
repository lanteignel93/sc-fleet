#!/usr/bin/env bash
# install.sh — link the fleet from this checkout into $HOME. Idempotent.
#
#   install.sh              apply: link what is missing, replace what is wrong
#   install.sh --check      report gaps only, change nothing; exit 1 if any
#   install.sh --uninstall  remove every link that points into this checkout
#
# What it links:
#   bin/<tool>         -> ~/.local/bin/<tool>            (sc, plus every marked tool)
#   man/<tool>.1       -> ~/.local/share/man/man1/<tool>.1
#   completions/_<t>   -> ${ZDOTDIR:-~}/.zsh_functions/_<t>
#   this checkout      -> ${XDG_DATA_HOME:-~/.local/share}/sc-fleet
#
# The last one is the stable path other things source through
# (shell/fleet.zsh from .zshrc, lib/sckit.sh from an outside member), so moving
# the checkout is one re-run, not an edit everywhere.
#
# It never writes the config (~/.config/sc-fleet/), an rc file, or anything
# outside the four destinations above. --check line kinds:
#   MISSING  nothing there          WRONG    a link to somewhere else
#   NOTLINK  a real file there      FOREIGN  a link into another copy of the fleet
#   ORPHAN   a link into this checkout that the manifest no longer has
# Apply replaces WRONG and FOREIGN links and backs up a NOTLINK file beside
# itself; ORPHANs are reported, never removed, except by --uninstall.

set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
BIN_DIR="$HOME/.local/bin"
MAN_DIR="$HOME/.local/share/man/man1"
FPATH_DIR="${ZDOTDIR:-$HOME}/.zsh_functions"
HOME_LINK="${XDG_DATA_HOME:-$HOME/.local/share}/sc-fleet"

MODE=apply
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --uninstall) MODE=uninstall ;;
  -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "refuse    unknown option $1 (--check, --uninstall, or no argument)" >&2; exit 1 ;;
esac

# --- the manifest -----------------------------------------------------------
# "source<TAB>dest" lines; the one source of truth for every mode. Membership
# is the `# sc-fleet` marker, the rule `sc` uses; sc itself carries none.
manifest() {
  local f name
  printf '%s\t%s\n' "$SRC" "$HOME_LINK"
  for f in "$SRC/bin/"*; do
    [[ -f "$f" && -x "$f" ]] || continue
    name="${f##*/}"
    [[ "$name" == sc ]] || grep -qm1 '^# sc-fleet' "$f" 2>/dev/null || continue
    printf '%s\t%s\n' "$f" "$BIN_DIR/$name"
    [[ -f "$SRC/man/$name.1" ]] && printf '%s\t%s\n' "$SRC/man/$name.1" "$MAN_DIR/$name.1"
  done
  for f in "$SRC/completions/"_*; do
    [[ -f "$f" ]] && printf '%s\t%s\n' "$f" "$FPATH_DIR/${f##*/}"
  done
  return 0
}

ours() { [[ "$1" == "$SRC" || "$1" == "$SRC"/* ]]; }

# Another copy of the fleet: a tool whose checkout has the kit beside it.
foreign() {
  local t="$1" root
  root="$(dirname "$(dirname "$t")")"
  [[ -f "$root/lib/sckit.sh" || -f "$(dirname "$t")/lib/sckit.sh" ]]
}

# --- check ------------------------------------------------------------------
check() {
  local gaps=0 src dest cur want
  while IFS=$'\t' read -r src dest; do
    if [[ ! -e "$dest" && ! -L "$dest" ]]; then
      echo "MISSING   $dest -> $src"; gaps=$((gaps+1))
    elif [[ -L "$dest" ]]; then
      cur="$(readlink -f "$dest" 2>/dev/null || true)"
      want="$(readlink -f "$src")"
      [[ "$cur" == "$want" ]] && continue
      if [[ -n "$cur" ]] && ! ours "$cur" && foreign "$cur"; then
        echo "FOREIGN   $dest -> $cur (another fleet copy; want $src)"
      else
        echo "WRONG     $dest -> ${cur:-<broken>} (want $src)"
      fi
      gaps=$((gaps+1))
    else
      echo "NOTLINK   $dest is a real file, not a symlink (want $src)"; gaps=$((gaps+1))
    fi
  done < <(manifest)

  local want_list dir tgt
  want_list="$(manifest | cut -f2)"
  for dir in "$BIN_DIR" "$MAN_DIR" "$FPATH_DIR"; do
    [[ -d "$dir" ]] || continue
    for dest in "$dir"/* "$dir"/.[!.]*; do
      [[ -L "$dest" ]] || continue
      tgt="$(readlink -f "$dest" 2>/dev/null || true)"
      ours "$tgt" || continue
      grep -qxF -- "$dest" <<<"$want_list" && continue
      echo "ORPHAN    $dest -> $tgt (not in the manifest)"; gaps=$((gaps+1))
    done
  done

  if [[ $gaps -eq 0 ]]; then
    echo "install: clean"
    return 0
  fi
  echo "install: $gaps gap(s) — run install.sh"
  return 1
}

# --- apply ------------------------------------------------------------------
link() {
  local src="$1" dest="$2"
  if [[ -L "$dest" && "$(readlink -f "$dest" 2>/dev/null)" == "$(readlink -f "$src")" ]]; then
    return 0
  fi
  if [[ -L "$dest" ]]; then
    rm "$dest"
  elif [[ -e "$dest" ]]; then
    local bak; bak="$dest.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$dest" "$bak"
    echo "Backed up: $dest -> $bak"
  fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
  echo "Linked: ${dest/#$HOME/\~} -> $src"
}

apply() {
  local src dest
  while IFS=$'\t' read -r src dest; do link "$src" "$dest"; done < <(manifest)
  cat <<EOF

sc-fleet is linked from $SRC.
Shell surface, once, in .zshrc after compinit:
  [[ -r ${HOME_LINK/#$HOME/\~}/shell/fleet.zsh ]] && . ${HOME_LINK/#$HOME/\~}/shell/fleet.zsh
Then \`arm\` re-arms a running shell. Site facts go in ~/.config/sc-fleet/config
(see docs/configuration.md); \`sc config\` shows what is in effect.
EOF
}

# --- uninstall --------------------------------------------------------------
uninstall() {
  local dir dest tgt n=0
  for dir in "$BIN_DIR" "$MAN_DIR" "$FPATH_DIR"; do
    [[ -d "$dir" ]] || continue
    for dest in "$dir"/* "$dir"/.[!.]*; do
      [[ -L "$dest" ]] || continue
      tgt="$(readlink -f "$dest" 2>/dev/null || true)"
      ours "$tgt" || continue
      rm "$dest"; echo "Removed: ${dest/#$HOME/\~}"; n=$((n+1))
    done
  done
  if [[ -L "$HOME_LINK" && "$(readlink -f "$HOME_LINK")" == "$SRC" ]]; then
    rm "$HOME_LINK"; echo "Removed: ${HOME_LINK/#$HOME/\~}"; n=$((n+1))
  fi
  echo "install: $n link(s) removed; config and rc files untouched"
}

case "$MODE" in
  check) check ;;
  apply) apply ;;
  uninstall) uninstall ;;
esac
