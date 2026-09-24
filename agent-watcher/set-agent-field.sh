#!/usr/bin/env bash
# set-agent-field.sh — set one orchestration enum field (agent_deliverable,
# agent_model, agent_effort, ...) on an Asana task, by field name and option
# label, using the gids in asana-config.json.
#
# update-status.sh owns agent_status (it also moves the kanban section); this
# script is for the other agent_* enums, which have no section side effect and
# no sanctioned setter otherwise (block-raw-asana-api.sh forbids ad-hoc curls,
# and asana-task-create.sh blocklists agent_* fields at creation by design).
#
# Usage: set-agent-field.sh <task_gid> <field_name> <option_label>
#   e.g. set-agent-field.sh 1234567890 agent_deliverable "Task + sim"
# Exit: 0 set, 1 API error, 2 usage or unknown field/option.
set -euo pipefail

GID="${1:-}"; FIELD="${2:-}"; LABEL="${3:-}"
[ -n "$GID" ] && [ -n "$FIELD" ] && [ -n "$LABEL" ] || { echo "usage: set-agent-field.sh <task_gid> <field_name> <option_label>" >&2; exit 2; }
CFG="$HOME/.config/agent-watcher/asana-config.json"
FGID=$(jq -r --arg f "$FIELD" '.custom_fields[$f].gid // empty' "$CFG")
[ -n "$FGID" ] || { echo "ERROR: field $FIELD not in $CFG custom_fields" >&2; exit 2; }
# Options are either "label": "gid" or "label": {"gid": ...} (agent_model).
OGID=$(jq -r --arg f "$FIELD" --arg l "$LABEL" '.custom_fields[$f].options[$l] | if type=="object" then .gid else . end // empty' "$CFG")
[ -n "$OGID" ] || { echo "ERROR: option '$LABEL' not in $FIELD; known: $(jq -r --arg f "$FIELD" '.custom_fields[$f].options | keys | join(", ")' "$CFG")" >&2; exit 2; }
TOK="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json")}"
[ -n "$TOK" ] || { echo "ERROR: no Asana token" >&2; exit 1; }
curl -sf --max-time 20 -X PUT "https://app.asana.com/api/1.0/tasks/$GID" \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d "$(jq -cn --arg f "$FGID" --arg o "$OGID" '{data:{custom_fields:{($f):$o}}}')" >/dev/null \
  && echo "SET: $FIELD=$LABEL on $GID" || { echo "ERROR: Asana rejected the update for $GID" >&2; exit 1; }
