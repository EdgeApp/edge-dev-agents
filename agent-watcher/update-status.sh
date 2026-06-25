#!/usr/bin/env bash
# update-status.sh — Update agent_status (and optionally blocked) on an Asana task.
# As a side effect, also moves the task to the kanban section that matches the new
# status, so a Board view of the project reflects the agent_status in real time.
#
# Usage:
#   update-status.sh <task_gid> <status_name> [--blocked yes|no]
#
# Status names: Pending | Planning | Developing | Reviewing | Testing | Complete
#
# Reads custom field GIDs and section GIDs from ~/.config/agent-watcher/asana-config.json
# and ASANA_TOKEN from credentials.json.
#
# Exit codes:
#   0 = success (custom-field update applied; section move best-effort)
#   1 = Asana API error on the custom-field update
#   2 = usage / missing config error
#
# Escape hatch: the section move is best-effort. If the kanban hasn't been set
# up yet (no section_gids in config) or the move call fails, we warn to stderr
# and still exit 0 — the canonical state is the custom field, not the section.

set -euo pipefail

CONFIG="$HOME/.config/agent-watcher/asana-config.json"
CRED="$HOME/.config/agent-watcher/credentials.json"

[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 2; }
[[ -f "$CRED"   ]] || { echo "Missing $CRED"   >&2; exit 2; }

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") <task_gid> <status_name> [--blocked yes|no] [--reason "<text>"]
  status_name: Pending | Planning | Developing | Reviewing | Testing | Complete
  --reason: REQUIRED with --blocked yes — the claimed blocker, judged by the
            concession-validation gate against the true-blocker taxonomy.
EOF
  exit 2
}

TASK_GID="${1:-}"
STATUS_NAME="${2:-}"
[[ -n "$TASK_GID" && -n "$STATUS_NAME" ]] || usage

BLOCKED=""
REASON=""
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --blocked) BLOCKED="${2:-}"; shift 2 ;;
    --reason)  REASON="${2:-}";  shift 2 ;;
    *) shift ;;
  esac
done
[[ -z "$BLOCKED" || "$BLOCKED" == "yes" || "$BLOCKED" == "no" ]] || usage

# Persist the claimed blocker reason (read by the concession-validation gate + the eval).
# The reason is the justification the concession-validator judges against the
# true-blocker taxonomy; an empty reason on a --blocked yes is itself suspect.
if [[ "$BLOCKED" == "yes" ]]; then
  printf '%s\n' "$REASON" > "/tmp/agent-concession-reason-$TASK_GID.txt" 2>/dev/null || true
elif [[ "$BLOCKED" == "no" ]]; then
  rm -f "/tmp/agent-concession-reason-$TASK_GID.txt" "/tmp/agent-concession-verdict-$TASK_GID.json" 2>/dev/null || true
fi

TOKEN=$(jq -r .asana_token "$CRED")
STATUS_FIELD_GID=$(jq -r .custom_fields.agent_status.gid "$CONFIG")
STATUS_OPT_GID=$(jq -r --arg s "$STATUS_NAME" '.custom_fields.agent_status.options[$s] // empty' "$CONFIG")

if [[ -z "$STATUS_OPT_GID" ]]; then
  echo "Unknown status: $STATUS_NAME" >&2
  echo "Valid: $(jq -r '.custom_fields.agent_status.options | keys | join(", ")' "$CONFIG")" >&2
  exit 2
fi

# Build the custom_fields payload as JSON
CF_JSON=$(jq -n \
  --arg sf "$STATUS_FIELD_GID" \
  --arg so "$STATUS_OPT_GID" \
  '{($sf): $so}')

if [[ -n "$BLOCKED" ]]; then
  BLOCKED_FIELD_GID=$(jq -r .custom_fields.blocked.gid "$CONFIG")
  if [[ "$BLOCKED" == "yes" ]]; then
    BLOCKED_OPT_GID=$(jq -r .custom_fields.blocked.options.Yes "$CONFIG")
  else
    BLOCKED_OPT_GID=$(jq -r .custom_fields.blocked.options.No "$CONFIG")
  fi
  CF_JSON=$(jq -n \
    --argjson base "$CF_JSON" \
    --arg bf "$BLOCKED_FIELD_GID" \
    --arg bo "$BLOCKED_OPT_GID" \
    '$base + {($bf): $bo}')
fi

PAYLOAD=$(jq -n --argjson cf "$CF_JSON" '{data: {custom_fields: $cf}}')

RESPONSE=$(curl -sS \
  -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "https://app.asana.com/api/1.0/tasks/$TASK_GID")

if echo "$RESPONSE" | jq -e .errors >/dev/null 2>&1; then
  echo "Asana API error:" >&2
  echo "$RESPONSE" | jq . >&2
  exit 1
fi

echo "Updated task $TASK_GID: agent_status=$STATUS_NAME${BLOCKED:+, blocked=$BLOCKED}${REASON:+ (reason: $REASON)}"

# Final-state marker for the Stop hook (require-continuation-or-block.sh). Written ONLY
# after the status PUT above SUCCEEDED, so a fresh marker proves the agent JUST reached a
# legit end (Complete/Archived, or blocked=Yes) — the hook allows the turn-end on it
# WITHOUT an Asana read-after-write race. Removed when the task returns to a non-terminal
# active status (a followup reopen) so a later premature stop is still caught. The hook
# only trusts a FRESH marker (the lag window is seconds); an old marker falls through to
# the authoritative Asana read.
FINAL_MARKER="/tmp/agent-final-$TASK_GID"
if [[ "$STATUS_NAME" == "Complete" || "$STATUS_NAME" == "Archived" || "$BLOCKED" == "yes" ]]; then
  : > "$FINAL_MARKER" 2>/dev/null || true
elif [[ "$STATUS_NAME" == "Pending" || "$STATUS_NAME" == "Planning" || "$STATUS_NAME" == "Developing" || "$STATUS_NAME" == "Reviewing" || "$STATUS_NAME" == "Testing" ]]; then
  rm -f "$FINAL_MARKER" 2>/dev/null || true
fi

# Best-effort section move so a Board view of the kanban reflects the status.
SECTION_GID=$(jq -r --arg s "$STATUS_NAME" '.custom_fields.agent_status.section_gids[$s] // empty' "$CONFIG")
if [[ -z "$SECTION_GID" ]]; then
  echo ">> section move: skipped (no section_gids in config — run setup-kanban-sections.sh once)" >&2
else
  MOVE_RESP=$(curl -sS -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$TASK_GID" '{data: {task: $t}}')" \
    "https://app.asana.com/api/1.0/sections/$SECTION_GID/addTask")
  if echo "$MOVE_RESP" | jq -e .errors >/dev/null 2>&1; then
    echo ">> section move: WARN — Asana returned errors: $(echo "$MOVE_RESP" | jq -c .errors)" >&2
  else
    echo ">> section move: $STATUS_NAME"
  fi
fi
