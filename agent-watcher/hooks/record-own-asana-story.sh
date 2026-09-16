#!/usr/bin/env bash
# record-own-asana-story.sh: PostToolUse(mcp__claude_ai_Asana__add_comment).
# Appends the story gid of a comment an in-flight orch run posted on its OWN
# task to /tmp/agent-own-stories-<gid> (one gid per line).
#
# Why: the agent and the operator post as the same Asana user, so the Complete
# gate (require-followup-scope-on-complete.sh) cannot tell "a comment landed
# after your scope check" apart from "you just posted your own completion
# comment". This file is that distinction: the gate ignores these gids when it
# compares the live newest comment against its marker. The script write path
# (asana-task-update.sh --comment-file) appends to the same file.
#
# Only orch-authored comments count (orch-run-context.sh, the same predicate
# the authorship markers use): a retired or chat session that keeps
# AGENT_TASK_GID writes operator instruction, which must stay visible as scope.
# Comments on any task other than AGENT_TASK_GID are not recorded.
#
# Scope: no-op unless AGENT_TASK_GID is set. Never blocks (always exit 0).
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
INPUT=$(cat)
"$HOME/.config/agent-watcher/orch-run-context.sh" || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in
  mcp__claude_ai_Asana__add_comment) ;;
  *) exit 0 ;;
esac

TASK=$(printf '%s' "$INPUT" | jq -r '.tool_input.task_id // .tool_input.task_gid // empty' 2>/dev/null)
[ "$TASK" = "$AGENT_TASK_GID" ] || exit 0

# tool_response shapes seen for MCP tools: the JSON object itself, a JSON
# string, or an array of {type:"text", text:"<json>"} content blocks.
STORY=$(printf '%s' "$INPUT" | jq -r '
  def parse: if type == "string" then (try fromjson catch null) else . end;
  (.tool_response // null)
  | if type == "array" then (map(select(type == "object") | .text // empty) | join("")) else . end
  | parse
  | if type == "object" then (.data.gid // .gid // .structuredContent.data.gid // (.content // [] | map(.text // empty) | join("") | parse | .data.gid?) // empty) else empty end
' 2>/dev/null)

case "$STORY" in
  ''|*[!0-9]*) exit 0 ;;
esac
printf '%s\n' "$STORY" >> "/tmp/agent-own-stories-$AGENT_TASK_GID"
exit 0
