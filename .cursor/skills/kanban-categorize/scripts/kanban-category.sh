#!/usr/bin/env bash
# kanban-category.sh — bulk field/tag operations on an Asana kanban board
# (Category enum, "UI (Minor)" tagging, additive Departments).
#
# Why this exists (vs the Asana MCP tools): the MCP search_tasks custom-field
# and section filters are silently ignored (a Department-filtered query returns
# unfiltered rows), and update_tasks has no tag support. This script paginates
# the raw REST API — GET /projects/<gid>/tasks with completed_since=now returns
# exactly the incomplete tasks — and resolves field/option/tag GIDs by NAME at
# runtime, so nothing breaks when the board grows new enum options.
#
# Subcommands:
#   fetch  [--department <name>] [--board <gid>] [--out <file.json>]
#          Writes incomplete tasks (gid, name, notes, category, board state,
#          departments, tags) as a JSON array; prints path + counts + Category
#          and Departments distributions + the Category field's options.
#          With --department, filters to tasks carrying that department.
#          CONTEXT BUDGET: notes are truncated to 1000 chars (tasks carry
#          pasted logs); use `detail` for a deeper read of one task.
#   detail --task <gid>
#          One task at full working fidelity, still bounded: notes to 3000
#          chars, first 25 subtasks (name+completed), last 10 comments
#          (text to 500 chars each, system stories dropped).
#   apply  --file <assign.tsv> [--board <gid>]
#          assign.tsv lines: <task-gid>\t<Category option name>. Resolves each
#          name to its option gid and PUTs. One status line per task.
#   tag    --tag-name <name> --file <gids.txt>
#          Adds the named workspace tag to each task gid (one per line).
#          addTag is idempotent — re-tagging an already-tagged task is a no-op.
#   set-department --department <name> --file <gids.txt>
#          Adds the named Departments option to each task gid (one per line).
#          ADDITIVE BY CONSTRUCTION: reads the task's current multi-enum values
#          and PUTs the union — this script has no removal path, so existing
#          departments can never be dropped. Tasks already carrying the
#          department are skipped (no write).
#   verify --file <assign.tsv> [--board <gid>]
#          Refetches every task in the TSV and diffs stored Category vs
#          intended. Prints MISMATCH lines; exit 1 if any.
#
# Exit: 0 = success, 1 = error/mismatch, 2 = usage.
set -euo pipefail

BOARD="1213843652804305"           # ⚡ Edge 4.x – Kanban Board (Master)
WORKSPACE="9976422036640"
API="https://app.asana.com/api/1.0"

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "ERROR: no ASANA_TOKEN and no credentials.json token" >&2; exit 1; }

usage() {
  echo "usage: kanban-category.sh fetch [--department <name>] [--board <gid>] [--out <file>]" >&2
  echo "       kanban-category.sh detail --task <gid>" >&2
  echo "       kanban-category.sh apply --file <assign.tsv> [--board <gid>]" >&2
  echo "       kanban-category.sh tag --tag-name <name> --file <gids.txt>" >&2
  echo "       kanban-category.sh set-department --department <name> --file <gids.txt>" >&2
  echo "       kanban-category.sh verify --file <assign.tsv> [--board <gid>]" >&2
  exit 2
}

CMD="${1:-}"; shift || usage
DEPARTMENT=""; OUT=""; FILE=""; TAG_NAME=""; TASK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --department) DEPARTMENT="$2"; shift 2;;
    --board)      BOARD="$2"; shift 2;;
    --out)        OUT="$2"; shift 2;;
    --file)       FILE="$2"; shift 2;;
    --tag-name)   TAG_NAME="$2"; shift 2;;
    --task)       TASK="$2"; shift 2;;
    *) echo "ERROR: unknown arg $1" >&2; usage;;
  esac
done

auth=(-H "Authorization: Bearer $TOKEN")

