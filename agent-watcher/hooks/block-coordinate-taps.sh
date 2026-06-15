#!/usr/bin/env bash
# PreToolUse hook (matchers: Bash + Write|Edit + mcp__maestro__run). Blocks
# maestro coordinate taps (tapOn/longPressOn by point:) in orchestrated agent
# sessions, per build-and-test's testids-over-coordinates rule: a missing
# selector means ADD a testID (JS-only, Metro reload) and drive by id, not
# grind coordinates. Deterministic counterpart to the prose rule, which a run
# read and still ignored (2026-06-12, coordinate-guessing on the send flow).
#
# Vectors covered (one script, switched on tool_name):
#   - Write/Edit of a maestro flow (.yaml/.yml content with tapOn + point:)
#   - mcp__maestro__run with inline yaml containing tapOn + point:
#   - Bash heredocs authoring yaml with tapOn + point:
# Swipes with start:/end: coordinates are NOT blocked (the confirm-slider
# fallback for uneditable native bounds is sanctioned).
#
# Escape hatch: /tmp/agent-coordtap-<gid>.md — written by the agent, stating
# WHY a testID is impossible for this element (system dialog, native picker,
# third-party view that does not forward testID). Audited by /eval-run; an
# unjustified note is a finding.
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ -n "$TOOL" ] || exit 0

case "$TOOL" in
  Write|Edit)
    PAYLOAD=$(printf '%s' "$INPUT" | jq -r '(.tool_input.file_path // "") + "\n" + (.tool_input.content // .tool_input.new_string // "")' 2>/dev/null || true)
    printf '%s' "$PAYLOAD" | head -1 | grep -qE '\.ya?ml$' || exit 0
    ;;
  mcp__maestro__run)
    PAYLOAD=$(printf '%s' "$INPUT" | jq -r '.tool_input | tostring' 2>/dev/null || true)
    ;;
  Bash)
    PAYLOAD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    ;;
  *) exit 0 ;;
esac

printf '%s' "$PAYLOAD" | grep -qE 'tapOn|longPressOn' || exit 0
printf '%s' "$PAYLOAD" | grep -q 'point:' || exit 0

if [ -s "/tmp/agent-coordtap-$AGENT_TASK_GID.md" ]; then
  exit 0
fi

echo "BLOCKED: coordinate tap (tapOn/longPressOn by point:) for task $AGENT_TASK_GID. Per build-and-test testids-over-coordinates: a missing selector means ADD a testID prop to the component in the gui worktree (JS-only; Metro reload picks it up in seconds) and drive by id, then commit the testID additions as a separate 'test: add missing testIDs for maestro selectors' commit. Coordinate taps are allowed ONLY for surfaces you cannot edit (system dialogs, native pickers, third-party views that do not forward testID): write the specific justification to /tmp/agent-coordtap-$AGENT_TASK_GID.md and retry — the note is audited by /eval-run. Coordinate-anchored swipes (start:/end:) are not affected." >&2
exit 2
