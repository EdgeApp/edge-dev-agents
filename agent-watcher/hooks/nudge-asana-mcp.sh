#!/usr/bin/env bash
# nudge-asana-mcp.sh — PreToolUse hook for Asana MCP tools.
#
# Steers agents away from unscoped Asana MCP reads, which return oversized
# payloads that blow the tool-result token cap. Denies only the unscoped
# shapes, with a reason pointing at the local ~/.cursor/skills scripts or
# the scoped re-call (opt_fields / include_comments:false / limit). Write
# tools pass through untouched.
#
# A SCOPED enumeration still passes, but carries a pointer: scoping bounds the
# payload, it does not make a hand-rolled task->PR walk correct. Enumerating
# tasks and regexing subtask names misses PRs that are linked as attachments,
# which is what pr-land-discover.sh already walks. The pointer rides on the
# call that starts such a walk, since that is the moment the wrong path is
# chosen.
#
# Registered in ~/.claude/settings.json under PreToolUse with a
# server-id-agnostic matcher (mcp__.*__<tool>), so it works across machines
# and connector reinstalls. No AGENT_TASK_GID guard: this protects
# interactive sessions too, not just orchestrated runs.
set -euo pipefail

payload="$(cat)"

tool=$(jq -r '.tool_name // ""' <<<"$payload")
short="${tool##*__}"

advise() {
  jq -n --arg ctx "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
  exit 0
}

deny() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

case "$short" in
  get_task)
    opt_fields=$(jq -r '.tool_input.opt_fields // ""' <<<"$payload")
    # NB: jq's // treats false as absent, so test the boolean explicitly.
    include_comments=$(jq -r '.tool_input.include_comments | if . == false then "false" else "true" end' <<<"$payload")
    if [[ -z "$opt_fields" && "$include_comments" != "false" ]]; then
      deny "Unscoped Asana get_task returns oversized payloads that exceed the tool-result token cap. Prefer ~/.cursor/skills/asana-get-context.sh <task_gid_or_url> — it returns a compact summary (fields, comments, relationships) and downloads/converts attachments (PDF/RTF/ZIP/images) to /tmp/asana-task-<gid>/. If the MCP tool is genuinely needed, re-call with opt_fields naming only the fields you need and include_comments: false (fetch comments separately with a small comment_limit)."
    fi
    ;;
  get_tasks|get_task_stories|search_tasks|search_tasks_preview|search_objects|get_my_tasks)
    limit=$(jq -r '.tool_input.limit // ""' <<<"$payload")
    opt_fields=$(jq -r '.tool_input.opt_fields // ""' <<<"$payload")
    if [[ -z "$limit" && -z "$opt_fields" ]]; then
      deny "Unbounded Asana $short call risks an oversized result. First check ~/.cursor/skills/ for a script that already covers this (asana-get-context.sh, asana-task-update/, asana-task-create/, asana-field-value.sh, asana-build-field.sh). To go from tasks to their PRs, use pr-land/scripts/pr-land-discover.sh — never a hand-rolled walk. If the MCP tool is the right fit, re-call with limit and opt_fields to keep the result small."
    fi
    advise "Scoped $short is fine for reading tasks. If this is the start of finding WHICH PRs exist (or their approval state), stop and use ~/.cursor/skills/pr-land/scripts/pr-land-discover.sh instead: it walks each task's attachments AND subtasks, so it finds PRs that a regex over subtask names alone misses, and it reports approval state. For one run's full evidence surface including its PRs, use ~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid <gid>."
    ;;
esac

# Everything else: allow (no output = fall through to normal permission flow).
exit 0
