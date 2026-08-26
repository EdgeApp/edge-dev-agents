#!/usr/bin/env bash
# mark-skill-read.sh — PostToolUse hook (matcher: Read|Bash|Skill). Records
# which SKILL.mds entered this run's context, as markers the companion
# read-gate (require-skill-read-for-scripts.sh) checks before letting a
# skill's script execute. Three sources count as a read:
#   Read tool  — file_path is a skills/<name>/SKILL.md
#   Bash       — the command references a skills/<name>/SKILL.md (cat/sed/grep;
#                generous on purpose: partial reads still beat none, and the
#                gate is a nudge toward reading, not a comprehension check)
#   Skill tool — the invocation injects the body wholesale
# inject-run-context.sh pre-writes markers for the bodies it injects at
# session start (asana-plan, task-review).
#
# Markers: /tmp/agent-skill-read-<gid>-<skill>. Scope: no-ops unless
# AGENT_TASK_GID is set. Always exit 0 (PostToolUse; never blocks).
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

mark() { touch "/tmp/agent-skill-read-$AGENT_TASK_GID-$1" 2>/dev/null || true; }

case "$TOOL" in
  Read)
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    if printf '%s' "$FP" | grep -qE 'skills/[a-z0-9-]+/SKILL\.md$'; then
      mark "$(printf '%s' "$FP" | sed -E 's|.*skills/([a-z0-9-]+)/SKILL\.md$|\1|')"
    fi
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    for sk in $(printf '%s' "$CMD" | grep -oE 'skills/[a-z0-9-]+/SKILL\.md' | sed -E 's|skills/([a-z0-9-]+)/SKILL\.md|\1|' | sort -u); do
      mark "$sk"
    done
    ;;
  Skill)
    SK=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null || true)
    SK="${SK##*:}"   # strip plugin/scope prefixes
    [ -n "$SK" ] && mark "$SK"
    ;;
esac
exit 0
