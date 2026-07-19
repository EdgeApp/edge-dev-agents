#!/usr/bin/env bash
# asana-field-value.sh — resolve any custom field's display value on a task,
# by field NAME (trailing-space and case tolerant). Generic sibling of
# asana-build-field.sh (which stays pinned to the Build field for its callers).
#
# Usage: asana-field-value.sh <task-gid> <field-name>
# stdout: the display value lowercased, or "none" when unset/absent.
# Exit: 0 = resolved (incl. none), 1 = auth/network error, 2 = usage.
set -euo pipefail

GID="${1:-}"
FIELD_NAME="${2:-}"
[ -n "$GID" ] && [ -n "$FIELD_NAME" ] || { echo "usage: asana-field-value.sh <task-gid> <field-name>" >&2; exit 2; }

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "ERROR: no ASANA_TOKEN and no credentials.json token" >&2; exit 1; }

resp=$(curl -sf --max-time 20 \
  "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.name,custom_fields.display_value" \
  -H "Authorization: Bearer $TOKEN") || { echo "ERROR: asana fetch failed for $GID" >&2; exit 1; }

val=$(echo "$resp" | jq -r --arg w "$FIELD_NAME" '
  first(.data.custom_fields[]?
    | select(((.name // "") | ascii_downcase | sub("^ +"; "") | sub(" +$"; ""))
             == ($w | ascii_downcase | sub("^ +"; "") | sub(" +$"; "")))
    | .display_value) // empty')

if [ -n "$val" ] && [ "$val" != "null" ]; then
  echo "$val" | tr '[:upper:]' '[:lower:]'
else
  echo "none"
fi
