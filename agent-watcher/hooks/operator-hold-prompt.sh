#!/usr/bin/env bash
# operator-hold-prompt.sh -- UserPromptSubmit hook. In an orchestrated session a
# prompt a HUMAN types sets an operator hold (operator-hold.sh) and prints one
# context line telling the agent to answer and wait. A prompt whose FIRST WORD
# is a release word clears the hold instead; the rest of that message is
# instructions to carry out. Machine prompts touch nothing.
#
# ONE RULE: after a leading ok / okay / yes / sure / please, the first word is
#   go | resume | continue | proceed
# and that is the whole grammar. "go, looks good" releases; "looks good, go
# ahead" holds (answer it; the operator writes "go" when they mean go). No
# sentence splitting, no acknowledgement list, no expiry: a held run waits.
#
# MACHINE PROMPTS ARE NOT STEERING. The harness delivers background-task
# completions, file-changed notices, command envelopes and reminder blocks
# through this same hook. A prompt that is nothing but such envelopes and
# notices stamps nothing; an envelope this list does not know degrades to a
# spurious hold (visible, answerable) rather than a missed one.
#
# Fail-open: never blocks a prompt. Scope: no-op unless AGENT_TASK_GID is set
# and the session is an in-flight run (orch-run-context.sh), so a chat in a
# retired done-asana-* pane never stamps the task's gid.
set -uo pipefail
[ -n "${AGENT_TASK_GID:-}" ] || exit 0
GID="$AGENT_TASK_GID"
H="$HOME/.config/agent-watcher"
if [ -x "$H/orch-run-context.sh" ] && ! "$H/orch-run-context.sh" >/dev/null 2>&1; then exit 0; fi

PROMPT=$(jq -r '.prompt // empty' 2>/dev/null || true)
[ -n "$PROMPT" ] || exit 0
case "$PROMPT" in
  '<watchdog-revive-ping>'*|'/one-shot'*) exit 0 ;;
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

# First word after a leading acknowledgement; punctuation around it ignored.
FIRST=$(printf '%s' "$HUMAN" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
  | sed -E 's/^ +//; s/^(ok|okay|k|yes|yep|yeah|sure|please)[[:punct:] ]+//' \
  | grep -oE '^[a-z/]+' || true)
case "$FIRST" in
  go|resume|continue|proceed|/resume)
    "$H/operator-hold.sh" release "$GID"
    echo "[operator hold released] The run is autonomous again: resume the phase you were in. Everything after the release word in this message is steering to carry out."
    exit 0 ;;
esac

"$H/operator-hold.sh" set "$GID"
echo "[operator hold] A human is steering this session. Answer this prompt, then END YOUR TURN and wait: do not advance agent_status, push, open or land a PR, or start the next phase until a message from the operator starts with go, resume, continue or proceed. Reading, investigating and local edits are fine. A Stop hook block will NOT fire while the hold is active; do not read its absence as license to continue."
exit 0
