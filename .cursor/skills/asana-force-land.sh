#!/usr/bin/env bash
# asana-force-land.sh — resolve a task's "Force Land" enum (Engineering Board).
#
# The field (gid 1216270424525434) is the operator's opt-in to land WITHOUT a
# human PR approval — for trivial changes (copy tweaks) where review adds
# nothing. All other landing legitimacy comes from an actual human approval on
# the PR (one-shot `land-on-approval`); this field overrides the approval
# requirement and, in pr-land-prepare.sh, the CHANGELOG entry requirement;
# never CI or the finalize gate.
#
# --since <iso8601>: print land-approved only when the field's most recent
# change to "Land Approved" (from the task's stories) happened AFTER that time.
# pr-address.sh dismiss-review uses it so Force Land overrides only a review
# the operator saw before setting the field, never a change request filed
# after it.
#
# Usage: asana-force-land.sh <task-gid> [--since <iso8601>]
# stdout: exactly one token: land-approved | none
# Exit: 0 = resolved (incl. none), 1 = auth/network error, 2 = usage.
set -euo pipefail

GID="" SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    -*) echo "usage: asana-force-land.sh <task-gid> [--since <iso8601>]" >&2; exit 2 ;;
    *) GID="$1"; shift ;;
  esac
done
[ -n "$GID" ] || { echo "usage: asana-force-land.sh <task-gid> [--since <iso8601>]" >&2; exit 2; }

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "ERROR: no ASANA_TOKEN and no credentials.json token" >&2; exit 1; }

FIELD_GID="$(jq -r '.custom_fields.force_land.gid // empty' "$HOME/.config/agent-watcher/asana-config.json")" # "Force Land", from the field registry
[ -n "$FIELD_GID" ] || { echo "ERROR: no custom_fields.force_land.gid in asana-config.json" >&2; exit 1; }

resp=$(curl -sf --max-time 20 \
  "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.gid,custom_fields.name,custom_fields.display_value" \
  -H "Authorization: Bearer $TOKEN") || { echo "ERROR: asana fetch failed for $GID" >&2; exit 1; }

val=$(echo "$resp" | jq -r --arg g "$FIELD_GID" \
  'first(.data.custom_fields[]? | select(.gid == $g or ((.name // "") == "Force Land")) | .display_value) // empty')

if [ "$val" != "Land Approved" ]; then
  echo "none"
  exit 0
fi

if [ -n "$SINCE" ]; then
  # Latest story setting the field to Land Approved. No such story (field set
  # at task creation, or history unreadable) means the set time is unknown:
  # resolve to none, so a caller gating on recency never over-grants.
  set_at=""
  offset=""
  while :; do
    url="https://app.asana.com/api/1.0/tasks/$GID/stories?limit=100&opt_fields=created_at,resource_subtype,custom_field.gid,custom_field.name,new_enum_value.name"
    [ -n "$offset" ] && url="$url&offset=$offset"
    page=$(curl -sf --max-time 20 "$url" -H "Authorization: Bearer $TOKEN") || { echo "ERROR: asana stories fetch failed for $GID" >&2; exit 1; }
    hit=$(echo "$page" | jq -r --arg g "$FIELD_GID" \
      '[.data[]? | select(.resource_subtype == "enum_custom_field_changed")
        | select((.custom_field.gid // "") == $g or (.custom_field.name // "") == "Force Land")
        | select((.new_enum_value.name // "") == "Land Approved") | .created_at] | last // empty')
    [ -n "$hit" ] && set_at="$hit"
    offset=$(echo "$page" | jq -r '.next_page.offset // empty')
    [ -n "$offset" ] || break
  done
  if [ -z "$set_at" ] || [[ ! "$set_at" > "$SINCE" ]]; then
    echo "none"
    exit 0
  fi
fi

echo "land-approved"
