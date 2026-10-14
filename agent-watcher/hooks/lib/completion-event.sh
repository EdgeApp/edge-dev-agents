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
#   Reads the commands the line runs (cmd-parse.sh), so a quoted, heredoc or
#   commented mention cannot trigger and a call inside `bash -c` text can.
#   Every update-status.sh call on the line is classified from its own
#   arguments and the strictest result is printed: complete, then block, then
#   pr-create, then status. When <gid> is given, a call for another task is
#   ignored; a call whose task argument is a variable the line does not set
#   is kept. When the line cannot be read, the text match below is used.

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

# One event per update-status.sh or pr-create.sh command on stdin (cmd-parse.sh
# records). --blocked and --reason take the next word as their value, so a
# reason that says Complete is not a status.
_CE_JQ='
  select(.opaque | not)
  | if .name == "pr-create.sh" then "pr-create"
    elif .name == "update-status.sh" then
      .argv[1:] as $a
      | [range(0; $a | length) as $i
          | select(($a[$i] | startswith("--") | not)
                   and ($i == 0 or (($a[$i - 1] == "--blocked" or $a[$i - 1] == "--reason") | not)))
          | $a[$i]] as $pos
      | ([range(0; $a | length) as $i
          | select(($a[$i] == "--blocked" and $a[$i + 1] == "yes") or $a[$i] == "--blocked=yes")] | length > 0) as $blocked
      | if $gid != "" and (($pos | index($gid)) == null) and ((($pos[0] // "") | contains("$")) | not) then empty
        elif $blocked then "block"
        elif ($pos | index("Complete")) != null then "complete"
        else "status" end
    else empty end'

completion_event() {
  local raw="$1" gid="${2:-}" text recs events ev
  if recs=$(printf '%s' "$raw" | "$_CE_HOOKS/cmd-parse.sh" 2>/dev/null); then
    events=$(printf '%s' "$recs" | jq -r --arg gid "$gid" "$_CE_JQ" 2>/dev/null)
    for ev in complete block pr-create status; do
      if printf '%s\n' "$events" | grep -qx "$ev"; then echo "$ev"; return 0; fi
    done
    return 0
  fi
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
