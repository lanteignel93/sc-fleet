# fleet.zsh — the spacecowboy fleet's shell surface, in one sourceable file.
#
# Sourced once at startup from .zshrc, and again on demand by `arm` when a
# shell is running yesterday's kit. It must therefore be IDEMPOTENT: every
# construct here survives being sourced any number of times in one shell.
#
# Two rules that keep that true:
#   - fpath is filtered before it is extended, never appended blindly.
#   - PATH is never touched. ~/.local/bin is .profile's job, and an
#     unguarded append here would grow the variable on every re-arm.
#
# Why this file exists at all: a tool's shell function and its completion
# have to travel with the tool. When they lived inline in .zshrc, `sc` and
# its completion shipped to one box and stranded there (2026-09-21), and
# re-arming a live shell meant `exec zsh` or re-sourcing an oh-my-zsh rc
# with a powerlevel10k instant-prompt block — which is not safe twice.
# It ships in the same checkout as the tools, so a new fleet member arrives
# complete.
#
# Sourced AFTER compinit: compdef needs the completion system already up.

# This file's own path, so `arm` can re-source exactly what is running.
# %x is the file being sourced; :A resolves it through the symlink.
FLEET_ZSH="${${(%):-%x}:A}"

# --- completions ------------------------------------------------------------
# The dir holds symlinks to the checkout's completions/_*, planted by install.sh.
() {
    local d="${ZDOTDIR:-$HOME}/.zsh_functions"
    [[ -d "$d" ]] || return 0
    fpath=("$d" "${(@)fpath:#$d}")
    local f name
    for f in "$d"/_*(N); do
        name="${f:t}"
        autoload -Uz -- "$name"
        # compdef exists only once compinit has run; skip quietly if not.
        (( $+functions[compdef] )) && compdef -- "$name" "${name#_}" 2>/dev/null
    done
    return 0
}

# --- wt ---------------------------------------------------------------------
# One worktree per topic across projects (bin/wt; layout in
# docs/wt-layout.md). A script cannot cd its parent shell, so
# `wt cd <query>` is the one subcommand handled here: `wt path` prints the
# worktree (fzf when the query is ambiguous).
wt() {
    if [[ "$1" == cd ]]; then
        local d
        d="$(command wt path "${@:2}")" && cd "$d"
    else
        command wt "$@"
    fi
}

# --- sc ---------------------------------------------------------------------
# The fleet dispatcher. `sc <tool> <verb>` execs the tool as a child process,
# which is right for everything except the subcommands a tool can only carry
# out inside this shell: `sc wt cd` printed the path and the wrapper hint,
# because no child can cd its parent. So when the named tool also has a
# shell function here, call that instead — the fleet namespace then behaves
# identically either way.
#
# Bare `sc`, and `sc <tool>` with no verb, open the menu: every verb the
# fleet declares, with its description, in fzf. A pick either runs (flag-only
# verbs) or lands on the prompt to be finished (verbs that need a value —
# <slug>, [-m MSG]); Tab forces the prompt for any entry. The binary decides
# needs-args; the function is what can run a shell function or prefill a
# prompt, which is why the menu lives here and not in the child.
_sc_run() {   # TOOL [ARGS...] — a shell function when one exists, else the binary
    local _bin="${$(whence -p sc):A:h}" _t="$1"; shift
    if [[ "$_t" == sc ]]; then command sc "$@"; return; fi
    if [[ -x "$_bin/$_t" ]] && typeset -f -- "$_t" >/dev/null 2>&1; then
        "$_t" "$@"
    else
        command sc "$_t" "$@"
    fi
}
_sc_pick() {  # [TOOL] — 0 ran or prefilled · 1 cancelled · 2 no menu here (no fzf / no tty)
    local _sel _cmd _need
    _sel="$(command sc __pick "$@")" || return $?
    _cmd="${_sel%%$'\t'*}"; _need="${_sel##*$'\t'}"
    if [[ "$_need" == 1 ]]; then
        print -z -- "$_cmd "
    else
        _sc_run ${=_cmd}
    fi
}
sc() {
    local _bin="${$(whence -p sc):A:h}" _rc
    case "${1:-}" in
        ls|logo|help|-h|--help) command sc "$@"; return ;;
        "")
            _sc_pick; _rc=$?
            (( _rc == 2 )) && command sc
            return $(( _rc == 2 ? 0 : _rc )) ;;
    esac
    if (( $# == 1 )) && [[ -x "$_bin/$1" ]] && grep -qm1 '^# sc-fleet' "$_bin/$1" 2>/dev/null; then
        _sc_pick "$1"; _rc=$?
        (( _rc == 2 )) && command sc "$@"
        return $(( _rc == 2 ? 0 : _rc ))
    fi
    _sc_run "$@"
}

# --- arm --------------------------------------------------------------------
# Bare `arm` re-arms THIS shell, so it has to be a function: the binary runs
# in a child and could not change anything a human would see. This is the
# `wt cd` wall again, and the same answer. Every other verb is the binary's.
arm() {
    if [[ $# -eq 0 ]]; then
        local f="${FLEET_ZSH:-${SC_FLEET_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/sc-fleet}/shell/fleet.zsh}"
        if [[ ! -r "$f" ]]; then
            print -ru2 -- "refuse    no readable fleet.zsh at $f — run install.sh"
            return 1
        fi
        . "$f" && print -r -- "    armed     this shell · ${f/#$HOME/~}"
        return
    fi
    command arm "$@"
}

# The theme bundle's shell surface (prompt colours, fzf, eza, bat, ...): sourcing
# it again after `dye <name>` is what re-themes a live shell. -r guarded, idempotent.
[[ -r ~/.config/theme/current/shell.zsh ]] && . ~/.config/theme/current/shell.zsh

# A marker so `arm ls` and `arm doctor` can tell an armed shell from a stale
# one. Exported on purpose: a child process can then read it too.
zmodload -F zsh/datetime +b:strftime 2>/dev/null
export FLEET_ARMED="${EPOCHSECONDS:-$(date +%s)}"

rehash
