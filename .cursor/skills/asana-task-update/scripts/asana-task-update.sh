#!/usr/bin/env bash
# asana-task-update.sh
# Unified Asana task mutation script.
#
# Exit codes:
#   0 = success
#   1 = error
#   2 = needs user input (PROMPT_REVIEWER, PROMPT_IMPLEMENTOR)
set -euo pipefail

TASK_GID=""
DO_ATTACH=false
PR_URL=""
PR_TITLE=""
PR_NUMBER=""

DO_ATTACH_FILE=false
ATTACH_FILE_PATH=""
ATTACH_FILE_NAME=""

DO_ASSIGN=false
ASSIGN_GID=""
SKIP_ASSIGN_IF_MISSING=false
DO_UNASSIGN=false

SET_STATUS=""
SET_BOARD_STATE=""
SET_REVIEWER_GID=""
SET_IMPLEMENTOR_GID=""
SET_PRIORITY_GID=""
SET_PLANNED_GID=""
AUTO_EST_REVIEW=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_GID="$2"; shift 2 ;;
    --attach-pr) DO_ATTACH=true; shift ;;
    --pr-url) PR_URL="$2"; shift 2 ;;
    --pr-title) PR_TITLE="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --attach-file) DO_ATTACH_FILE=true; ATTACH_FILE_PATH="$2"; shift 2 ;;
    --attach-name) ATTACH_FILE_NAME="$2"; shift 2 ;;
    --assign)
      DO_ASSIGN=true
      if [[ $# -ge 2 && "${2:0:2}" != "--" ]]; then
        ASSIGN_GID="$2"
        shift 2
      else
        shift
      fi
      ;;
    --skip-assign-if-missing) SKIP_ASSIGN_IF_MISSING=true; shift ;;
    --unassign) DO_UNASSIGN=true; shift ;;
    --set-status) SET_STATUS="$2"; shift 2 ;;
    --set-board-state) SET_BOARD_STATE="$2"; shift 2 ;;
    --set-reviewer|--reviewer) SET_REVIEWER_GID="$2"; shift 2 ;;
    --set-implementor|--implementor) SET_IMPLEMENTOR_GID="$2"; shift 2 ;;
    --set-priority) SET_PRIORITY_GID="$2"; shift 2 ;;
    --set-planned) SET_PLANNED_GID="$2"; shift 2 ;;
    --auto-est-review-hrs) AUTO_EST_REVIEW=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TASK_GID" ]]; then
  echo "Error: --task <task_gid> is required" >&2
  exit 1
fi

if ! $DO_ATTACH && ! $DO_ATTACH_FILE && ! $DO_ASSIGN && ! $DO_UNASSIGN && [[ -z "$SET_STATUS" ]] && [[ -z "$SET_BOARD_STATE" ]] && [[ -z "$SET_REVIEWER_GID" ]] && [[ -z "$SET_IMPLEMENTOR_GID" ]] && [[ -z "$SET_PRIORITY_GID" ]] && [[ -z "$SET_PLANNED_GID" ]] && ! $AUTO_EST_REVIEW; then
  echo "Error: No operations specified" >&2
  exit 1
fi

# Token: prefer $ASANA_TOKEN, else fall back to credentials.json (the lowercase
# `asana_token` key — same source update-status.sh uses). Spawned agent shells
# don't get ASANA_TOKEN exported, so this fallback is what makes attaches work.
if [[ -z "${ASANA_TOKEN:-}" ]]; then
  CRED="$HOME/.config/agent-watcher/credentials.json"
  [[ -f "$CRED" ]] && ASANA_TOKEN="$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)"
fi
if [[ -z "${ASANA_TOKEN:-}" ]]; then
  echo "Error: ASANA_TOKEN not set and not found in credentials.json (.asana_token)" >&2
  exit 1
fi

# --attach-pr is OPTIONAL on a workspace where the Asana ↔ GitHub widget
# integration is disabled. If the secret is missing, skip the widget call with
# a warning rather than failing — the canonical Asana ↔ PR link lives in the PR
# body (injected by /pr-create) and downstream skills do not need the widget.
if $DO_ATTACH && [[ -z "${ASANA_GITHUB_SECRET:-}" ]]; then
  echo ">> PR attach: skipped (ASANA_GITHUB_SECRET not set; widget integration not configured)" >&2
  DO_ATTACH=false
