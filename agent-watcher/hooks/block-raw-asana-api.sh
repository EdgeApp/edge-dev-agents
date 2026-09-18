#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks raw HTTP hits on the Asana API in
# agent sessions — Asana reads and writes go through the sanctioned companion
# scripts, which carry the contracts a raw call silently drops. Founding
# incident (2026-08-24, task 1217796671374968): a run hand-rolled
# `curl .../tasks/<gid>?opt_fields=name,notes,...` two minutes after spawn
# instead of asana-get-context.sh, never fetched attachments or stories, and
# planned past two repro screenshots. The block message is the signpost that
# teaches the sanctioned path at the moment of substitution.
#
# Attachment BINARIES (asanausercontent.com) are not matched — downloading a
# file the script already surfaced is fine.
#
# Scope: EVERY session, orchestrated or chat. A chat session hand-rolling the
# traversal reaches the same wrong answer as a run does, and silently: the
# discovery scripts walk a task's attachments AND subtasks, which a hand-rolled
# regex over subtask names alone misses. Companion scripts are exempt by path.
# Exit 0 allow, exit 2 block.
set -uo pipefail

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. The API URL itself
# legitimately sits INSIDE quotes (a curl argument), so the trigger is: the
# URL anywhere in the raw command AND an actual HTTP-client invocation in the
# stripped view. Fail-open to the raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

echo "$CMD" | grep -q "app.asana.com/api" || exit 0
printf '%s' "$CMD_M" | grep -qE '(^|[;&|([:space:]])(curl|wget|http|xh)([[:space:]]|$)' || exit 0

# Sanctioned scripts (their internal curls are invisible to this hook anyway;
# this exempts mixed commands that both run a script and mention the API).
# Matched by DIRECTORY, not by a name list: every Asana-touching script already
# lives under one of these two roots, and a name list silently stops covering
# the next script added there.
# Companion scripts are exempt by DIRECTORY, but only when one is actually
# INVOKED: cmd-executes.sh owns the command-position test and the reason a
# substring match is not good enough.
printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/cmd-executes.sh" \
  --under /.cursor/skills/ --under /.config/agent-watcher/ && exit 0

echo "BLOCKED: raw Asana API calls are forbidden in every session, chat included — the sanctioned scripts carry contracts a raw curl drops (attachment download, followup-scope watermark arithmetic, authored-text marking, gated status writes). Use instead:
  task ingestion (task+comments+subtasks+ATTACHMENTS): ~/.cursor/skills/asana-get-context.sh <gid>
  single field read: ~/.cursor/skills/asana-field-value.sh <gid> \"<field>\"
  task COMMENT: ~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task <gid> --comment-file <file>
  WHICH PRs EXIST + approval state (walks attachments AND subtasks): ~/.cursor/skills/pr-land/scripts/pr-land-discover.sh
  a run's full evidence surface incl. its PRs: ~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid <gid>
  attachments: asana-task-update.sh --task <gid> --attach-file <path> --attach-name <name> (a same-name run report is replaced)
  subtasks: asana-task-update.sh --task <gid> --create-subtask --subtask-name \"<name>\"
  task DESCRIPTION (agent-maintained tail only): asana-task-update.sh --task <gid> --set-current-state <file>
  followup-scope / watermark: ~/.config/agent-watcher/check-followup-scope.sh --task-gid <gid>
  status transitions: ~/.config/agent-watcher/update-status.sh
Read the owning SKILL.md (task-review, asana-task-update) before using its script." >&2
exit 2
