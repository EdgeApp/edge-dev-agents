#!/usr/bin/env bash
# operator-hold-prompt.sh -- UserPromptSubmit hook. In an orchestrated session a
# prompt a HUMAN types sets an operator hold (operator-hold.sh) and prints one
# context line telling the agent to answer and wait; a release clears it and
# says so; a stop order keeps it and tells the agent to take the operator-
# directed block now. Machine prompts and headless children touch nothing.
#
# Grammar (hooks/lib/operator-directives.sh owns the sentence rules):
#   release  the first word (after ok/yes/sure/please) is go|resume|continue|
#            proceed, or the last bare clause (after the final , ; . ! ? and/then)
#            is go|go ahead|resume|continue|proceed|complete|finish up|wrap it up,
#            or a COMPLETION directive opens or closes the message
#            ("finish up", "set it to complete", "ship it")
#   stop     a STOP directive opens or closes the message ("stop the task",
#            "set it to blocked"); the hold stays, the agent is told to block
#   hold     anything else a human typed, including negated or conditional
#            directives ("don't finish yet", "finish once QA signs off") and a
#            bare "stop" (an interrupt, not an order)
# A completion or stop directive, or an explicit "bypass the judge", also writes
# /tmp/agent-judge-waiver-<gid>: the completion judge is not consulted for the
# rest of the segment (require-completion-judgment.sh; spawn clears it).
#
# Not steering: harness envelopes and notices (background-task completions,
# file-changed notes, command echoes) are stripped before the text is read, and
# a prompt that is nothing else stamps nothing. Headless `claude -p` children
# spawned by scripts inside the run inherit AGENT_TASK_GID and fire this hook on
# their own payload; hooks/lib/headless-child.sh exits them early. The watchdog's
# <operator-hold-expired> resume prompt (operator_hold_ttl_min) is machine text too.
#
# Fail-open: never blocks a prompt. Scope: no-op unless AGENT_TASK_GID is set
# and the session is an in-flight run (orch-run-context.sh), so a chat in a
# retired done-asana-* pane never stamps the task's gid.
set -uo pipefail
[ -n "${AGENT_TASK_GID:-}" ] || exit 0
GID="$AGENT_TASK_GID"
H="$HOME/.config/agent-watcher"
. "$H/hooks/lib/headless-child.sh" 2>/dev/null && headless_child && exit 0
if [ -x "$H/orch-run-context.sh" ] && ! "$H/orch-run-context.sh" >/dev/null 2>&1; then exit 0; fi

PROMPT=$(jq -r '.prompt // empty' 2>/dev/null || true)
[ -n "$PROMPT" ] || exit 0
case "$PROMPT" in
  '<watchdog-revive-ping>'*|'<operator-hold-expired>'*|'/one-shot'*) exit 0 ;;
esac

# Strip harness envelopes and machine notices; what survives is human text.
HUMAN=$(printf '%s' "$PROMPT" | node -e '
const tags = ["system-reminder", "task-notification", "local-command-stdout", "local-command-stderr",
  "command-name", "command-message", "command-args", "user-prompt-submit-hook", "session-start-hook", "function_results"]
let t = require("fs").readFileSync(0, "utf8")
for (const tag of tags) {
  t = t.replace(new RegExp(`<${tag}\\b[^]*?</${tag}>`, "g"), "").replace(new RegExp(`</?${tag}\\b[^>]*>`, "g"), "")
}
const notice = /^\s*(\[SYSTEM NOTIFICATION|This is an automated|Do NOT interpret this|No human input has been received|Note: .*changed on disk|Background command .* completed|<task-id>|<tool-use-id>|<output-file>|<status>|<summary>)/
process.stdout.write(t.split("\n").filter(l => !notice.test(l)).join("\n"))
' 2>/dev/null || printf '%s' "$PROMPT")
printf '%s' "$HUMAN" | tr -d '[:space:]' | grep -q . || exit 0

NORM=$(printf '%s' "$HUMAN" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//')
. "$H/hooks/lib/operator-directives.sh"
ANCHOR=$(printf '%s' "$NORM" | release_anchor)
KINDS=$(printf '%s' "$NORM" | directive_kinds)
RELEASE=false; STOP=false; COMPLETE_DIRECTIVE=false; BYPASS=false
case "$ANCHOR" in release*) RELEASE=true ;; esac
case "$ANCHOR" in "release complete") COMPLETE_DIRECTIVE=true ;; esac
case " $KINDS " in *" complete "*) RELEASE=true; COMPLETE_DIRECTIVE=true ;; esac
case " $KINDS " in *" stop "*) STOP=true ;; esac
case " $KINDS " in *" bypass "*) BYPASS=true ;; esac
write_waiver() { printf 'operator-directed %s (%s): %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$PROMPT" | head -c 300 | tr '\n' ' ')" > "/tmp/agent-judge-waiver-$GID" 2>/dev/null || true; }
if $BYPASS; then write_waiver bypass; fi
if $STOP; then
  write_waiver stop
  "$H/operator-hold.sh" set "$GID"
  echo "[operator hold: stop directive] The operator asked you to STOP this run. Do it now, in this turn: update-status.sh $GID <current status> --blocked yes --reason \"operator-directed: <their words>\" (this passes every gate while the hold is active), write and attach the run report describing where things stand, then end your turn. Do not resume the phase, push, or open a PR."
  exit 0
fi
if $RELEASE; then
  $COMPLETE_DIRECTIVE && write_waiver complete
  "$H/operator-hold.sh" release "$GID"
  echo "[operator hold released] The run is autonomous again: resume the phase you were in. The rest of this message is steering to carry out; a completion directive (complete / finish / ship) means finalize through the normal gates now."
  exit 0
fi

"$H/operator-hold.sh" set "$GID"
echo "[operator hold] A human is steering this session. Answer this prompt, then END YOUR TURN and wait: do not advance agent_status, push, open or land a PR, or start the next phase until a message from the operator starts with go, resume, continue or proceed, or ends with one of those (or "complete") as its own clause (e.g. "... and resume", "..., complete."). Reading, investigating and local edits are fine. If the operator asks you to STOP or BLOCK the task, a `--blocked yes --reason "operator-directed: <their words>"` write passes the gates while held. A Stop hook block will NOT fire while the hold is active; do not read its absence as license to continue."
exit 0
