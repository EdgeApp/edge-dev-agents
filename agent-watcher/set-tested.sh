#!/usr/bin/env bash
# set-tested.sh — set the Asana "tested" multi-select field on an agent task to
# the testing method(s) actually performed. Companion to update-status.sh; same
# auth + PUT pattern, separate concern (testing method, not phase).
#
# Usage:
#   set-tested.sh <task_gid> <Option> [<Option> ...]
#   set-tested.sh <task_gid> --clear          # set the field to empty (blank)
#   set-tested.sh <task_gid> ... --dry-run     # print payload, do not PUT
#
# Options (multi-select; pass every method that genuinely ran):
#   iOS Sim     — the change was driven in-app on the iOS sim (maestro / build +
#                 simctl launch, real action to terminal success). DEFAULT sim
#                 platform; quote it ("iOS Sim") since it contains a space.
#   Android Sim — exercised on Android (gradle :app:assembleDebug for a build-only
#                 fix, or an AVD/maestro in-app drive). Only for Android tasks.
#   Unit Tests  — jest / mocha / `npm test` ran (verify-repo's test step)
#   CouchDB     — a CouchDB-backed test ran (sync / server repos: edge-reports-
#                 server, edge-core-js sync, a couch/pouch integration test)
#   Untested    — NO test method applied; mutually exclusive with the others
#                 (only static tsc/lint, or nothing). Never combine with a real
#                 method.
#
# Exit: 0 ok, 1 API/runtime error, 2 usage / unknown option.
set -euo pipefail

CONFIG="$HOME/.config/agent-watcher/asana-config.json"
CRED="$HOME/.config/agent-watcher/credentials.json"

usage() {
  echo "Usage: set-tested.sh <task_gid> <Option ...> | --clear  [--dry-run]" >&2
  echo "Options: $(jq -r '.custom_fields.tested.options | keys | join(", ")' "$CONFIG" 2>/dev/null)" >&2
  exit 2
}

TASK_GID="${1:-}"; shift || true
[[ -n "$TASK_GID" ]] || usage

DRY_RUN=false
CLEAR=false
OPTS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=true ;;
    --clear)   CLEAR=true ;;
    *)         OPTS+=("$a") ;;
  esac
done
{ [[ "$CLEAR" == true ]] || [[ ${#OPTS[@]} -gt 0 ]]; } || usage

FIELD_GID=$(jq -r .custom_fields.tested.gid "$CONFIG")
[[ -n "$FIELD_GID" && "$FIELD_GID" != "null" ]] || { echo "tested field not configured in $CONFIG" >&2; exit 1; }

# Resolve option names → option GIDs (exact-name match against config).
OPT_GIDS=()
if [[ "$CLEAR" == false ]]; then
  # Untested is mutually exclusive with real methods — reject the contradiction.
  if [[ " ${OPTS[*]} " == *" Untested "* ]] && [[ ${#OPTS[@]} -gt 1 ]]; then
    echo "Untested cannot be combined with another method." >&2; exit 2
  fi
  for name in "${OPTS[@]}"; do
    gid=$(jq -r --arg n "$name" '.custom_fields.tested.options[$n] // empty' "$CONFIG")
    [[ -n "$gid" ]] || { echo "Unknown option: $name" >&2; usage; }
    OPT_GIDS+=("$gid")
  done
fi

# multi_enum value is a JSON array of option GIDs ([] clears the field).
ARR=$(printf '%s\n' "${OPT_GIDS[@]:-}" | jq -R . | jq -cs 'map(select(length > 0))')
PAYLOAD=$(jq -n --arg f "$FIELD_GID" --argjson v "$ARR" '{data: {custom_fields: {($f): $v}}}')

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY-RUN payload for task $TASK_GID:"; echo "$PAYLOAD" | jq .
  exit 0
fi

TOKEN=$(jq -r .asana_token "$CRED")
RESPONSE=$(curl -sS -X PUT \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "$PAYLOAD" "https://app.asana.com/api/1.0/tasks/$TASK_GID")

if echo "$RESPONSE" | jq -e .errors >/dev/null 2>&1; then
  echo "Asana API error: $(echo "$RESPONSE" | jq -c .errors)" >&2
  exit 1
fi
echo "Set tested=[${OPTS[*]:-}] on task $TASK_GID"
