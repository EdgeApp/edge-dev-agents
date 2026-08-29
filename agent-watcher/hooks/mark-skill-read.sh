#!/usr/bin/env bash
# mark-skill-read.sh — PostToolUse hook (matcher: Read|Bash|Skill). Records
# which SKILL.mds FULLY entered this run's context, as markers the companion
# read-gate (require-skill-read-for-scripts.sh) checks before letting a
# skill's script execute. STRICT since 2026-08-28: only provably-complete
# deliveries count, because a partial read that earns the marker also
# suppresses the gate's deny-with-body delivery, recreating the under-read
# hole (the Cacao run credited pr-address from a 150-235 line slice).
#   Read tool  — file_path is a skills/<name>/SKILL.md AND no offset/limit
#   Bash       — `cat` of the SKILL.md in a command with no truncation tool
#                (sed/head/tail/awk) anywhere in it
#   Skill tool — the invocation injects the body wholesale
# Partial reads earn nothing; the gate then denies the first script call and
# delivers the full body itself (writing the marker as it does).
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
    RANGED=$(printf '%s' "$INPUT" | jq -r 'if (.tool_input.offset // null) != null or (.tool_input.limit // null) != null then "yes" else "no" end' 2>/dev/null || echo yes)
    if [ "$RANGED" = "no" ] && printf '%s' "$FP" | grep -qE 'skills/[a-z0-9-]+/SKILL\.md$'; then
      mark "$(printf '%s' "$FP" | sed -E 's|.*skills/([a-z0-9-]+)/SKILL\.md$|\1|')"
    fi
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # Full-read heuristic: a cat of the file counts unless the command also
    # wields a truncation/slicing tool. Coarse on purpose — under-marking is
    # cheap now (the gate backfills with the full body), over-marking is the
    # failure mode this strictness exists to prevent.
    if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|\$\()[[:space:]]*cat[[:space:]][^|;&]*skills/[a-z0-9-]+/SKILL\.md' \
       && ! printf '%s' "$CMD" | grep -qE '\b(sed|head|tail|awk)\b'; then
      for sk in $(printf '%s' "$CMD" | grep -oE 'skills/[a-z0-9-]+/SKILL\.md' | sed -E 's|skills/([a-z0-9-]+)/SKILL\.md|\1|' | sort -u); do
        mark "$sk"
      done
    fi
    ;;
  Skill)
    SK=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null || true)
    SK="${SK##*:}"   # strip plugin/scope prefixes
    [ -n "$SK" ] && mark "$SK"
    ;;
esac
exit 0
