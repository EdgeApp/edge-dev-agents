#!/usr/bin/env bash
# launchd-env.sh — PATH for scripts that run under launchd (or any context that
# inherits launchd's bare /usr/bin:/bin:/usr/sbin:/sbin). Source it before the
# first tool call:
#   source "$HOME/.config/agent-watcher/lib/launchd-env.sh"
# Adds, in front of whatever PATH exists: the newest nvm node bin (node, npm,
# sfw), ~/.local/bin, Homebrew (Apple Silicon and Intel). Idempotent: a
# directory already on PATH is not added twice. Sourcing this from an
# interactive shell is harmless.
_le_prepend() { case ":$PATH:" in *":$1:"*) ;; *) [[ -d "$1" ]] && PATH="$1:$PATH" ;; esac; }
_le_node=""
for _le_d in "$HOME/.nvm/versions/node"/*/bin; do
  [[ -d "$_le_d" ]] || continue
  if [[ -z "$_le_node" ]] || [[ "$(printf '%s\n%s\n' "${_le_node%/bin}" "${_le_d%/bin}" | sort -V | tail -1)" == "${_le_d%/bin}" ]]; then
    _le_node="$_le_d"
  fi
done
_le_prepend /usr/local/bin
_le_prepend /opt/homebrew/bin
_le_prepend "$HOME/.local/bin"
[[ -n "$_le_node" ]] && _le_prepend "$_le_node"
export PATH
unset -f _le_prepend; unset _le_node _le_d
