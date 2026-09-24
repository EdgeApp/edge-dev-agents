#!/usr/bin/env bash
# asana-field-ensure.sh — create an enum custom field on a project if it does not
# exist yet, and print its gid plus option gids as JSON for asana-config.json.
#
# The watcher reads orchestration fields (agent_status, agent_model, agent_lane,
# agent_deliverable) by gid from asana-config.json, so a new field has to be
# created once and its gids recorded. This is the sanctioned way to do that:
# block-raw-asana-api.sh forbids ad-hoc curls, and no other companion script
# creates fields. Idempotent: an existing field of the same name on the project
# is reported, never duplicated, and missing options are added to it.
#
# Usage:
#   asana-field-ensure.sh --project <gid> --name <field> --options "A,B,C" [--description "<text>"]
# Output (stdout): {"gid":"...","options":{"A":"...","B":"...","C":"..."}}
# Exit: 0 ok, 1 error, 2 usage.
set -euo pipefail

API="https://app.asana.com/api/1.0"
PROJECT=""; NAME=""; OPTS=""; DESC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --options) OPTS="$2"; shift 2 ;;
    --description) DESC="$2"; shift 2 ;;
    *) echo "usage: asana-field-ensure.sh --project <gid> --name <field> --options \"A,B,C\" [--description <text>]" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$NAME" ] && [ -n "$OPTS" ] || { echo "usage: --project, --name and --options are required" >&2; exit 2; }

TOK="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null || true)}"
[ -n "$TOK" ] || { echo "ERROR: no Asana token (ASANA_TOKEN or credentials.json)" >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $TOK" -H "Content-Type: application/json")

WS=$(curl -sf --max-time 20 "${AUTH[@]}" "$API/projects/$PROJECT?opt_fields=workspace.gid" | jq -r '.data.workspace.gid')
[ -n "$WS" ] && [ "$WS" != "null" ] || { echo "ERROR: cannot resolve workspace for project $PROJECT" >&2; exit 1; }

FGID=$(curl -sf --max-time 20 "${AUTH[@]}" \
  "$API/projects/$PROJECT/custom_field_settings?opt_fields=custom_field.gid,custom_field.name&limit=100" \
  | jq -r --arg n "$NAME" '.data[] | select(.custom_field.name == $n) | .custom_field.gid' | head -1)

if [ -z "$FGID" ]; then
  body=$(jq -cn --arg ws "$WS" --arg n "$NAME" --arg d "$DESC" --arg o "$OPTS" \
    '{data:{workspace:$ws, name:$n, resource_subtype:"enum", description:$d,
            enum_options:($o | split(",") | map({name:(.|ltrimstr(" ")|rtrimstr(" "))}))}}')
  FGID=$(curl -sf --max-time 30 -X POST "${AUTH[@]}" "$API/custom_fields" -d "$body" | jq -r '.data.gid')
  [ -n "$FGID" ] && [ "$FGID" != "null" ] || { echo "ERROR: field create failed" >&2; exit 1; }
  curl -sf --max-time 20 -X POST "${AUTH[@]}" "$API/projects/$PROJECT/addCustomFieldSetting" \
    -d "$(jq -cn --arg f "$FGID" '{data:{custom_field:$f, is_important:true}}')" >/dev/null
  echo "CREATED_FIELD: $NAME ($FGID) on project $PROJECT" >&2
else
  echo "FIELD_EXISTS: $NAME ($FGID)" >&2
fi

# Add any option that is missing (idempotent), then print the map.
existing=$(curl -sf --max-time 20 "${AUTH[@]}" "$API/custom_fields/$FGID?opt_fields=enum_options.gid,enum_options.name,enum_options.enabled")
IFS=',' read -r -a wanted <<< "$OPTS"
for o in "${wanted[@]}"; do
  o="${o## }"; o="${o%% }"
  if ! printf '%s' "$existing" | jq -e --arg o "$o" '.data.enum_options[] | select(.enabled and .name == $o)' >/dev/null; then
    curl -sf --max-time 20 -X POST "${AUTH[@]}" "$API/custom_fields/$FGID/enum_options" \
      -d "$(jq -cn --arg o "$o" '{data:{name:$o}}')" >/dev/null
    echo "CREATED_OPTION: $o" >&2
  fi
done
curl -sf --max-time 20 "${AUTH[@]}" "$API/custom_fields/$FGID?opt_fields=enum_options.gid,enum_options.name,enum_options.enabled" \
  | jq -c --arg g "$FGID" '{gid:$g, options:([.data.enum_options[] | select(.enabled) | {(.name):.gid}] | add)}'
