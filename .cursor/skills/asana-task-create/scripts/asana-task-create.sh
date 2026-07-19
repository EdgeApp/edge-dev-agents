#!/usr/bin/env bash
# asana-task-create.sh
# Create an Edge dev task homed on the standard boards, with Engineering-board
# custom fields settable by NAME (option GIDs resolved at runtime):
#   - Edge 4.x Kanban (Master)  [default incoming section]
#   - Engineering Board          [default incoming section]
#   - jon-claude agent board     [Refinement section by default]
#
# Missing enum options are auto-created for the fields in CREATE_ALLOWLIST
# (Release (4.x.x), Repo) only; other fields error out listing valid options.
# Attachments delegate to asana-task-update.sh --attach-file.
#
# Modes:
#   (default)             create a task
#   --show-field-context  print Engineering-board fields + how recent tasks
#                         fill them, then exit (read-only; for choosing values)
#
# Usage:
#   asana-task-create.sh --name "<task name>" --notes-file /tmp/notes.txt \
#     [--release 53.0] [--repo core,gui] \
#     [--set "Priority=High"] [--set "LOE=M"] [--set "Category=Feature"] \
#     [--set "Release Notes=Needs To Be Added"] [--set "Estimate (hrs)=6"] \
#     [--attach-file /path/one.md]... \
#     [--jon-claude-section Refinement] [--dry-run]
#
# Output (one per line):
#   TASK_GID: / TASK_URL: / ADDED: / FIELD: / CREATED_OPTION: / ATTACHED:
# Exit: 0 = success, 1 = error (enum misses list the valid option names).
set -euo pipefail

WORKSPACE_GID="9976422036640"
MASTER_BOARD_GID="1213843652804305"     # ⚡ Edge 4.x – Kanban Board (Master)
ENG_BOARD_GID="1213880789473005"        # ⚙️ Engineering Board
JON_CLAUDE_BOARD_GID="1215088146871429" # 🥋Jon-Claude Von Dayamnn 👊

RELEASE_FIELD_NAME="Release (4.x.x)"
REPO_FIELD_NAME="Repo"

API="https://app.asana.com/api/1.0"

NAME=""
NOTES_FILE=""
RELEASE=""
REPOS=""
SET_SPECS=()
ATTACH_FILES=()
JC_SECTION="Refinement"
DRY_RUN=false
SHOW_CONTEXT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --repo) REPOS="$2"; shift 2 ;;
    --set) SET_SPECS+=("$2"); shift 2 ;;
    --attach-file) ATTACH_FILES+=("$2"); shift 2 ;;
    --jon-claude-section) JC_SECTION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --show-field-context) SHOW_CONTEXT=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[[ -n "$TOKEN" ]] || { echo "ERROR: no ASANA_TOKEN and no credentials.json token" >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//'; }

# Fields whose missing enum options may be auto-created:
allow_create() {
  case "$(lc "$1")" in
    "release (4.x.x)"|"repo") return 0 ;;
    *) return 1 ;;
  esac
}

# Normalize release spellings to the field's option naming ("53.0"):
#   4.53 -> 53.0, 4.53.1 -> 53.1, 53 -> 53.0, 53.0 -> 53.0
normalize_release() {
  local v="$1"
  if [[ "$v" =~ ^4\.([0-9]+)\.([0-9]+)$ ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "$v" =~ ^4\.([0-9]+)$ ]]; then
    printf '%s.0' "${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^([0-9]+)$ ]]; then
    printf '%s.0' "$v"
  else
    printf '%s' "$v"
  fi
}

# Automation-, workflow-, or orchestration-owned fields; never set at creation:
is_blocked() {
  case "$(lc "$1")" in
    "board state 🤖"|"departments 🤖"|"🤖 - developer"|"agent_status"|"agent_model"|"agent_effort"|"blocked"|"tested"|"force land"|"build (staging/cheese)"|"status"|"proposal status") return 0 ;;
    *) return 1 ;;
  esac
}

# Field settings for both boards, fetched once: gid<TAB>subtype<TAB>name
FIELD_TABLE=""
load_fields() {
  [[ -n "$FIELD_TABLE" ]] && return 0
  local proj rows=""
  for proj in "$ENG_BOARD_GID" "$MASTER_BOARD_GID"; do
    rows+=$(curl -sf --max-time 20 "${AUTH[@]}" \
      "$API/projects/$proj/custom_field_settings?opt_fields=custom_field.gid,custom_field.name,custom_field.resource_subtype&limit=100" \
      | jq -r '.data[].custom_field | [.gid, .resource_subtype, .name] | @tsv')$'\n'
  done
  FIELD_TABLE=$(printf '%s' "$rows" | awk -F'\t' '!seen[$1]++')
}

