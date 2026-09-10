#!/usr/bin/env bash
# operator-hold.sh -- the single oracle for an OPERATOR HOLD on an orchestrated
# session: a human typed into the session and is steering it, so the run must
# answer and wait instead of being pushed onward by the autonomy machinery.
#
# A hold is one fact: the stamp file /tmp/agent-operator-hold-<gid> exists.
# No TTL, no owner. A steered run waits for the operator for as long as it
# takes; the watchdog's park escalation is the reminder that one is waiting.
# The stamp is cleared by the operator's release word (hooks/operator-hold-
# prompt.sh), by setting the task back to Pending (asana-watcher.js) and at
# every spawn or resume of the task's session (spawn-test-session.sh), so a
# hold never outlives the conversation it was set in.
#
# A hold is distinct from Asana blocked=Yes, which is a blocked COMPLETION
# (resources shed, task retired, justification judged): a hold keeps the slot,
# sim and Metro and needs no justification.
#
# Consumers (all read `status`; none re-implement the file check):
#   hooks/operator-hold-prompt.sh      UserPromptSubmit: sets on a human prompt,
#                                      releases on a leading release word
#   hooks/require-continuation-or-block.sh  Stop: allows the stop while held
#   hooks/operator-hold-gate.sh        PreToolUse(Bash): blocks phase advances,
#                                      pushes and PR/landing actions while held
#   hooks/require-concession-validation.sh  a --blocked yes while held is
#                                      operator-directed, not a concession
#   session-watchdog.js                a held session is never revived
#
# Usage:
#   operator-hold.sh set <gid>         create the stamp (idempotent)
#   operator-hold.sh release <gid>     remove the stamp
#   operator-hold.sh status <gid>      exit 0 + "held <age>s" when the stamp
#                                      exists, exit 1 + "clear" otherwise
set -uo pipefail
cmd="${1:-}"; gid="${2:-}"
[ -n "$cmd" ] && [ -n "$gid" ] || { echo "usage: operator-hold.sh set|release|status <gid>" >&2; exit 2; }
stamp="/tmp/agent-operator-hold-$gid"
case "$cmd" in
  set) : > "$stamp" 2>/dev/null; exit 0 ;;
  release) rm -f "$stamp" 2>/dev/null; exit 0 ;;
  status)
    [ -f "$stamp" ] || { echo clear; exit 1; }
    ts=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null || echo 0)
    echo "held $(( $(date +%s) - ts ))s"; exit 0 ;;
  *) echo "usage: operator-hold.sh set|release|status <gid>" >&2; exit 2 ;;
esac
