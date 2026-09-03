#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks the Planning→Developing status
# transition in agent sessions until the planning artifacts exist and no
# operator ruling is pending:
#
#   1. INGESTION marker /tmp/asana-task-<gid>/.context-fetched — proof
#      asana-get-context.sh ran (task-review step 1; it downloads every task
#      attachment). Added 2026-08-24: task 1217796671374968 hand-rolled a raw
#      curl with notes-only opt_fields, never learned the prescribed script
#      existed, and planned past two repro screenshots. A read-gate on script
#      invocation cannot catch a script that is never invoked; only this
#      boundary-evidence check can.
#   2. PLAN document — deterministic counterpart to asana-plan's
#      `create-plan-required` (the prose-guarded plan contract was met 1/3 in
#      the last cohort; the hook-guarded contracts went 3/3).
#
# Scope: no-ops unless AGENT_TASK_GID is set. Exit 0 allow, exit 2 block.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

case "$CMD_M" in
  *update-status.sh*) ;;
  *) exit 0 ;;
esac
echo "$CMD_M" | grep -q "Developing" || exit 0

# Check 1: ingestion evidence. Checked before the plan check — a plan written
# without ingestion is exactly the failure this catches, so prescribing "write
# the plan" first would order the fix backwards.
if [ ! -f "/tmp/asana-task-$AGENT_TASK_GID/.context-fetched" ]; then
  echo "BLOCKED: no task-ingestion evidence for $AGENT_TASK_GID. Read ~/.cursor/skills/task-review/SKILL.md and run its steps 1-3 BEFORE planning — step 1's asana-get-context.sh fetches the task, comments, subtasks, AND downloads every attachment to /tmp/asana-task-$AGENT_TASK_GID/ (screenshots, specs, and logs attached to the task are requirements; a hand-rolled curl with notes-only opt_fields silently misses them all), and the skill's later steps tell you how to READ each downloaded artifact and fold it into the plan. Running the script bare skips those steps — read the skill first. Revise the plan file if it already exists, then retry this status update." >&2
  exit 2
fi

# Check 2: operator ruling. asana-get-context.sh writes this marker when a
# non-operator human's comment or description edit postdates the operator's
# last word (task-review operator-final-say). Implementation waits for the
# operator; the marker clears itself on the next ingestion after the operator
# comments.
RULING="/tmp/asana-task-$AGENT_TASK_GID/.awaiting-operator-ruling"
if [ -s "$RULING" ]; then
  echo "BLOCKED: task $AGENT_TASK_GID has other-human text the operator has not ruled on (task-review operator-final-say): $(tr '\n' ';' < "$RULING"). The operator has final say before implementation. Do NOT enter Developing. Attach the plan, then post ONE agent comment that lists each open proposal by author with the plan's chosen default for it, so the operator can answer in one line; then take the blocked completion per one-shot yolo-true-blockers (e): ~/.config/agent-watcher/update-status.sh $AGENT_TASK_GID Complete --blocked yes --reason \"awaiting operator ruling: <items>\". An operator comment after that ruling re-arms the task with a clear marker." >&2
  exit 2
fi

if ls /tmp/plan-"$AGENT_TASK_GID"-*.md >/dev/null 2>&1 || \
   ls "$HOME"/git/.agent-worktrees/"$AGENT_TASK_GID"/*/plan-"$AGENT_TASK_GID"-*.md >/dev/null 2>&1; then
  exit 0
fi

echo "BLOCKED: no plan document exists for task $AGENT_TASK_GID. Before entering Developing, write the plan per asana-plan's create-plan-required: /tmp/plan-$AGENT_TASK_GID-<short-slug>.md with all six sections (Summary; Goal/Definition of Done; Likely relevant files; Findings so far; Numbered implementation steps; Constraints), stamped with \$AGENT_SESSION_UUID. Then attach it to the task: ~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task $AGENT_TASK_GID --attach-file <plan-path> --attach-name plan-<short-slug>.md. Then retry this status update." >&2
exit 2
