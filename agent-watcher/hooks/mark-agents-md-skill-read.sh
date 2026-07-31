#!/usr/bin/env bash
# mark-agents-md-skill-read.sh — PostToolUse(Skill | Read | Bash).
# Writes the per-session marker require-agents-md-skill.sh checks, when the
# completed tool call actually loaded the `agents-md` skill: a Skill invocation,
# a Read of its SKILL.md, or a Bash command referencing that path (cat/grep
# count — any engagement with the content beats none). Never blocks; exit 0.
set -euo pipefail

INPUT=$(cat)

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$SESSION" ] || SESSION="${AGENT_TASK_GID:-default}"
MARKER="/tmp/agent-agents-md-skill-$SESSION"
[ -f "$MARKER" ] && exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in
  Skill)
    SKILL=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null || true)
    case "$SKILL" in *agents-md) touch "$MARKER" ;; esac
    ;;
  Read)
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    case "$FP" in *skills/agents-md/SKILL.md) touch "$MARKER" ;; esac
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    case "$CMD" in *skills/agents-md*) touch "$MARKER" ;; esac
    ;;
esac
exit 0
