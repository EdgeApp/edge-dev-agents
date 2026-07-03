#!/usr/bin/env bash
# asana-build-field.sh — resolve a task's "Build (staging/cheese)" enum value.
#
# The field lives on the Engineering Board (gid 1213928707858644); tasks
# multi-homed into that project carry it. Consumers route on the value:
#   staging                      → /pr-land cherry-picks onto staging after land
#   feta|gouda|halloumi|cheddar  → /one-shot kicks a cheese build (test-<value>
#                                  hard-reset to the PR head) before Complete
#   none                         → no build routing
#
# Usage: asana-build-field.sh <task-gid>
# stdout: exactly one token: staging | feta | gouda | halloumi | cheddar | none
# Exit: 0 = resolved (incl. none), 1 = auth/network error, 2 = usage.
set -euo pipefail

GID="${1:-}"
[ -n "$GID" ] || { echo "usage: asana-build-field.sh <task-gid>" >&2; exit 2; }

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "ERROR: no ASANA_TOKEN and no credentials.json token" >&2; exit 1; }

FIELD_GID="1213928707858644" # "Build (staging/cheese)" on the Engineering Board

resp=$(curl -sf --max-time 20 \
  "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.gid,custom_fields.name,custom_fields.display_value" \
  -H "Authorization: Bearer $TOKEN") || { echo "ERROR: asana fetch failed for $GID" >&2; exit 1; }

val=$(echo "$resp" | jq -r --arg g "$FIELD_GID" \
  'first(.data.custom_fields[]? | select(.gid == $g or ((.name // "") == "Build (staging/cheese)")) | .display_value) // empty')

if [ -n "$val" ] && [ "$val" != "null" ]; then
  echo "$val" | tr '[:upper:]' '[:lower:]'
else
  echo "none"
fi
