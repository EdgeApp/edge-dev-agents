#!/usr/bin/env bash
# task-pr-urls.sh: the GitHub PR URLs attached to an Asana task AND to its
# subtasks (multi-repo runs attach each repo's PR to a per-repo subtask, so a
# parent-only read sees no PR for exactly those tasks). One per line, sorted,
# unique. Best-effort: a failed fetch contributes nothing.
#
# task_pr_urls <task_gid> [<attachments_json>]
#   Needs TOKEN (Asana PAT). Pass the parent's attachments response when the
#   caller already fetched it with view_url, to save one call.

task_pr_urls() {
  local gid="$1" att="${2:-}" api="https://app.asana.com/api/1.0" urls subt sgid satt
  local re='github\.com/.+/pull/[0-9]+$'
  urls=$(printf '%s' "$att" | jq -r --arg re "$re" '[.data[]? | .view_url // "" | select(test($re))] | unique | .[]' 2>/dev/null || true)
  if [[ -z "$urls" ]]; then
    att="$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
      "$api/tasks/$gid/attachments?opt_fields=view_url" 2>/dev/null || true)"
    urls=$(printf '%s' "$att" | jq -r --arg re "$re" '[.data[]? | .view_url // "" | select(test($re))] | unique | .[]' 2>/dev/null || true)
  fi
  subt="$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" \
    "$api/tasks/$gid/subtasks?opt_fields=gid" 2>/dev/null || true)"
  for sgid in $(printf '%s' "$subt" | jq -r '.data[]?.gid // empty' 2>/dev/null); do
    satt="$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" \
      "$api/tasks/$sgid/attachments?opt_fields=view_url" 2>/dev/null || true)"
    urls=$(printf '%s\n%s\n' "$urls" "$(printf '%s' "$satt" | jq -r --arg re "$re" '[.data[]? | .view_url // "" | select(test($re))] | .[]' 2>/dev/null || true)")
  done
  printf '%s\n' "$urls" | grep -v '^$' | sort -u || true
}
