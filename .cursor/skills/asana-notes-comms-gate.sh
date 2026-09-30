#!/usr/bin/env bash
# asana-notes-comms-gate.sh
# Refuse task-description notes that direct outbound comms (Slack, thread,
# channel, DM, email, reporter/partner) unless the operator authorized them.
#
# A task description is read downstream as authority: the orch agent and the
# completion judge both act on it, so an unrequested "reply in the thread" step
# turns into messages sent under the operator's name. Shared by every writer of
# a task description (asana-task-create.sh, asana-task-update.sh --set-notes).
#
# Usage: asana-notes-comms-gate.sh <notes-file> [<the operator's words authorizing comms>]
# Output: COMMS_AUTHORIZED: <words> on stdout when authorization was passed.
# Exit: 0 = pass, 1 = comms lines found without authorization (lines on stderr), 2 = usage.
set -euo pipefail

NOTES_FILE="${1:-}"
COMMS_AUTH="${2:-}"
[[ -n "$NOTES_FILE" ]] || { echo "usage: asana-notes-comms-gate.sh <notes-file> [<authorization>]" >&2; exit 2; }
[[ -f "$NOTES_FILE" ]] || { echo "ERROR: notes file not found: $NOTES_FILE" >&2; exit 2; }

COMMS_TARGET='(slack|thread|channel|e-?mail|dm|discord|telegram|reporter|partner)'
COMMS_HITS=$(grep -inE \
  "\b(post|reply|respond|message|dm|ping|notify|send|tell|announce|follow[- ]up|ask)\b[^.]{0,60}\b${COMMS_TARGET}\b|\breport\b[^.]{0,40}\b(back|in|to|on)\b[^.]{0,30}\b${COMMS_TARGET}\b|\b(email|e-mail|dm|ping)\s+(the|a|an|them|him|her|back)\b" \
  "$NOTES_FILE" | grep -viE 'thread[- ]?(pool|safe|id|local)|main thread|ui thread|js thread' || true)
if [[ -n "$COMMS_HITS" && -z "$COMMS_AUTH" ]]; then
  echo "ERROR: the notes direct outbound comms, which needs the operator's explicit authorization:" >&2
  printf '%s\n' "$COMMS_HITS" | sed 's/^/  line /' >&2
  echo "Remove those steps, or re-run with --comms-authorized \"<the operator's words>\" if they asked for it." >&2
  exit 1
fi
[[ -n "$COMMS_AUTH" ]] && echo "COMMS_AUTHORIZED: $COMMS_AUTH"
exit 0
