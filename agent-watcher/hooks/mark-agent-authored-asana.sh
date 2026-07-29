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

# ORCH-authored text only. Operator-context sessions (direct chats, always-on
# consoles, chat forks, RETIRED post-completion sessions) write to Asana on the
# operator's behalf: that text is operator instruction, and a later orch run
# must read it as scope, not discount it as another agent's output. The
# in-flight-run test (env var AND live tmux name) lives in orch-run-context.sh;
# the env var alone is wrong because retired sessions keep AGENT_TASK_GID.
"$(dirname "$0")/../orch-run-context.sh" || exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in
  mcp__claude_ai_Asana__add_comment|mcp__claude_ai_Asana__create_task*|mcp__claude_ai_Asana__create_tasks|mcp__claude_ai_Asana__update_tasks|mcp__claude_ai_Asana__save_task_changes_confirm) ;;
  *) exit 0 ;;
esac

# Rewrite every PRESENT prose field, top-level and inside the batch tools'
# `tasks[]` / `subtasks[]` arrays.
#
# Absent keys must stay absent. `.k? |= f` does NOT skip a missing key — it
# materializes it as null (`{"a":1}` through `.b? |= f` yields `{"a":1,"b":null}`),
# and the MCP schema rejects null for these fields, so every call whose caller
# omitted one of them fails validation before it reaches Asana. `has($k)` is the
# only form that leaves a missing key missing.
UPDATED=$(printf '%s' "$INPUT" | jq -c '
  def marked: (. // "") | (
    (split("\n") | map(select(test("^\\s*$") | not))) as $ne
    | (($ne[0] // "") | startswith("🥋")) and (($ne[-1] // "" | gsub("\\s"; "")) == "👊")
  );
  def mark: if (. == null or . == "" or marked) then . else "🥋 " + . + "\n👊" end;
  def markfield($k): if has($k) then .[$k] |= mark else . end;
  def markprose:
      markfield("text")
    | markfield("html_text")
    | markfield("notes")
    | markfield("html_notes")
    | markfield("comment")
    | markfield("description");
  .tool_input
  | markprose
  | (if (.tasks?    | type) == "array" then .tasks    |= map(markprose) else . end)
  | (if (.subtasks? | type) == "array" then .subtasks |= map(markprose) else . end)
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
