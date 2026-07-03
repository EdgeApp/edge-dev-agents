#!/usr/bin/env bash
# asana-force-land.sh — resolve a task's "Force Land" enum (Engineering Board).
#
# The field (gid 1216270424525434) is the operator's opt-in to land WITHOUT a
# human PR approval — for trivial changes (copy tweaks) where review adds
# nothing. All other landing legitimacy comes from an actual human approval on
# the PR (one-shot `land-on-approval`); this field overrides only the approval
# requirement, never CI or the finalize gate.
#
# Usage: asana-force-land.sh <task-gid>
# stdout: exactly one token: land-approved | none
# Exit: 0 = resolved (incl. none), 1 = auth/network error, 2 = usage.
set -euo pipefail

GID="${1:-}"
[ -n "$GID" ] || { echo "usage: asana-force-land.sh <task-gid>" >&2; exit 2; }

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "ERROR: no ASANA_TOKEN and no credentials.json token" >&2; exit 1; }

FIELD_GID="1216270424525434" # "Force Land" on the Engineering Board

resp=$(curl -sf --max-time 20 \
  "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.gid,custom_fields.name,custom_fields.display_value" \
  -H "Authorization: Bearer $TOKEN") || { echo "ERROR: asana fetch failed for $GID" >&2; exit 1; }

val=$(echo "$resp" | jq -r --arg g "$FIELD_GID" \
  'first(.data.custom_fields[]? | select(.gid == $g or ((.name // "") == "Force Land")) | .display_value) // empty')

if [ "$val" = "Land Approved" ]; then
  echo "land-approved"
else
  echo "none"
fi