# field_lookup <name> -> "gid<TAB>subtype<TAB>canonical_name" (trailing-space tolerant)
field_lookup() {
  local wanted; wanted=$(lc "$1")
  load_fields
  local line
  line=$(printf '%s\n' "$FIELD_TABLE" | awk -F'\t' -v w="$wanted" \
    'BEGIN{IGNORECASE=0} { n=tolower($3); gsub(/^ +| +$/, "", n); if (n == w) { print; exit } }')
  [[ -n "$line" ]] || {
    echo "ERROR: no custom field named \"$1\" on the Engineering/Master boards. Known fields:" >&2
    printf '%s\n' "$FIELD_TABLE" | awk -F'\t' '{print "  - " $3 " (" $2 ")"}' >&2
    exit 1
  }
  printf '%s' "$line"
}

# resolve_enum <field_gid> <field_name> <wanted> -> option gid
# Exact case-insensitive match, else unique prefix match ("M" -> "M (2-4h)").
# If missing and the field is in CREATE_ALLOWLIST, creates the option.
resolve_enum() {
  local field_gid="$1" label="$2" wanted="$3"
  local opts gid
  opts=$(curl -sf --max-time 20 "${AUTH[@]}" \
    "$API/custom_fields/$field_gid?opt_fields=enum_options.gid,enum_options.name,enum_options.enabled") \
    || { echo "ERROR: could not fetch options for $label" >&2; exit 1; }
  gid=$(echo "$opts" | jq -r --arg w "$wanted" '
    [.data.enum_options[] | select(.enabled)] as $o
    | (first($o[] | select((.name | ascii_downcase) == ($w | ascii_downcase))) // empty).gid
    // ([$o[] | select((.name | ascii_downcase) | startswith($w | ascii_downcase))] | if length == 1 then .[0].gid else empty end)
    // empty')
  if [[ -z "$gid" ]]; then
    if allow_create "$label"; then
      gid=$(curl -sf --max-time 20 -X POST "$API/custom_fields/$field_gid/enum_options" "${AUTH[@]}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg n "$wanted" '{data: {name: $n}}')" | jq -r '.data.gid // empty')
      [[ -n "$gid" ]] || { echo "ERROR: failed to create option \"$wanted\" on $label" >&2; exit 1; }
      echo "CREATED_OPTION: $label=$wanted"
    else
      echo "ERROR: $label has no option matching \"$wanted\". Available:" >&2
      echo "$opts" | jq -r '.data.enum_options[] | select(.enabled) | "  - " + .name' >&2
      exit 1
    fi
  fi
  printf '%s' "$gid"
}

if $SHOW_CONTEXT; then
  load_fields
  echo "== Engineering/Master board fields =="
  printf '%s\n' "$FIELD_TABLE" | awk -F'\t' '{print $3 " (" $2 ")"}'
  echo ""
  echo "== Recent Engineering tasks and their filled fields =="
  peers=$(curl -sf --max-time 30 "${AUTH[@]}" \
    "$API/workspaces/$WORKSPACE_GID/tasks/search?projects.any=$ENG_BOARD_GID&sort_by=modified_at&limit=8&opt_fields=name,custom_fields.name,custom_fields.display_value" \
    || curl -sf --max-time 30 "${AUTH[@]}" \
    "$API/projects/$ENG_BOARD_GID/tasks?limit=8&opt_fields=name,custom_fields.name,custom_fields.display_value")
  echo "$peers" | jq -r '.data[] | .name + "\n" + ([.custom_fields[]? | select(.display_value != null and .display_value != "") | "  " + .name + " = " + .display_value] | join("\n")) + "\n"'
  exit 0
fi

[[ -n "$NAME" ]] || { echo "ERROR: --name is required" >&2; exit 1; }
[[ -n "$NOTES_FILE" ]] || { echo "ERROR: --notes-file is required" >&2; exit 1; }
[[ -f "$NOTES_FILE" ]] || { echo "ERROR: notes file not found: $NOTES_FILE" >&2; exit 1; }
for f in "${ATTACH_FILES[@]:-}"; do
  [[ -z "$f" || -f "$f" ]] || { echo "ERROR: attach file not found: $f" >&2; exit 1; }
done

CF="{}"
declare -a FIELD_ECHO=()

# add_field <field_name> <value>  (routes by field subtype)
add_field() {
  local fname="$1" value="$2" line gid subtype canon
  if is_blocked "$fname"; then
    echo "ERROR: field \"$fname\" is automation/orchestration-owned; do not set it at creation" >&2
    exit 1
  fi
  line=$(field_lookup "$fname")
  gid=$(printf '%s' "$line" | cut -f1)
  subtype=$(printf '%s' "$line" | cut -f2)
  canon=$(printf '%s' "$line" | cut -f3)
  if [[ "$(lc "$canon")" == "release (4.x.x)" ]]; then
    value=$(normalize_release "$value")
  fi
  case "$subtype" in
    enum)
      local ogid; ogid=$(resolve_enum "$gid" "$canon" "$value")
      CF=$(echo "$CF" | jq --arg k "$gid" --arg v "$ogid" '. + {($k): $v}') ;;
    multi_enum)
      local arr="[]" part ogid
      IFS=',' read -ra parts <<< "$value"
      for part in "${parts[@]}"; do
        ogid=$(resolve_enum "$gid" "$canon" "$(echo "$part" | xargs)")
        arr=$(echo "$arr" | jq --arg g "$ogid" '. + [$g]')
      done
      CF=$(echo "$CF" | jq --arg k "$gid" --argjson v "$arr" '. + {($k): $v}') ;;
    number)
      CF=$(echo "$CF" | jq --arg k "$gid" --argjson v "$value" '. + {($k): $v}') ;;
    text)
      CF=$(echo "$CF" | jq --arg k "$gid" --arg v "$value" '. + {($k): $v}') ;;
    people|date|reference)
      echo "ERROR: field \"$canon\" ($subtype) is not supported by --set; set it manually" >&2
      exit 1 ;;
    *)
      echo "ERROR: unsupported field subtype \"$subtype\" for \"$canon\"" >&2
      exit 1 ;;
  esac
  FIELD_ECHO+=("FIELD: $canon=$value")
}

