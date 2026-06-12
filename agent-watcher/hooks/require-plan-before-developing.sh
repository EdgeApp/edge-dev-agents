#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks the Planning→Developing status
# transition in agent sessions until the plan document exists. Deterministic
# counterpart to asana-plan's `create-plan-required` (the prose-guarded plan
# contract was met 1/3 in the last cohort; the hook-guarded contracts went 3/3).
#
# Scope: no-ops unless AGENT_TASK_GID is set. Exit 0 allow, exit 2 block.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

case "$CMD" in
  *update-status.sh*) ;;
  *) exit 0 ;;
esac
echo "$CMD" | grep -q "Developing" || exit 0

if ls /tmp/plan-"$AGENT_TASK_GID"-*.md >/dev/null 2>&1 || \
   ls "$HOME"/git/.agent-worktrees/"$AGENT_TASK_GID"/*/plan-"$AGENT_TASK_GID"-*.md >/dev/null 2>&1; then
  exit 0
fi

echo "BLOCKED: no plan document exists for task $AGENT_TASK_GID. Before entering Developing, write the plan per asana-plan's create-plan-required: /tmp/plan-$AGENT_TASK_GID-<short-slug>.md with all six sections (Summary; Goal/Definition of Done; Likely relevant files; Findings so far; Numbered implementation steps; Constraints), stamped with \$AGENT_SESSION_UUID. Then attach it to the task: ~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task $AGENT_TASK_GID --attach-file <plan-path> --attach-name plan-<short-slug>.md. Then retry this status update." >&2
exit 2
