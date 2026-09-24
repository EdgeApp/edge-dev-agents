#!/usr/bin/env bash
# jev-shadow.sh -- shell side of lib/jev-shadow.py (Jev Phase 2 shadow mode).
# Source it, then:
#
#   printf '%s' "$json" | jev_shadow_enqueue <path>
#       Spool one scrubbed row for the drain (launchd com.jontz.jev-shadow).
#       Detached, output dropped, returns 0 at once: a caller's exit code and
#       latency never change.
#   jev_shadow_cmd_trap <hook> <thing> <raw-trigger-ERE> "$CMD"
#       Command-safety hooks, called right after CMD is read. When the RAW
#       command matches the trigger (quoted mentions included), an EXIT trap
#       logs "does this command execute <thing> or only quote it" beside the
#       hook's own decision: exit 2 = block, anything else = allow. The trap
#       never calls exit, so the hook's status is untouched.
#
# Everything is a no-op unless AGENT_TASK_GID is set (orchestrated sessions
# only) and ~/.config/jev/shadow/OFF is absent. Nothing here ever blocks.

JEV_SHADOW_PY="$HOME/.config/agent-watcher/lib/jev-shadow.py"

jev_shadow_enqueue() {
  local path="$1" payload
  payload=$(cat)
  [ -n "${AGENT_TASK_GID:-}" ] || return 0
  [ -f "${JEV_SHADOW_ROOT:-$HOME/.config/jev/shadow}/OFF" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  ( printf '%s' "$payload" | python3 "$JEV_SHADOW_PY" enqueue "$path" >/dev/null 2>&1 & ) >/dev/null 2>&1
  return 0
}

_jev_shadow_cmd_exit() {
  local live=allow
  [ "$1" = 2 ] && live=block
  command -v jq >/dev/null 2>&1 || return 0
  jq -cn --arg hook "$_JEV_HOOK" --arg x "$_JEV_THING" --arg live "$live" --arg cmd "$_JEV_CMD" \
    --arg task "$AGENT_TASK_GID" '{hook:$hook,x:$x,live:$live,cmd:$cmd,task:$task}' 2>/dev/null \
    | jev_shadow_enqueue command
  return 0
}

jev_shadow_cmd_trap() {
  [ -n "${AGENT_TASK_GID:-}" ] || return 0
  printf '%s' "$4" | grep -qE "$3" 2>/dev/null || return 0
  _JEV_HOOK="$1" _JEV_THING="$2" _JEV_CMD="$4"
  trap '_jev_shadow_cmd_exit $?' EXIT
  return 0
}