[[ -n "$RELEASE" ]] && add_field "$RELEASE_FIELD_NAME" "$RELEASE"
[[ -n "$REPOS" ]] && add_field "$REPO_FIELD_NAME" "$REPOS"
for spec in "${SET_SPECS[@]:-}"; do
  [[ -n "$spec" ]] || continue
  [[ "$spec" == *"="* ]] || { echo "ERROR: --set expects \"Field Name=Value\", got: $spec" >&2; exit 1; }
  add_field "${spec%%=*}" "${spec#*=}"
done

# Resolve the jon-claude section by name (survives section reordering/renames).
JC_SECTION_GID=$(curl -sf --max-time 20 "${AUTH[@]}" \
  "$API/projects/$JON_CLAUDE_BOARD_GID/sections?opt_fields=name" \
  | jq -r --arg w "$JC_SECTION" \
    'first(.data[] | select((.name | ascii_downcase) == ($w | ascii_downcase))).gid // empty')
[[ -n "$JC_SECTION_GID" ]] || { echo "ERROR: jon-claude board has no section named \"$JC_SECTION\"" >&2; exit 1; }

PAYLOAD=$(jq -n \
  --arg name "$NAME" \
  --rawfile notes "$NOTES_FILE" \
  --arg ws "$WORKSPACE_GID" \
  --arg master "$MASTER_BOARD_GID" \
  --argjson cf "$CF" \
  '{data: {name: $name, notes: $notes, workspace: $ws, projects: [$master], custom_fields: $cf}}')

if $DRY_RUN; then
  echo "DRY_RUN payload:"
  echo "$PAYLOAD" | jq .
  echo "DRY_RUN addProject: $ENG_BOARD_GID (default section)"
  echo "DRY_RUN addProject: $JON_CLAUDE_BOARD_GID section $JC_SECTION_GID ($JC_SECTION)"
  for f in "${ATTACH_FILES[@]:-}"; do [[ -n "$f" ]] && echo "DRY_RUN attach: $f"; done
  for line in "${FIELD_ECHO[@]:-}"; do [[ -n "$line" ]] && echo "DRY_RUN $line"; done
  exit 0
fi

resp=$(curl -sf --max-time 30 -X POST "$API/tasks" "${AUTH[@]}" \
  -H "Content-Type: application/json" -d "$PAYLOAD") \
  || { echo "ERROR: task creation failed" >&2; exit 1; }
TASK_GID=$(echo "$resp" | jq -r '.data.gid')
TASK_URL=$(echo "$resp" | jq -r '.data.permalink_url')
echo "TASK_GID: $TASK_GID"
echo "TASK_URL: $TASK_URL"
echo "ADDED: Edge 4.x Kanban (Master)"

curl -sf --max-time 20 -X POST "$API/tasks/$TASK_GID/addProject" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"data\": {\"project\": \"$ENG_BOARD_GID\"}}" > /dev/null \
  || { echo "ERROR: addProject Engineering Board failed" >&2; exit 1; }
echo "ADDED: Engineering Board"

curl -sf --max-time 20 -X POST "$API/tasks/$TASK_GID/addProject" "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"data\": {\"project\": \"$JON_CLAUDE_BOARD_GID\", \"section\": \"$JC_SECTION_GID\"}}" > /dev/null \
  || { echo "ERROR: addProject jon-claude failed" >&2; exit 1; }
echo "ADDED: jon-claude / $JC_SECTION"

for line in "${FIELD_ECHO[@]:-}"; do [[ -n "$line" ]] && echo "$line"; done

for f in "${ATTACH_FILES[@]:-}"; do
  [[ -n "$f" ]] || continue
  "$HOME/.cursor/skills/asana-task-update/scripts/asana-task-update.sh" \
    --task "$TASK_GID" --attach-file "$f" --attach-name "$(basename "$f")" > /dev/null \
    || { echo "ERROR: attach failed: $f" >&2; exit 1; }
  echo "ATTACHED: $f"
done
