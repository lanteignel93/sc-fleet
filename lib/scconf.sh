# scconf.sh — the fleet's config reader. Source it; it prints nothing and
# changes nothing.
#
#   sc_conf KEY [DEFAULT]   the effective scalar: last value wins, config.local
#                           over config over DEFAULT
#   sc_conf_all KEY         every value of a list key, one per line:
#                           config.local's entries first, then config's
#   sc_conf_home            the config directory
#
# Files: $SC_CONFIG_HOME/{config,config.local}; SC_CONFIG_HOME defaults to
# ${XDG_CONFIG_HOME:-$HOME/.config}/sc-fleet. Env vars a tool already honours
# (WT_ROOT, TK_STORE, ...) still win — callers write ${WT_ROOT:-$(sc_conf ...)}.
#
# Grammar, shared with the roster: `tool.key=value` lines; blank lines and
# `#` lines skipped; a trailing ` # comment` stripped; whitespace around the
# key and value trimmed; split on the first `=`. The file is read, never
# sourced or evaluated: the only expansion is text substitution of `~/` at
# the start of a word, $HOME, ${HOME}, $USER and ${USER}.
#
# Independent of sckit.sh on purpose, so a tool that runs without the kit can
# still read its config. The Python twin is sc_conf() in tasks.py;
# tests/test_conf.sh keeps the two identical.

sc_conf_home() {
  printf '%s' "${SC_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/sc-fleet}"
}

_sc_conf_values() {  # FILE KEY -> the file's values for KEY, in file order
  [[ -r "$1" ]] || return 0
  awk -v k="$2" '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      eq = index(line, "=")
      if (!eq) next
      kk = substr(line, 1, eq - 1); vv = substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", kk)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", vv)
      if (kk == k) print vv
    }' "$1"
}

_sc_conf_expand() {
  local v=" $1" user="${USER:-$(id -un 2>/dev/null)}"
  v="${v// \~\// $HOME/}"
  [[ "$v" == " ~" ]] && v=" $HOME"
  v="${v//\$\{HOME\}/$HOME}"; v="${v//\$HOME/$HOME}"
  v="${v//\$\{USER\}/$user}"; v="${v//\$USER/$user}"
  printf '%s' "${v# }"
}

sc_conf() {
  local key="$1" home v=""
  home="$(sc_conf_home)"
  v="$(_sc_conf_values "$home/config.local" "$key" | tail -n 1)"
  [[ -n "$v" ]] || v="$(_sc_conf_values "$home/config" "$key" | tail -n 1)"
  if [[ -n "$v" ]]; then _sc_conf_expand "$v"; else printf '%s' "${2-}"; fi
}

sc_conf_all() {
  local key="$1" home line
  home="$(sc_conf_home)"
  while IFS= read -r line; do
    [[ -n "$line" ]] && { _sc_conf_expand "$line"; printf '\n'; }
  done < <(_sc_conf_values "$home/config.local" "$key"; _sc_conf_values "$home/config" "$key")
}
