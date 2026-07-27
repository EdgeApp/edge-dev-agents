#!/usr/bin/env bash
# mark-agent-authored-asana.sh — PreToolUse(mcp__claude_ai_Asana__*).
# REWRITES agent-authored Asana prose to carry the orch's authorship markers
# (🥋 first line, 👊 last line) instead of blocking, so the write proceeds with
# no bounce. The MCP tools are the path agents actually use for comments, so a
# script-only helper would miss nearly every comment the fleet posts.
#
# Covered fields: comment text (`text`/`html_text`) and task prose
# (`notes`/`html_notes`) on create/update/comment tools. Everything else (field
# updates, searches, reads) passes through untouched.
#
# Idempotent: already-marked text is left alone (same check as
# agent-authored-text.sh, which scripts use for the non-MCP write path).
set -euo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in
  mcp__claude_ai_Asana__add_comment|mcp__claude_ai_Asana__create_task*|mcp__claude_ai_Asana__create_tasks|mcp__claude_ai_Asana__update_tasks|mcp__claude_ai_Asana__save_task_changes_confirm) ;;
  *) exit 0 ;;
esac

# Rewrite every present prose field; jq walks only the ones that exist.
UPDATED=$(printf '%s' "$INPUT" | jq -c '
  def marked: (. // "") | (
    (split("\n") | map(select(test("^\\s*$") | not))) as $ne
    | ($ne[0] // "" | gsub("\\s"; "")) == "🥋" and ($ne[-1] // "" | gsub("\\s"; "")) == "👊"
  );
  def mark: if (. == null or . == "" or marked) then . else "🥋\n" + . + "\n👊" end;
  .tool_input
  | (.text?          |= mark)
  | (.html_text?     |= mark)
  | (.notes?         |= mark)
  | (.html_notes?    |= mark)
  | (.comment?       |= mark)
' 2>/dev/null || true)

[ -n "$UPDATED" ] || exit 0
ORIG=$(printf '%s' "$INPUT" | jq -c '.tool_input' 2>/dev/null || true)
[ "$UPDATED" = "$ORIG" ] && exit 0

jq -nc --argjson ui "$UPDATED" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "marked agent-authored Asana text with 🥋 / 👊",
    updatedInput: $ui
  }
}'
exit 0
