#!/usr/bin/env bash
# setup-kanban-sections.sh — One-time (idempotent) setup of agent_status-aligned
# kanban sections in the Asana project + persist section GIDs into
# ~/.config/agent-watcher/asana-config.json so update-status.sh can move tasks
# to the matching section.
#
# Behavior:
#   1. Read existing sections from the project.
#   2. For each agent_status value (Pending, Planning, Developing, Reviewing,
#      Testing, Complete):
#        - If a section with that exact name exists, capture its GID.
#        - If the project's default "Untitled section" still exists AND no
#          matching section is found for the first missing status, RENAME the
#          default to that status (avoids leaving a stray section behind).
#        - Otherwise, CREATE the section.
#   3. Write the resulting section_gids map into asana-config.json under
#      .custom_fields.agent_status.section_gids (sibling of .options).
#   4. Optionally backfill existing tasks: move each task to the section
#      matching its current agent_status. Pass --backfill to enable.
#
# Re-running this script is safe — sections won't be duplicated.
#
# Usage:
#   setup-kanban-sections.sh [--backfill]
#
# Exit codes:
#   0 = success (config + sections in sync)
#   1 = error (Asana API failure, malformed config)

set -euo pipefail

CONFIG="$HOME/.config/agent-watcher/asana-config.json"
CRED="$HOME/.config/agent-watcher/credentials.json"
API="https://app.asana.com/api/1.0"

[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG" >&2; exit 1; }
[[ -f "$CRED"   ]] || { echo "Missing $CRED"   >&2; exit 1; }

BACKFILL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backfill) BACKFILL=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TOKEN=$(jq -r .asana_token "$CRED")
PROJECT_GID=$(jq -r .project_gid "$CONFIG")

# Section names that mirror agent_status enum (order matters for the kanban view)
ORDERED_STATUSES=(Pending Planning Developing Reviewing Testing Complete)

# ─── 1. Read existing sections ───────────────────────────────────────────────
EXISTING=$(curl -sS -H "Authorization: Bearer $TOKEN" "$API/projects/$PROJECT_GID/sections?opt_fields=name,gid")
echo "$EXISTING" | jq -e .data >/dev/null 2>&1 || {
  echo "Failed to fetch sections: $EXISTING" >&2
  exit 1
}

# ─── 2. Resolve each status to a section GID (find / rename / create) ────────
declare -A SECTION_GIDS
UNTITLED_GID=$(echo "$EXISTING" | jq -r '.data[] | select(.name == "Untitled section") | .gid' | head -1)

for status in "${ORDERED_STATUSES[@]}"; do
  existing_gid=$(echo "$EXISTING" | jq -r --arg n "$status" '.data[] | select(.name == $n) | .gid' | head -1)

  if [[ -n "$existing_gid" ]]; then
    SECTION_GIDS[$status]="$existing_gid"
    echo ">> section '$status' already exists (gid=$existing_gid)"
    continue
  fi

  # Absorb the auto-created "Untitled section" on the first missing status
  if [[ -n "$UNTITLED_GID" ]]; then
    echo ">> renaming 'Untitled section' → '$status' (gid=$UNTITLED_GID)"
    resp=$(curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg n "$status" '{data: {name: $n}}')" \
      "$API/sections/$UNTITLED_GID")
    new_gid=$(echo "$resp" | jq -r '.data.gid // empty')
    [[ -n "$new_gid" ]] || { echo "Rename failed: $resp" >&2; exit 1; }
    SECTION_GIDS[$status]="$new_gid"
    UNTITLED_GID=""   # only absorb once
    continue
  fi

  # Create it fresh
  echo ">> creating section '$status'"
  resp=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -n --arg n "$status" '{data: {name: $n}}')" \
    "$API/projects/$PROJECT_GID/sections")
  new_gid=$(echo "$resp" | jq -r '.data.gid // empty')
  [[ -n "$new_gid" ]] || { echo "Create failed for '$status': $resp" >&2; exit 1; }
  SECTION_GIDS[$status]="$new_gid"
done

# ─── 3. Persist into asana-config.json (merge into custom_fields.agent_status.section_gids) ──
SECTIONS_JSON=$(jq -n \
  --arg pe "${SECTION_GIDS[Pending]}" \
  --arg pl "${SECTION_GIDS[Planning]}" \
  --arg dv "${SECTION_GIDS[Developing]}" \
  --arg rv "${SECTION_GIDS[Reviewing]}" \
  --arg tn "${SECTION_GIDS[Testing]}" \
  --arg cp "${SECTION_GIDS[Complete]}" \
  '{Pending:$pe, Planning:$pl, Developing:$dv, Reviewing:$rv, Testing:$tn, Complete:$cp}')

tmp=$(mktemp)
jq --argjson s "$SECTIONS_JSON" '.custom_fields.agent_status.section_gids = $s' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"
chmod 600 "$CONFIG"
echo ">> wrote section_gids into $CONFIG"

# ─── 4. Optional backfill: move existing tasks to their current-status section ──
if $BACKFILL; then
  echo ">> backfill: moving existing tasks to their agent_status section"
  STATUS_FIELD_GID=$(jq -r .custom_fields.agent_status.gid "$CONFIG")
  TASKS=$(curl -sS -H "Authorization: Bearer $TOKEN" \
    "$API/projects/$PROJECT_GID/tasks?opt_fields=name,custom_fields.gid,custom_fields.enum_value.name")
  echo "$TASKS" | jq -c '.data[]' | while read -r task; do
    gid=$(echo "$task" | jq -r '.gid')
    name=$(echo "$task" | jq -r '.name' | cut -c1-60)
    status=$(echo "$task" | jq -r --arg f "$STATUS_FIELD_GID" '.custom_fields[]? | select(.gid == $f) | .enum_value.name // empty')
    if [[ -z "$status" ]]; then
      echo "   skip (no agent_status): $name"
      continue
    fi
    target=$(jq -r --arg s "$status" '.custom_fields.agent_status.section_gids[$s] // empty' "$CONFIG")
    if [[ -z "$target" ]]; then
      echo "   skip (no section for status '$status'): $name"
      continue
    fi
    moveresp=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg t "$gid" '{data: {task: $t}}')" \
      "$API/sections/$target/addTask")
    if echo "$moveresp" | jq -e .errors >/dev/null 2>&1; then
      echo "   FAIL move: $name → $status — $(echo "$moveresp" | jq -c .errors)"
    else
      echo "   moved → $status: $name"
    fi
  done
fi

echo ">> setup-kanban-sections: done"