# Category option map for the board: "<Name>\t<gid>" lines.
category_options() {
  curl -sf --max-time 30 "${auth[@]}" \
    "$API/projects/$BOARD?opt_fields=custom_field_settings.custom_field.name,custom_field_settings.custom_field.gid,custom_field_settings.custom_field.enum_options.name,custom_field_settings.custom_field.enum_options.gid" \
  | jq -r '.data.custom_field_settings[].custom_field | select(.name=="Category") | .enum_options[] | "\(.name)\t\(.gid)"'
}

category_field_gid() {
  curl -sf --max-time 30 "${auth[@]}" \
    "$API/projects/$BOARD?opt_fields=custom_field_settings.custom_field.name,custom_field_settings.custom_field.gid" \
  | jq -r '.data.custom_field_settings[].custom_field | select(.name=="Category") | .gid'
}

# Paginate all incomplete tasks on the board into a JSON array on stdout.
fetch_incomplete() {
  local fields="$1" offset="" page tmp
  tmp=$(mktemp -d)
  local i=0
  while :; do
    i=$((i+1))
    local url="$API/projects/$BOARD/tasks?limit=100&completed_since=now&opt_fields=$fields"
    [ -n "$offset" ] && url="$url&offset=$offset"
    curl -sf --max-time 30 "${auth[@]}" "$url" > "$tmp/p$i.json"
    offset=$(jq -r '.next_page.offset // empty' "$tmp/p$i.json")
    [ -z "$offset" ] && break
    [ $i -ge 20 ] && { echo "ERROR: pagination runaway (>20 pages)" >&2; exit 1; }
  done
  jq -s '[.[].data[]] | unique_by(.gid)' "$tmp"/p*.json
  rm -rf "$tmp"
}

case "$CMD" in