fi

ASANA_API="https://app.asana.com/api/1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Airbitz.co workspace field GIDs
STATUS_FIELD="1190660107346181"
REVIEW_NEEDED_OPTION="1190660107348334"
PUBLISH_NEEDED_OPTION="1191304757575656"
VERIFICATION_NEEDED_OPTION="1190660107348340"
BOARD_STATE_FIELD="1213992584300456"
REVIEWER_FIELD="1203334388004673"
IMPLEMENTOR_FIELD="1203334386796983"
SPENT_DEV_HRS_FIELD="1202996660964169"
EST_REVIEW_HRS_FIELD="1203002792997295"

status_to_gid() {
  case "$1" in
    "Review Needed") echo "$REVIEW_NEEDED_OPTION" ;;
    "Publish Needed") echo "$PUBLISH_NEEDED_OPTION" ;;
    "Verification Needed") echo "$VERIFICATION_NEEDED_OPTION" ;;
    *) echo "$1" ;;
  esac
}

board_state_to_gid() {
  case "$1" in
    "Incoming Requests") echo "1214109511460876" ;;
    "Refinement") echo "1214109511571763" ;;
    "Ready to Pull") echo "1213992584300457" ;;
    "In Progress") echo "1213992584300458" ;;
    "PR Review") echo "1214074445437890" ;;
    "QA Verification") echo "1213992584300459" ;;
    "Blocked") echo "1213992584300460" ;;
    "Done") echo "1213992584300461" ;;
    "Icebox") echo "1214109610541444" ;;
    *) echo "$1" ;;
  esac
}

TASK_FIELDS=""
load_task_fields() {
  if [[ -n "$TASK_FIELDS" ]]; then
    return 0
  fi
  TASK_FIELDS=$(curl -sf "$ASANA_API/tasks/$TASK_GID?opt_fields=name,assignee.name,custom_fields.gid,custom_fields.name,custom_fields.people_value.gid,custom_fields.people_value.name,custom_fields.number_value,custom_fields.enum_value.gid,custom_fields.enum_value.name" \
    -H "Authorization: Bearer $ASANA_TOKEN")
}

