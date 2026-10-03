#!/usr/bin/env bash
# completion-event.sh: the ONE classification of a command into a completion
# event, sourced by every hook that gates one (the completion judge gate, the
# followup-scope gate, the operator-hold gate, the TDD gates and the skill-read
# gate). Before this lib each matched its own pattern, and they disagreed on the
# documented blocked completion `update-status.sh <gid> Complete --blocked yes`:
# the judge read it as a block, the followup-scope gate as a plain Complete.
#
# Events:
#   block      update-status.sh ... --blocked yes   (whatever status rides with it)
#   complete   update-status.sh ... Complete        (no --blocked yes)
#   status     any other update-status.sh call
#   pr-create  pr-create.sh
#   (empty)    none of the above
#
# completion_event_text <mention-stripped text>
#   Classifies by text alone: for callers that already isolated one invocation.
# completion_event <raw command> [<gid>]
#   Strips mentions (quoted, heredoc and backticked spans cannot trigger),
#   requires the script to actually execute (cmd-executes.sh), and when <gid>
#   is given ignores update-status.sh calls for any other task.

_CE_HOOKS="$HOME/.config/agent-watcher/hooks"

completion_event_text() {
  local text="$1" args
  args=$(printf '%s' "$text" | grep -oE 'update-status\.sh([[:space:]][^|;&]*)?' | head -1)
  if [ -n "$args" ]; then
    if printf '%s' "$args" | grep -qE -- '--blocked([[:space:]]+|=)["'"'"']?yes'; then
      echo block
    elif printf '%s' "$args" | grep -qE '[[:space:]]Complete([[:space:]"'"'"']|$)'; then
      echo complete
    else
      echo status
    fi
    return 0
  fi
  printf '%s' "$text" | grep -qE 'pr-create\.sh' && echo pr-create
  return 0
}

completion_event() {
  local raw="$1" gid="${2:-}" text
  text=$(printf '%s' "$raw" | "$_CE_HOOKS/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$raw")
  if printf '%s' "$raw" | "$_CE_HOOKS/cmd-executes.sh" update-status.sh >/dev/null 2>&1; then
    if [ -n "$gid" ]; then
      case "$text" in *"$gid"*) ;; *) return 0 ;; esac
    fi
    completion_event_text "$(printf '%s' "$text" | grep -oE 'update-status\.sh([[:space:]][^|;&]*)?' | head -1)"
    return 0
  fi
  if printf '%s' "$raw" | "$_CE_HOOKS/cmd-executes.sh" pr-create.sh >/dev/null 2>&1; then
    echo pr-create
  fi
  return 0
}