fetch)
  OUT="${OUT:-${TMPDIR:-/tmp}/kanban-${DEPARTMENT:+${DEPARTMENT// /-}}${DEPARTMENT:-all}.json}"
  fetch_incomplete "name,notes,completed,tags.name,tags.gid,custom_fields.name,custom_fields.enum_value.name,custom_fields.multi_enum_values.name" \
  | jq --arg dept "$DEPARTMENT" '[.[]
      | select(.completed==false)
      | {gid, name,
         notes: ((.notes // "")[0:1000]),
         category: ([.custom_fields[]? | select(.name=="Category") | .enum_value.name] | first),
         state: ([.custom_fields[]? | select(.name|startswith("Board State")) | .enum_value.name] | first),
         departments: [.custom_fields[]? | select(.name|startswith("Departments")) | .multi_enum_values[]?.name],
         tags: [.tags[]?.name]}
      | select(($dept=="") or (.departments | index($dept)))]' > "$OUT"
  echo "out: $OUT"
  echo "tasks: $(jq 'length' "$OUT")"
  echo "missing-category: $(jq '[.[]|select(.category==null)]|length' "$OUT")"
  echo "category-distribution:"
  jq -r '[.[].category // "(none)"] | group_by(.) | sort_by(-length) | map("  \(length)\t\(.[0])") | .[]' "$OUT"
  echo "department-distribution:"
  jq -r '[.[] | (if (.departments|length)==0 then ["(none)"] else .departments end)[]] | group_by(.) | sort_by(-length) | map("  \(length)\t\(.[0])") | .[]' "$OUT"
  echo "category-options:"
  category_options | cut -f1 | sed 's/^/  /'
  ;;

detail)
  [ -n "$TASK" ] || usage
  t=$(curl -sf --max-time 30 "${auth[@]}" \
    "$API/tasks/$TASK?opt_fields=name,notes,completed,tags.name,custom_fields.name,custom_fields.enum_value.name,custom_fields.multi_enum_values.name")
  s=$(curl -sf --max-time 30 "${auth[@]}" \
    "$API/tasks/$TASK/subtasks?limit=25&opt_fields=name,completed")
  c=$(curl -sf --max-time 30 "${auth[@]}" \
    "$API/tasks/$TASK/stories?opt_fields=type,text,created_at,created_by.name")
  jq -n --argjson t "$t" --argjson s "$s" --argjson c "$c" '{
    gid: $t.data.gid, name: $t.data.name, completed: $t.data.completed,
    notes: (($t.data.notes // "")[0:3000]),
    category: ([$t.data.custom_fields[]? | select(.name=="Category") | .enum_value.name] | first),
    departments: [$t.data.custom_fields[]? | select(.name|startswith("Departments")) | .multi_enum_values[]?.name],
    tags: [$t.data.tags[]?.name],
    subtasks: [$s.data[]? | {name, completed}],
    comments: ([$c.data[]? | select(.type=="comment")] | .[-10:] | map({by: .created_by.name, at: .created_at, text: ((.text // "")[0:500])}))
  }'
  ;;

apply)
  [ -n "$FILE" ] && [ -f "$FILE" ] || usage
  FIELD=$(category_field_gid)
  [ -n "$FIELD" ] || { echo "ERROR: no Category field on board $BOARD" >&2; exit 1; }
  OPTS=$(category_options)
  ok=0; fail=0
  while IFS=$'\t' read -r gid cat _; do
    [ -n "$gid" ] || continue
    opt=$(echo "$OPTS" | awk -F'\t' -v c="$cat" '$1==c {print $2}')
    if [ -z "$opt" ]; then echo "FAIL $gid: unknown Category name '$cat'"; fail=$((fail+1)); continue; fi
    code=$(curl -s --max-time 30 -o /dev/null -w "%{http_code}" -X PUT "${auth[@]}" \
      -H "Content-Type: application/json" \
      -d "{\"data\":{\"custom_fields\":{\"$FIELD\":\"$opt\"}}}" \
      "$API/tasks/$gid")
    if [ "$code" = "200" ]; then echo "ok $gid -> $cat"; ok=$((ok+1))
    else echo "FAIL $gid: HTTP $code"; fail=$((fail+1)); fi
  done < "$FILE"
  echo "applied: ok=$ok fail=$fail"
  [ "$fail" -eq 0 ]
  ;;

tag)
  [ -n "$TAG_NAME" ] && [ -n "$FILE" ] && [ -f "$FILE" ] || usage
  # Resolve tag gid by exact name across the workspace (paginated).
  TAG_GID=""; offset=""
  while :; do
    url="$API/workspaces/$WORKSPACE/tags?limit=100&opt_fields=name"
    [ -n "$offset" ] && url="$url&offset=$offset"
    resp=$(curl -sf --max-time 30 "${auth[@]}" "$url")
    TAG_GID=$(echo "$resp" | jq -r --arg n "$TAG_NAME" 'first(.data[] | select(.name==$n) | .gid) // empty')
    [ -n "$TAG_GID" ] && break
    offset=$(echo "$resp" | jq -r '.next_page.offset // empty')
    [ -z "$offset" ] && break
  done
  [ -n "$TAG_GID" ] || { echo "ERROR: tag '$TAG_NAME' not found in workspace" >&2; exit 1; }
  ok=0; fail=0
  while IFS=$'\t' read -r gid _; do
    [ -n "$gid" ] || continue
    code=$(curl -s --max-time 30 -o /dev/null -w "%{http_code}" -X POST "${auth[@]}" \
      -H "Content-Type: application/json" -d "{\"data\":{\"tag\":\"$TAG_GID\"}}" \
      "$API/tasks/$gid/addTag")
    if [ "$code" = "200" ]; then echo "ok $gid tagged '$TAG_NAME'"; ok=$((ok+1))
    else echo "FAIL $gid: HTTP $code"; fail=$((fail+1)); fi
  done < "$FILE"
  echo "tagged: ok=$ok fail=$fail"
  [ "$fail" -eq 0 ]
  ;;

set-department)
  [ -n "$DEPARTMENT" ] && [ -n "$FILE" ] && [ -f "$FILE" ] || usage
  # Resolve the Departments field + target option gid by name (field name is
  # prefix-matched: the board names it "Departments 🤖").
  DMETA=$(curl -sf --max-time 30 "${auth[@]}" \
    "$API/projects/$BOARD?opt_fields=custom_field_settings.custom_field.name,custom_field_settings.custom_field.gid,custom_field_settings.custom_field.enum_options.name,custom_field_settings.custom_field.enum_options.gid" \
  | jq '.data.custom_field_settings[].custom_field | select(.name|startswith("Departments"))')
  DFIELD=$(echo "$DMETA" | jq -r '.gid // empty')
  [ -n "$DFIELD" ] || { echo "ERROR: no Departments field on board $BOARD" >&2; exit 1; }
  DOPT=$(echo "$DMETA" | jq -r --arg n "$DEPARTMENT" 'first(.enum_options[] | select(.name==$n) | .gid) // empty')
  [ -n "$DOPT" ] || { echo "ERROR: unknown Departments option '$DEPARTMENT'; available:" >&2
                      echo "$DMETA" | jq -r '.enum_options[].name' | sed 's/^/  /' >&2; exit 1; }
  ok=0; fail=0; skip=0
  while IFS=$'\t' read -r gid _; do
    [ -n "$gid" ] || continue
    cur=$(curl -s --max-time 30 "${auth[@]}" \
      "$API/tasks/$gid?opt_fields=custom_fields.gid,custom_fields.multi_enum_values.gid" \
    | jq -c --arg f "$DFIELD" '[.data.custom_fields[]? | select(.gid==$f) | .multi_enum_values[]?.gid]' || echo "")
    if [ -z "$cur" ]; then echo "FAIL $gid: could not read current departments"; fail=$((fail+1)); continue; fi
    if echo "$cur" | jq -e --arg o "$DOPT" 'index($o) != null' >/dev/null; then
      echo "ok $gid already '$DEPARTMENT'"; skip=$((skip+1)); continue
    fi
    vals=$(echo "$cur" | jq -c --arg o "$DOPT" '. + [$o]')
    code=$(curl -s --max-time 30 -o /dev/null -w "%{http_code}" -X PUT "${auth[@]}" \
      -H "Content-Type: application/json" \
      -d "{\"data\":{\"custom_fields\":{\"$DFIELD\":$vals}}}" \
      "$API/tasks/$gid")
    if [ "$code" = "200" ]; then echo "ok $gid +'$DEPARTMENT'"; ok=$((ok+1))
    else echo "FAIL $gid: HTTP $code"; fail=$((fail+1)); fi
  done < "$FILE"
  echo "set-department: ok=$ok already=$skip fail=$fail"
  [ "$fail" -eq 0 ]
  ;;

verify)
  [ -n "$FILE" ] && [ -f "$FILE" ] || usage
  CUR=$(fetch_incomplete "custom_fields.name,custom_fields.enum_value.name" \
    | jq -r '.[] | "\(.gid)\t\([.custom_fields[]? | select(.name=="Category") | .enum_value.name] | first // "(none)")"')
  mismatch=0
  while IFS=$'\t' read -r gid want _; do
    [ -n "$gid" ] || continue
    have=$(echo "$CUR" | awk -F'\t' -v g="$gid" '$1==g {print $2}')
    if [ "$have" != "$want" ]; then echo "MISMATCH $gid: want '$want' have '${have:-<not on board / completed>}'"; mismatch=$((mismatch+1)); fi
  done < "$FILE"
  echo "verified: $(wc -l < "$FILE" | tr -d ' ') tasks, mismatches=$mismatch"
  [ "$mismatch" -eq 0 ]
  ;;

*) usage;;
esac
