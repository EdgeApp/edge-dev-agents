#!/usr/bin/env bash
# mark-skill-read.sh — PostToolUse hook (matcher: Read|Bash|Skill). Records
# which SKILL.mds FULLY entered this run's context, as markers the companion
# read-gate (require-skill-read-for-scripts.sh) checks before letting a
# skill's script execute. STRICT since 2026-08-28: only provably-complete
# deliveries count, because a partial read that earns the marker also
# suppresses the gate's deny-with-body delivery, recreating the under-read
# hole (the Cacao run credited pr-address from a 150-235 line slice).
#   Read tool: each Read of a skills/<name>/SKILL.md adds the lines it showed
#                (checked line by line against the current file) to
#                /tmp/agent-skill-read-<key>-<name>.ranges; the marker is
#                written once every line is covered. One uncapped full Read
#                covers everything; a Read cut at the token cap covers only
#                the lines it returned, so paging finishes the job.
#   Bash: `cat` of the SKILL.md whose output reaches the transcript
#                unaltered: no truncation tool (sed/head/tail/awk) anywhere in
#                the command, no pipe, stdout redirect, or $( ) capture on the
#                cat, output not persisted to a side file, and stdout contains
#                the current body.
#   Skill tool: the invocation injects the body wholesale
# Content checks live in lib/skill-read-evidence.js (post mode). Partial reads
# earn nothing; the gate then scans the transcript for other proof and
# otherwise denies and delivers the full body itself (writing the marker).
# inject-run-context.sh pre-writes markers for the bodies it injects at
# session start (asana-plan, task-review), and expires markers and .ranges
# files together at segment and compaction boundaries.
#
# Markers: /tmp/agent-skill-read-<key>-<skill>. <key> is AGENT_TASK_GID in
# orch runs and sess-<session_id> in interactive sessions, so the file gates
# that cover interactive editing (require-skill-for-file.sh, all-sessions
# entries) can credit a skill loaded ahead of the write. The orch gates only
# ever look up the gid key. Always exit 0 (PostToolUse; never blocks).
set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

KEY="${AGENT_TASK_GID:-}"
if [ -z "$KEY" ]; then
  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  [ -n "$SID" ] || exit 0
  KEY="sess-$SID"
fi

mark() { touch "/tmp/agent-skill-read-$KEY-$1" 2>/dev/null || true; }
EVIDENCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/skill-read-evidence.js"

# post_evidence : marks every skill the content check credits for this payload.
post_evidence() {
  command -v node >/dev/null 2>&1 && [ -f "$EVIDENCE" ] || return 0
  local sk
  for sk in $(printf '%s' "$INPUT" | node "$EVIDENCE" post "$KEY" 2>/dev/null); do
    mark "$sk"
  done
}

case "$TOOL" in
  Read)
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    if printf '%s' "$FP" | grep -qE 'skills/[a-z0-9-]+/SKILL\.md$'; then
      post_evidence
    fi
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # Coarse shape filter first (cheap); the content check decides. Under-
    # marking is cheap (the gate backfills), over-marking is the failure mode.
    if printf '%s' "$CMD" | grep -qE '(^|[;&|(]|\$\()[[:space:]]*cat[[:space:]][^|;&]*skills/[a-z0-9-]+/SKILL\.md' \
       && ! printf '%s' "$CMD" | grep -qE '\b(sed|head|tail|awk)\b'; then
      post_evidence
    fi
    ;;
  Skill)
    SK=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null || true)
    SK="${SK##*:}"   # strip plugin/scope prefixes
    [ -n "$SK" ] && mark "$SK"
    ;;
esac
exit 0