read_people_field() {
  local field_gid="$1"
  echo "$TASK_FIELDS" | jq -r --arg gid "$field_gid" '
    .data.custom_fields[]
    | select(.gid == $gid)
    | (.people_value[0].gid // "")
  ' | head -n 1
}

if $DO_ATTACH; then
  if [[ -z "$PR_URL" || -z "$PR_TITLE" || -z "$PR_NUMBER" ]]; then
    echo "Error: --attach-pr requires --pr-url, --pr-title, and --pr-number" >&2
    exit 1
  fi

  ATTACH_BODY_FILE=$(mktemp)
  ATTACH_HTTP_CODE=$(curl -sS -o "$ATTACH_BODY_FILE" -w "%{http_code}" \
    -X POST "https://github.integrations.asana.plus/custom/v1/actions/widget" \
    -H "Authorization: Bearer $ASANA_GITHUB_SECRET" \
    -H "Content-Type: application/json" \
    -d "{
      \"allowedProjects\": [],
      \"blockedProjects\": [],
      \"pullRequestDescription\": \"https://app.asana.com/0/0/$TASK_GID\",
      \"pullRequestName\": $(jq -Rn --arg v "$PR_TITLE" '$v'),
      \"pullRequestNumber\": $PR_NUMBER,
      \"pullRequestURL\": \"$PR_URL\"
    }" 2>/dev/null || echo "000")

  if [[ "$ATTACH_HTTP_CODE" =~ ^(401|403|404)$ ]]; then
    # Asana ↔ GitHub widget integration is disabled at the workspace level
    # (or the secret is invalid). Skip gracefully — the PR body's Asana link
    # is the canonical link and downstream skills do not need the widget.
    echo ">> PR attach: skipped (integration returned $ATTACH_HTTP_CODE; widget integration disabled or secret invalid)" >&2
  elif [[ "$ATTACH_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
    ATTACH_STATUS=$(python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0].get('result','unknown'))" <"$ATTACH_BODY_FILE" 2>/dev/null || echo "ok (unparseable)")
    echo ">> PR attach: $ATTACH_STATUS"
  else
    echo ">> PR attach: failed (HTTP $ATTACH_HTTP_CODE): $(cat "$ATTACH_BODY_FILE")" >&2
  fi
  rm -f "$ATTACH_BODY_FILE"
fi

# Upload a local file (e.g. a run report markdown) as a native Asana attachment.
# This is a real file upload to the task, distinct from --attach-pr (the GitHub widget).
if $DO_ATTACH_FILE; then
  if [[ ! -f "$ATTACH_FILE_PATH" ]]; then
    echo "Error: --attach-file path not found: $ATTACH_FILE_PATH" >&2
    exit 1
  fi
  FORM_SPEC="file=@${ATTACH_FILE_PATH};type=text/markdown"
  [[ -n "$ATTACH_FILE_NAME" ]] && FORM_SPEC="${FORM_SPEC};filename=${ATTACH_FILE_NAME}"
  if FILE_ATTACH_OUT=$(curl -sf -X POST "$ASANA_API/tasks/$TASK_GID/attachments" \
      -H "Authorization: Bearer $ASANA_TOKEN" \
      -F "$FORM_SPEC" 2>/dev/null); then
    echo ">> File attach: $(echo "$FILE_ATTACH_OUT" | jq -r '.data.name // "attachment"')"
  else
    echo ">> File attach: FAILED ($ATTACH_FILE_PATH)" >&2
    exit 1
  fi
fi

if $DO_ASSIGN || [[ -n "$SET_REVIEWER_GID" ]] || [[ -n "$SET_IMPLEMENTOR_GID" ]] || $AUTO_EST_REVIEW || [[ -n "$SET_PRIORITY_GID" ]] || [[ -n "$SET_PLANNED_GID" ]]; then
  load_task_fields
fi

if $DO_ASSIGN; then
  if [[ -z "$ASSIGN_GID" ]]; then
    ASSIGN_GID="${SET_REVIEWER_GID:-$(read_people_field "$REVIEWER_FIELD")}"
  fi
  if [[ -z "$ASSIGN_GID" ]]; then
    if $SKIP_ASSIGN_IF_MISSING; then
      echo ">> Assignee: skipped (no reviewer provided or found on task)"
      DO_ASSIGN=false
    else
      echo ">> PROMPT_REVIEWER"
      exit 2
    fi
  fi

  if $DO_ASSIGN; then
    if [[ -z "$SET_REVIEWER_GID" ]]; then
      SET_REVIEWER_GID="$ASSIGN_GID"
    fi

    if [[ -z "$SET_IMPLEMENTOR_GID" ]]; then
      SET_IMPLEMENTOR_GID="$(read_people_field "$IMPLEMENTOR_FIELD")"
    fi
    if [[ -z "$SET_IMPLEMENTOR_GID" ]]; then
      SET_IMPLEMENTOR_GID="$("$SCRIPT_DIR/../../asana-whoami.sh" 2>/dev/null || true)"
      if [[ -n "$SET_IMPLEMENTOR_GID" ]]; then
        echo ">> Implementor: auto-resolved to current user ($SET_IMPLEMENTOR_GID)"
      fi
    fi
    if [[ -z "$SET_IMPLEMENTOR_GID" ]]; then
      echo ">> PROMPT_IMPLEMENTOR"
      exit 2
    fi
  fi
fi

CUSTOM_FIELDS_PATCH='{}'

if [[ -n "$SET_STATUS" ]]; then
  STATUS_GID="$(status_to_gid "$SET_STATUS")"
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$STATUS_FIELD" --arg v "$STATUS_GID" '. + {($k): $v}')
fi
if [[ -n "$SET_BOARD_STATE" ]]; then
  BOARD_STATE_GID="$(board_state_to_gid "$SET_BOARD_STATE")"
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$BOARD_STATE_FIELD" --arg v "$BOARD_STATE_GID" '. + {($k): $v}')
fi
if [[ -n "$SET_REVIEWER_GID" ]]; then
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$REVIEWER_FIELD" --arg v "$SET_REVIEWER_GID" '. + {($k): [$v]}')
fi
if [[ -n "$SET_IMPLEMENTOR_GID" ]]; then
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$IMPLEMENTOR_FIELD" --arg v "$SET_IMPLEMENTOR_GID" '. + {($k): [$v]}')
fi
if [[ -n "$SET_PRIORITY_GID" ]]; then
  PRIORITY_FIELD_GID=$(echo "$TASK_FIELDS" | jq -r '.data.custom_fields[] | select(.name == "Priority") | .gid' | head -n 1)
  if [[ -n "$PRIORITY_FIELD_GID" ]]; then
    CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$PRIORITY_FIELD_GID" --arg v "$SET_PRIORITY_GID" '. + {($k): $v}')
  fi
fi
if [[ -n "$SET_PLANNED_GID" ]]; then
  PLANNED_FIELD_GID=$(echo "$TASK_FIELDS" | jq -r '.data.custom_fields[] | select(.name == "Planned") | .gid' | head -n 1)
  if [[ -n "$PLANNED_FIELD_GID" ]]; then
    CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$PLANNED_FIELD_GID" --arg v "$SET_PLANNED_GID" '. + {($k): $v}')
  fi
fi

UPDATE_BODY='{"data":{}}'
HAS_UPDATE=false

if [[ "$CUSTOM_FIELDS_PATCH" != "{}" ]]; then
  UPDATE_BODY=$(echo "$UPDATE_BODY" | jq --argjson cf "$CUSTOM_FIELDS_PATCH" '.data.custom_fields = $cf')
  HAS_UPDATE=true
fi

if $DO_UNASSIGN; then
  UPDATE_BODY=$(echo "$UPDATE_BODY" | jq '.data.assignee = null')
  HAS_UPDATE=true
elif $DO_ASSIGN; then
  UPDATE_BODY=$(echo "$UPDATE_BODY" | jq --arg a "$ASSIGN_GID" '.data.assignee = $a')
  HAS_UPDATE=true
fi

if $HAS_UPDATE; then
  curl -sf -X PUT "$ASANA_API/tasks/$TASK_GID" \
    -H "Authorization: Bearer $ASANA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$UPDATE_BODY" > /dev/null
  echo ">> Task fields: updated"
fi

if $DO_ASSIGN; then
  echo ">> Assigned to reviewer: $ASSIGN_GID"
fi
if $DO_UNASSIGN; then
  echo ">> Assignee: unset"
fi
if [[ -n "$SET_STATUS" ]]; then
  echo ">> Status: $SET_STATUS"
fi
if [[ -n "$SET_BOARD_STATE" ]]; then
  echo ">> Board State: $SET_BOARD_STATE"
fi
if [[ -n "$SET_REVIEWER_GID" ]]; then
  echo ">> Reviewer field: set"
fi
if [[ -n "$SET_IMPLEMENTOR_GID" ]]; then
  echo ">> Implementor field: set"
fi
if [[ -n "$SET_PRIORITY_GID" ]]; then
  echo ">> Priority field: set"
fi
if [[ -n "$SET_PLANNED_GID" ]]; then
  echo ">> Planned field: set"
fi

if $AUTO_EST_REVIEW; then
  load_task_fields
  EST_REVIEW=$(echo "$TASK_FIELDS" | jq -r --arg gid "$EST_REVIEW_HRS_FIELD" '.data.custom_fields[] | select(.gid == $gid) | (.number_value // empty)' | head -n 1)
  if [[ -n "$EST_REVIEW" ]]; then
    echo ">> Est. Review Hrs: already set ($EST_REVIEW)"
  else
    SPENT_DEV=$(echo "$TASK_FIELDS" | jq -r --arg gid "$SPENT_DEV_HRS_FIELD" '.data.custom_fields[] | select(.gid == $gid) | (.number_value // empty)' | head -n 1)
    if [[ -z "$SPENT_DEV" ]]; then
      echo ">> Est. Review Hrs: skipped (no Spent Dev Hrs)"
    else
      EST_VAL=$(python3 -c "v=float('$SPENT_DEV'); x=round(v*0.1,1); print(x if x >= 0.1 else 0.1)")
      REVIEW_PATCH=$(jq -n --arg f "$EST_REVIEW_HRS_FIELD" --argjson v "$EST_VAL" '{data:{custom_fields:{($f):$v}}}')
      curl -sf -X PUT "$ASANA_API/tasks/$TASK_GID" \
        -H "Authorization: Bearer $ASANA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$REVIEW_PATCH" > /dev/null
      echo ">> Est. Review Hrs: set to $EST_VAL (10% of Spent Dev Hrs)"
    fi
  fi
fi
