#!/usr/bin/env bash
# asana-task-update.sh
# Unified Asana task mutation script.
#
# Exit codes:
#   0 = success
#   1 = error
#   2 = needs user input (PROMPT_REVIEWER, or the QA-subtask gate below)
#
# Manual QA subtasks: a subtask titled "QA: <what a human verifies>" is a manual
# verification item for the QA handoff, not scope. asana-get-context.sh hides
# these from every run's ingestion, so an orchestrated run never plans from
# them. --create-subtask --subtask-name "QA: ..." --subtask-notes <file> makes
# one (plain notes, verbatim; the CURRENT STATE section is never written on a
# subtask). --set-board-state "QA Verification" refuses (exit 2) when the task
# has no open QA: subtask, unless --no-manual-qa "<why nothing needs a human>"
# is passed; the reason is posted as a comment so QA sees why the list is empty.
set -euo pipefail

QA_SUBTASK_PREFIX="QA: "

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

SET_BOARD_STATE=""
SET_PRIORITY=""
SET_RELEASE=""
SET_DEVELOPER_GID=""

CREATE_SUBTASK=false
SUBTASK_NAME=""
SUBTASK_NOTES_FILE=""
NO_MANUAL_QA=""

SET_CURRENT_STATE_FILE=""

COMMENT_FILE=""
EDIT_COMMENT_GID=""
DELETE_COMMENT_GID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_GID="$2"; shift 2 ;;
    --create-subtask) CREATE_SUBTASK=true; shift ;;
    --subtask-name) SUBTASK_NAME="$2"; shift 2 ;;
    --subtask-notes) SUBTASK_NOTES_FILE="$2"; shift 2 ;;
    --no-manual-qa) NO_MANUAL_QA="$2"; shift 2 ;;
    --attach-pr) DO_ATTACH=true; shift ;;
    --pr-url) PR_URL="$2"; shift 2 ;;
    --pr-title) PR_TITLE="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --attach-file) DO_ATTACH_FILE=true; ATTACH_FILE_PATH="$2"; shift 2 ;;
    --set-current-state) SET_CURRENT_STATE_FILE="$2"; shift 2 ;;
    --comment-file) COMMENT_FILE="$2"; shift 2 ;;
    --edit-comment) EDIT_COMMENT_GID="$2"; shift 2 ;;
    --delete-comment) DELETE_COMMENT_GID="$2"; shift 2 ;;
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
    --set-board-state) SET_BOARD_STATE="$2"; shift 2 ;;
    --set-priority) SET_PRIORITY="$2"; shift 2 ;;
    --set-release) SET_RELEASE="$2"; shift 2 ;;
    --set-developer) SET_DEVELOPER_GID="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TASK_GID" ]]; then
  echo "Error: --task <task_gid> is required" >&2
  exit 1
fi

if ! $CREATE_SUBTASK && ! $DO_ATTACH && ! $DO_ATTACH_FILE && ! $DO_ASSIGN && ! $DO_UNASSIGN && [[ -z "$SET_BOARD_STATE" ]] && [[ -z "$SET_PRIORITY" ]] && [[ -z "$SET_RELEASE" ]] && [[ -z "$SET_DEVELOPER_GID" ]] && [[ -z "$SET_CURRENT_STATE_FILE" ]] && [[ -z "$COMMENT_FILE" ]] && [[ -z "$DELETE_COMMENT_GID" ]] && [[ -z "$EDIT_COMMENT_GID" ]]; then
  echo "Error: No operations specified" >&2
  exit 1
fi

# --edit-comment and --delete-comment each act on ONE story, so they never pair
# with each other, and --edit-comment carries its new body in --comment-file
# (which otherwise means "post a new comment" — the pairing is what selects PUT
# over POST).
if [[ -n "$EDIT_COMMENT_GID" && -n "$DELETE_COMMENT_GID" ]]; then
  echo "Error: --edit-comment and --delete-comment are mutually exclusive" >&2
  exit 1
fi
if [[ -n "$EDIT_COMMENT_GID" && -z "$COMMENT_FILE" ]]; then
  echo "Error: --edit-comment <story_gid> requires --comment-file <path> (the replacement body)" >&2
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
# Exported so child helpers (asana-whoami.sh for implementor resolution) see a
# token that came from credentials.json rather than the environment.
export ASANA_TOKEN

# Widget secret: prefer $ASANA_GITHUB_SECRET, else fall back to credentials.json
# (mirrors the token fallback — spawned shells may not have it exported).
if [[ -z "${ASANA_GITHUB_SECRET:-}" ]]; then
  CRED="$HOME/.config/agent-watcher/credentials.json"
  [[ -f "$CRED" ]] && ASANA_GITHUB_SECRET="$(jq -r '.asana_github_secret // empty' "$CRED" 2>/dev/null)"
fi
# --attach-pr is OPTIONAL on a workspace where the Asana ↔ GitHub widget
# integration is disabled. If the secret is still missing, skip the widget call
# with a warning rather than failing — the canonical Asana ↔ PR link lives in the
# PR body (injected by /pr-create) and downstream skills do not need the widget.
if $DO_ATTACH && [[ -z "${ASANA_GITHUB_SECRET:-}" ]]; then
  echo ">> PR attach: skipped (ASANA_GITHUB_SECRET not set; widget integration not configured)" >&2
  DO_ATTACH=false
fi

ASANA_API="https://app.asana.com/api/1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# asana_request <label> <curl args...>
# Runs one Asana API call and leaves the response body in ASANA_RESPONSE.
# Returns 0 on a 2xx. Otherwise prints ">> <label>: FAILED (HTTP <code>): <why>"
# to stderr, where <why> is Asana's errors[].message (else the raw body, else
# curl's own error), and returns 1; callers exit 1.
# Use it instead of a bare `curl -sf`: on an HTTP/2 connection the system curl
# reports an HTTP 4xx under -f as exit 56 (not 22) and discards the body, so an
# unguarded `curl -sf` under `set -e` ended the script with a bare 56 and no hint
# of what Asana refused.
ASANA_RESPONSE=""
asana_request() {
  local label="$1"; shift
  local out err code rc=0 why
  out="$(mktemp)"; err="$(mktemp)"
  code="$(curl -sS -o "$out" -w '%{http_code}' "$@" 2>"$err")" || rc=$?
  ASANA_RESPONSE="$(cat "$out" 2>/dev/null || true)"
  if [[ $rc -eq 0 && "$code" =~ ^2[0-9][0-9]$ ]]; then
    rm -f "$out" "$err"
    return 0
  fi
  why="$(printf '%s' "$ASANA_RESPONSE" | jq -r '[.errors[]?.message // empty] | join("; ")' 2>/dev/null || true)"
  [[ -n "$why" ]] || why="$(printf '%s' "$ASANA_RESPONSE" | tr '\n' ' ')"
  [[ -n "$why" ]] || why="$(tr '\n' ' ' < "$err")"
  local curl_note=""
  [[ $rc -ne 0 ]] && curl_note=", curl exit $rc"
  echo ">> $label: FAILED (HTTP ${code:-000}${curl_note}): ${why:0:800}" >&2
  rm -f "$out" "$err"
  return 1
}

# The one line separating operator prose from the agent-maintained tail of a
# task description. Owned here so every writer agrees on the byte-exact literal;
# `--set-current-state` replaces everything from this line down and never touches
# what sits above it.
# Matched ANYWHERE on a line, not only at column 1: an authorship marker (🥋)
# prepended to the delimiter line must not hide a stale section from the strip.
CURRENT_STATE_DELIM="===== CURRENT STATE (agent-maintained; supersedes any stale prose above) ====="

# --create-subtask: create a subtask under --task, print its gid, and re-point
# TASK_GID to it so any --attach-pr/--set-board-state in the SAME invocation lands on
# the new subtask (one call: make the per-PR subtask AND attach its PR).
if $CREATE_SUBTASK; then
  [[ -n "$SUBTASK_NAME" ]] || { echo "Error: --create-subtask requires --subtask-name" >&2; exit 1; }
  SUB_NOTES=""
  if [[ -n "$SUBTASK_NOTES_FILE" ]]; then
    [[ -f "$SUBTASK_NOTES_FILE" ]] || { echo "Error: --subtask-notes file not found: $SUBTASK_NOTES_FILE" >&2; exit 1; }
    SUB_NOTES="$(cat "$SUBTASK_NOTES_FILE")"
    # A subtask body is plain notes for a human; the agent-maintained CURRENT
    # STATE section belongs to the parent task only.
    if grep -qF "CURRENT STATE" "$SUBTASK_NOTES_FILE"; then
      echo "Error: --subtask-notes must not carry a CURRENT STATE section (write plain steps and expected results)" >&2; exit 1
    fi
  fi
  SUB_GID="$(jq -n --arg n "$SUBTASK_NAME" --arg notes "$SUB_NOTES" '{data: ({name: $n} + (if $notes == "" then {} else {notes: $notes} end))}' \
    | curl -sS -X POST "$ASANA_API/tasks/$TASK_GID/subtasks" \
    -H "Authorization: Bearer $ASANA_TOKEN" -H "Content-Type: application/json" -d @- \
    | jq -r '.data.gid // empty')"
  [[ -n "$SUB_GID" ]] || { echo "Error: failed to create subtask under $TASK_GID" >&2; exit 1; }
  echo ">> subtask created: $SUB_GID ($SUBTASK_NAME)"
  TASK_GID="$SUB_GID"
fi

# Engineering Board field gids. Only Engineering and jon-claude fields are
# written here: a task GET also lists workspace-global fields from other boards
# (the old Status / Reviewer / Implementor / Planned set), and Asana refuses a
# whole PUT that names a field outside the task's projects.
BOARD_STATE_FIELD="1213992584300456"
PRIORITY_FIELD="1213843686985522"
RELEASE_FIELD="1213939602865824"
DEVELOPER_FIELD="1214028561571290"

# Resolve an enum option to its gid by NAME, from the field's OWN enum_options
# on this task. Never from a hand-maintained table: the operator adds and renames
# options in Asana, a table goes stale silently, and the old fallback passed an
# unknown name through AS a gid, so a new or misspelled option became a malformed
# API write instead of an error. Matching ignores case, surrounding whitespace,
# and a leading emoji run, so only the words have to hold.
#
# Accepts either an option NAME or an option GID (an all-digits value, which no
# option name ever is) — callers that copy a field between tasks already hold the
# gid. Either way the value is VALIDATED against the field's live options, so a
# gid from a deleted or foreign option is an error rather than a malformed write.
#
# Usage: enum_option_gid <field_gid> <field_label> <option-name-or-gid>
# stdout: the option gid. Exit 1 with the field's real options on no match.
normalize_option_name() {
  printf '%s' "$1" | sed -E 's/^[^[:alnum:]]+//; s/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]'
}

enum_option_gid() {
  local field_gid="$1" field_label="$2" want_raw="$3" want gid options
  load_task_fields

  if [[ "$want_raw" =~ ^[0-9]+$ ]]; then
    gid="$(printf '%s' "$TASK_FIELDS" | jq -r --arg f "$field_gid" --arg w "$want_raw" '
      .data.custom_fields[]? | select(.gid == $f) | .enum_options[]?
      | select(.gid == $w) | .gid' | head -n 1)"
    if [[ -n "$gid" ]]; then
      printf '%s' "$gid"
      return 0
    fi
  fi

  want="$(normalize_option_name "$want_raw")"

  gid="$(printf '%s' "$TASK_FIELDS" | jq -r --arg f "$field_gid" --arg w "$want" '
    .data.custom_fields[]? | select(.gid == $f) | .enum_options[]?
    | select((.name // "")
        | sub("^[^\\p{L}\\p{N}]+"; "") | sub("^\\s+"; "") | sub("\\s+$"; "") | ascii_downcase
        == $w)
    | .gid' | head -n 1)"
  if [[ -n "$gid" ]]; then
    printf '%s' "$gid"
    return 0
  fi

  options="$(printf '%s' "$TASK_FIELDS" | jq -r --arg f "$field_gid" '
    [.data.custom_fields[]? | select(.gid == $f) | .enum_options[]?.name] | join(", ")')"
  if [[ -z "$options" ]]; then
    echo "Error: field \"$field_label\" ($field_gid) is not on task $TASK_GID, or carries no enum options" >&2
  else
    echo "Error: \"$want_raw\" is not an option (by name or gid) of \"$field_label\" on task $TASK_GID; options are: $options" >&2
  fi
  return 1
}

TASK_FIELDS=""
load_task_fields() {
  if [[ -n "$TASK_FIELDS" ]]; then
    return 0
  fi
  asana_request "Task read" "$ASANA_API/tasks/$TASK_GID?opt_fields=name,assignee.name,memberships.project.gid,custom_fields.gid,custom_fields.name,custom_fields.people_value.gid,custom_fields.people_value.name,custom_fields.number_value,custom_fields.enum_value.gid,custom_fields.enum_value.name,custom_fields.enum_options.gid,custom_fields.enum_options.name" \
    -H "Authorization: Bearer $ASANA_TOKEN" || exit 1
  TASK_FIELDS="$ASANA_RESPONSE"
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

# assert_own_comment <story_gid>
# Gate for --edit-comment / --delete-comment: Asana only lets a comment's own
# author rewrite or remove it, and the API answers a violation with a bare 403.
# Checking first turns that into a specific refusal, and rules out the two
# mistakes a gid typo actually produces: acting on a SYSTEM story (an
# assignment, a field change — those are the task's audit trail and are not
# ours to erase) or on a comment belonging to a different task than --task.
assert_own_comment() {
  local sgid="$1" subtype target author me
  asana_request "Comment $sgid" -X GET \
    "$ASANA_API/stories/$sgid?opt_fields=resource_subtype,created_by.gid,target.gid" \
    -H "Authorization: Bearer $ASANA_TOKEN" || exit 1
  subtype="$(printf '%s' "$ASANA_RESPONSE" | jq -r '.data.resource_subtype // empty')"
  target="$(printf '%s' "$ASANA_RESPONSE" | jq -r '.data.target.gid // empty')"
  author="$(printf '%s' "$ASANA_RESPONSE" | jq -r '.data.created_by.gid // empty')"
  if [[ "$subtype" != "comment_added" ]]; then
    echo ">> Comment $sgid: REFUSED (story is '${subtype:-unknown}', not a comment; system stories are the task's audit trail)" >&2
    exit 1
  fi
  if [[ "$target" != "$TASK_GID" ]]; then
    echo ">> Comment $sgid: REFUSED (belongs to task ${target:-unknown}, not --task $TASK_GID)" >&2
    exit 1
  fi
  me="$("$SCRIPT_DIR/../../asana-whoami.sh" 2>/dev/null || true)"
  if [[ -n "$me" && "$author" != "$me" ]]; then
    echo ">> Comment $sgid: REFUSED (authored by ${author:-unknown}, not this token's user $me; Asana allows neither an edit nor a delete of someone else's comment)" >&2
    exit 1
  fi
}

# --delete-comment <story_gid>: remove one of our own comments. Runs BEFORE the
# post/edit path so a single call can retire a wrong comment and leave the
# replacement as the newest story.
if [[ -n "$DELETE_COMMENT_GID" ]]; then
  assert_own_comment "$DELETE_COMMENT_GID"
  asana_request "Comment delete" -X DELETE "$ASANA_API/stories/$DELETE_COMMENT_GID" \
    -H "Authorization: Bearer $ASANA_TOKEN" || exit 1
  # Drop it from the own-stories ledger: a deleted comment must stop counting as
  # the run's own when require-followup-scope-on-complete.sh separates the run's
  # comments from operator scope.
  LEDGER="/tmp/agent-own-stories-$TASK_GID"
  if [[ -f "$LEDGER" ]]; then
    grep -vxF "$DELETE_COMMENT_GID" "$LEDGER" > "$LEDGER.tmp" 2>/dev/null || true
    mv "$LEDGER.tmp" "$LEDGER" 2>/dev/null || rm -f "$LEDGER.tmp"
  fi
  echo ">> Comment: deleted story $DELETE_COMMENT_GID from task $TASK_GID"
fi

# --comment-file <path>: post the file's text as a task comment. Runs BEFORE
# --attach-file so a single call that does both keeps the watermark order the
# one-shot report-as-attachment rule requires (comment first, report last).
# The text is marked via agent-authored-text.sh (orch runs only), rejected when
# it narrates a reviewer-bot outage (same boundary mark-agent-authored-asana.sh
# enforces on the MCP path), and the created story gid is appended to
# /tmp/agent-own-stories-<gid> for in-flight orch runs commenting on their own
# task, so require-followup-scope-on-complete.sh can tell the run's own
# comments from operator scope that arrived after its check.
if [[ -n "$COMMENT_FILE" ]]; then
  [[ -f "$COMMENT_FILE" ]] || { echo "Error: --comment-file not found: $COMMENT_FILE" >&2; exit 1; }
  CM_BODY="$(cat "$COMMENT_FILE")"
  [[ -n "${CM_BODY//[[:space:]]/}" ]] || { echo "Error: --comment-file is empty: $COMMENT_FILE" >&2; exit 1; }
  CM_ORCH=false
  "$HOME/.config/agent-watcher/orch-run-context.sh" 2>/dev/null && CM_ORCH=true
  CM_NOISE_LIB="$HOME/.config/agent-watcher/hooks/lib/reviewer-outage-noise.sh"
  if $CM_ORCH && [[ -f "$CM_NOISE_LIB" ]]; then
    . "$CM_NOISE_LIB"
    CM_NOISE="$(reviewer_noise_hits "$COMMENT_FILE" | head -4 || true)"
    if [[ -n "$CM_NOISE" ]]; then
      echo ">> Comment: REJECTED (reviewer-bot outage narration; that state is one unchecked box in the run report's Finalize Gate and appears nowhere else). Remove these lines and retry:" >&2
      printf '%s\n' "$CM_NOISE" | sed 's/^/    /' >&2
      exit 1
    fi
  fi
  CM_MARKER="$HOME/.config/agent-watcher/agent-authored-text.sh"
  if [[ -x "$CM_MARKER" ]]; then
    CM_BODY="$(printf '%s' "$CM_BODY" | "$CM_MARKER")"
  fi
  CM_PAYLOAD="$(jq -n --arg t "$CM_BODY" '{data:{text:$t}}')"
  if [[ -n "$EDIT_COMMENT_GID" ]]; then
    # Editing replaces the body of an EXISTING story, so the gid does not
    # change and the ledger already holds it.
    assert_own_comment "$EDIT_COMMENT_GID"
    asana_request "Comment edit" -X PUT "$ASANA_API/stories/$EDIT_COMMENT_GID" \
      -H "Authorization: Bearer $ASANA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$CM_PAYLOAD" || exit 1
    echo ">> Comment: edited story $EDIT_COMMENT_GID on task $TASK_GID"
  elif CM_OUT=$(curl -sf -X POST "$ASANA_API/tasks/$TASK_GID/stories" \
      -H "Authorization: Bearer $ASANA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$CM_PAYLOAD" 2>/dev/null); then
    CM_GID="$(printf '%s' "$CM_OUT" | jq -r '.data.gid // empty' 2>/dev/null || true)"
    if $CM_ORCH && [[ -n "$CM_GID" && "$TASK_GID" == "${AGENT_TASK_GID:-}" ]]; then
      printf '%s\n' "$CM_GID" >> "/tmp/agent-own-stories-$TASK_GID"
    fi
    echo ">> Comment: posted to task $TASK_GID (story ${CM_GID:-unknown})"
  else
    echo ">> Comment: FAILED (POST rejected for task $TASK_GID)" >&2
    exit 1
  fi
fi

# Upload a local file (e.g. a run report markdown) as a native Asana attachment.
# This is a real file upload to the task, distinct from --attach-pr (the GitHub widget).
#
# Same-name handling, by kind (names from lib/attach-names.sh):
#   run report  REPLACE: a corrected report re-attached under the report NAME
#               FAMILY (same slug, ordinal-insensitive) must land (it moves the
#               followup watermark), so upload first, and only after the upload succeeds
#               DELETE every older same-name attachment. Upload failure exits 1
#               with the old report still attached; a failed delete only warns
#               (a duplicate is acceptable, zero reports never is). Guard: only
#               attachments created at or after THIS segment's start (newest
#               versions/<gid>.jsonl stamp, the same source check-followup-scope.sh
#               uses) are replaced; an older segment's report is never deleted,
#               so that case keeps the skip below and says why.
#               NAME FAMILY: the attach gate re-numbers --attach-name after the
#               caller wrote it (agent-run-report.md -> <N>-agent-run-report.md),
#               so an exact-string compare finds nothing and the task keeps BOTH
#               docs. Match the ordinal-stripped name instead. Two DIFFERENT
#               explicit ordinals stay different docs (a re-number always goes
#               bare -> numbered), so a fresh ordinal still uploads beside the
#               segment's earlier report rather than deleting it.
#   plan        dedupe by <anything> suffix (a retry never mints a second ordinal).
#   other       dedupe by exact name (a double-invoke creates no duplicate).
if $DO_ATTACH_FILE; then
  if [[ ! -f "$ATTACH_FILE_PATH" ]]; then
    echo "Error: --attach-file path not found: $ATTACH_FILE_PATH" >&2
    exit 1
  fi
  DEDUPE_NAME="${ATTACH_FILE_NAME:-$(basename "$ATTACH_FILE_PATH")}"
  ATTACH_LIST=$(curl -sf "$ASANA_API/tasks/$TASK_GID/attachments?opt_fields=name,created_at" \
      -H "Authorization: Bearer $ASANA_TOKEN" 2>/dev/null || true)
  ATTACH_NAMES=$(printf '%s' "$ATTACH_LIST" | jq -r '.data[]? | .name' 2>/dev/null || true)
  EXISTING_ATTACH=$(printf '%s\n' "$ATTACH_NAMES" | grep -Fx -- "$DEDUPE_NAME" | head -1 || true)
  # Off-orch machines (skills synced without the orch lib) keep plain names.
  source "$HOME/.config/agent-watcher/lib/attach-names.sh" 2>/dev/null || true
  if [[ -n "${PLAN_ATTACH_RE:-}" && "$DEDUPE_NAME" =~ $PLAN_ATTACH_RE ]]; then
    PLAN_SUFFIX=$(plan_attach_suffix "$DEDUPE_NAME")
    EXISTING_ATTACH=$(printf '%s\n' "$ATTACH_NAMES" | grep -E "$PLAN_ATTACH_RE" | while read -r n; do
        [[ "$(plan_attach_suffix "$n")" == "$PLAN_SUFFIX" ]] && echo "$n"; done | head -1 || true)
    if [[ -z "$EXISTING_ATTACH" ]]; then
      ATTACH_FILE_NAME=$(plan_attach_name "$(printf '%s\n' "$ATTACH_NAMES" | next_attach_ordinal plan)" "$DEDUPE_NAME")
      DEDUPE_NAME="$ATTACH_FILE_NAME"
    fi
  fi

  # Report name family: same slug, ordinal-insensitive (see header). The two
  # readers below stay local until attach-names.sh grows a report_attach_suffix.
  report_name_suffix() { printf '%s\n' "$1" | sed -E 's/^[0-9]+-//; s/^agent-run-report-?//; s/^[0-9]+-//'; }
  report_name_ordinal() { printf '%s\n' "$1" | sed -nE 's/^([0-9]+)-agent-run-report.*/\1/p; s/^agent-run-report-([0-9]+)-.*/\1/p' | head -1 | sed -E 's/^0+//'; }
  REPORT_FAMILY=""
  if [[ -n "${REPORT_ATTACH_RE:-}" && "$DEDUPE_NAME" =~ $REPORT_ATTACH_RE ]]; then
    WANT_SUFFIX=$(report_name_suffix "$DEDUPE_NAME")
    WANT_ORD=$(report_name_ordinal "$DEDUPE_NAME")
    # A bare (ordinal-less) report is a PRE-SCHEME doc. It is the same document
    # as a numbered request only while the task carries no numbered report at
    # all; once any numbered report exists (<N>-agent-run-report.md or the legacy
    # agent-run-report-<N>-<slug>.md, whatever its suffix) the bare one belongs
    # to an earlier segment, so it must neither be replaced nor block the new
    # ordinal.
    HAVE_NUMBERED=$(printf '%s\n' "$ATTACH_NAMES" | grep -E "$REPORT_ATTACH_RE" | while read -r n; do
        if [[ -n "$(report_name_ordinal "$n")" ]]; then echo yes; fi
      done | grep -m1 yes || true)
    REPORT_FAMILY=$(printf '%s\n' "$ATTACH_NAMES" | grep -E "$REPORT_ATTACH_RE" | while read -r n; do
        [[ "$(report_name_suffix "$n")" == "$WANT_SUFFIX" ]] || continue
        HAVE_ORD=$(report_name_ordinal "$n")
        if [[ -z "$HAVE_ORD" && -n "$WANT_ORD" && -n "$HAVE_NUMBERED" ]]; then continue; fi
        [[ -z "$HAVE_ORD" || -z "$WANT_ORD" || "$HAVE_ORD" == "$WANT_ORD" ]] && echo "$n"
      done | grep -v '^$' || true)
    [[ -n "$REPORT_FAMILY" ]] && EXISTING_ATTACH=$(printf '%s\n' "$REPORT_FAMILY" | head -1)
  fi

  REPLACE_GIDS=""
  if [[ -n "$EXISTING_ATTACH" && -n "$REPORT_FAMILY" ]]; then
    SEG_START=""
    VERSIONS_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions/$TASK_GID.jsonl"
    [[ -f "$VERSIONS_FILE" ]] && SEG_START=$(jq -rs '[.[] | .ts // empty] | last // empty' "$VERSIONS_FILE" 2>/dev/null || true)
    # Fractional seconds stripped on both sides so the ISO strings compare lexically.
    FAMILY_JSON=$(printf '%s\n' "$REPORT_FAMILY" | grep -v '^$' | jq -Rsc 'split("\n") | map(select(. != ""))' 2>/dev/null || echo '[]')
    SAME_NAME=$(printf '%s' "$ATTACH_LIST" | jq -c --argjson f "$FAMILY_JSON" --arg s "${SEG_START%%.*}" '
        def norm: (. // "") | sub("\\.[0-9]+Z$"; "Z");
        [.data[]? | select(.name as $n | $f | index($n)) | {gid, name, created_at, in_seg: (($s | sub("Z$"; "")) as $ss | ($ss != "") and ((.created_at | norm) >= ($ss + "Z")))}]' 2>/dev/null || echo "[]")
    OLDER_SEG=$(printf '%s' "$SAME_NAME" | jq -r '[.[] | select(.in_seg | not)] | length' 2>/dev/null || echo 1)
    if [[ -z "$SEG_START" ]]; then
      echo ">> File attach: skipped, '$EXISTING_ATTACH' already attached to task $TASK_GID and no segment start is recorded (versions/$TASK_GID.jsonl), so it cannot be proven this segment's report; not replacing"
    elif [[ "$OLDER_SEG" != "0" ]]; then
      echo ">> File attach: skipped, '$EXISTING_ATTACH' on task $TASK_GID was attached before this segment started ($SEG_START); an older segment's report is never replaced. Fix the report's iteration so it attaches under a new ordinal"
    else
      REPLACE_GIDS=$(printf '%s' "$SAME_NAME" | jq -r '.[].gid' 2>/dev/null || true)
      [[ -n "$REPLACE_GIDS" ]] || echo ">> File attach: skipped, '$EXISTING_ATTACH' already attached to task $TASK_GID but its gid could not be read; not replacing"
    fi
  elif [[ -n "$EXISTING_ATTACH" ]]; then
    echo ">> File attach: skipped, '$DEDUPE_NAME' already attached to task $TASK_GID (dedupe)"
  fi

  if [[ -z "$EXISTING_ATTACH" || -n "$REPLACE_GIDS" ]]; then
    FORM_SPEC="file=@${ATTACH_FILE_PATH};type=text/markdown"
    [[ -n "$ATTACH_FILE_NAME" ]] && FORM_SPEC="${FORM_SPEC};filename=${ATTACH_FILE_NAME}"
    if FILE_ATTACH_OUT=$(curl -sf -X POST "$ASANA_API/tasks/$TASK_GID/attachments" \
        -H "Authorization: Bearer $ASANA_TOKEN" \
        -F "$FORM_SPEC" 2>/dev/null); then
      NEW_ATTACH_GID=$(printf '%s' "$FILE_ATTACH_OUT" | jq -r '.data.gid // empty' 2>/dev/null || true)
    else
      NEW_ATTACH_GID=""
      FILE_ATTACH_OUT=""
    fi
    if [[ -n "$REPLACE_GIDS" ]]; then
      if [[ -z "$NEW_ATTACH_GID" ]]; then
        echo ">> File attach: FAILED ($ATTACH_FILE_PATH); the existing '$DEDUPE_NAME' is still attached" >&2
        exit 1
      fi
      DELETED=""
      for OLD_GID in $REPLACE_GIDS; do
        if curl -sf -X DELETE "$ASANA_API/attachments/$OLD_GID" \
            -H "Authorization: Bearer $ASANA_TOKEN" > /dev/null 2>&1; then
          DELETED="${DELETED:+$DELETED,}$OLD_GID"
        else
          echo ">> WARN: uploaded $NEW_ATTACH_GID but could not delete older '$DEDUPE_NAME' ($OLD_GID); the task now carries a duplicate" >&2
        fi
      done
      echo ">> File attach: replaced ${DELETED:-none}->$NEW_ATTACH_GID ($DEDUPE_NAME)"
    elif [[ -n "$FILE_ATTACH_OUT" ]]; then
      echo ">> File attach: $(echo "$FILE_ATTACH_OUT" | jq -r '.data.name // "attachment"')"
    else
      echo ">> File attach: FAILED ($ATTACH_FILE_PATH)" >&2
      exit 1
    fi
  fi
fi

# --assign with no gid has no field to read a reviewer from (the Engineering
# Board has none), so it asks, or skips under --skip-assign-if-missing.
if $DO_ASSIGN && [[ -z "$ASSIGN_GID" ]]; then
  if $SKIP_ASSIGN_IF_MISSING; then
    echo ">> Assignee: skipped (no assignee gid provided)"
    DO_ASSIGN=false
  else
    echo ">> PROMPT_REVIEWER"
    exit 2
  fi
fi

CUSTOM_FIELDS_PATCH='{}'

# QA handoff gate: the move to QA Verification is where the manual verification
# list must already exist as "QA: ..." subtasks (pr-land qa-subtasks-before-handoff).
if [[ "$SET_BOARD_STATE" == "QA Verification" ]]; then
  QA_OPEN="$(curl -sS "$ASANA_API/tasks/$TASK_GID/subtasks?opt_fields=name,completed" \
    -H "Authorization: Bearer $ASANA_TOKEN" \
    | jq --arg p "$QA_SUBTASK_PREFIX" '[.data[]? | select((.completed | not) and (.name | startswith($p)))] | length')"
  if [[ "${QA_OPEN:-0}" -eq 0 && -z "$NO_MANUAL_QA" ]]; then
    echo "QA_SUBTASKS_REQUIRED: task $TASK_GID has no open '${QA_SUBTASK_PREFIX}...' subtask. Create one per manual verification item (--create-subtask --subtask-name \"${QA_SUBTASK_PREFIX}<what a human checks>\" --subtask-notes <file>) before --set-board-state \"QA Verification\", or pass --no-manual-qa \"<why nothing needs a human>\"." >&2
    exit 2
  fi
  if [[ "${QA_OPEN:-0}" -eq 0 && -n "$NO_MANUAL_QA" ]]; then
    NO_QA_BODY="$(mktemp)"; printf 'No manual QA items: %s\n' "$NO_MANUAL_QA" > "$NO_QA_BODY"
    [[ -n "$COMMENT_FILE" ]] || COMMENT_FILE="$NO_QA_BODY"
    echo ">> no manual QA items (reason recorded as a comment)"
  else
    echo ">> manual QA items: $QA_OPEN open '${QA_SUBTASK_PREFIX}' subtask(s)"
  fi
fi

if [[ -n "$SET_BOARD_STATE" ]]; then
  BOARD_STATE_GID="$(enum_option_gid "$BOARD_STATE_FIELD" "Board State 🤖" "$SET_BOARD_STATE")" || exit 1
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$BOARD_STATE_FIELD" --arg v "$BOARD_STATE_GID" '. + {($k): $v}')
fi
if [[ -n "$SET_PRIORITY" ]]; then
  PRIORITY_GID="$(enum_option_gid "$PRIORITY_FIELD" "Priority" "$SET_PRIORITY")" || exit 1
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$PRIORITY_FIELD" --arg v "$PRIORITY_GID" '. + {($k): $v}')
fi
if [[ -n "$SET_RELEASE" ]]; then
  RELEASE_GID="$(enum_option_gid "$RELEASE_FIELD" "Release (4.x.x)" "$SET_RELEASE")" || exit 1
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$RELEASE_FIELD" --arg v "$RELEASE_GID" '. + {($k): $v}')
fi
if [[ -n "$SET_DEVELOPER_GID" ]]; then
  CUSTOM_FIELDS_PATCH=$(echo "$CUSTOM_FIELDS_PATCH" | jq --arg k "$DEVELOPER_FIELD" --arg v "$SET_DEVELOPER_GID" '. + {($k): [$v]}')
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
  UPDATE_KEYS="$(printf '%s' "$UPDATE_BODY" | jq -r '[.data | to_entries[] | if .key == "custom_fields" then "custom_fields " + (.value | keys | join(",")) else .key end] | join("; ")')"
  asana_request "Task update (PUT $TASK_GID: $UPDATE_KEYS)" -X PUT "$ASANA_API/tasks/$TASK_GID" \
    -H "Authorization: Bearer $ASANA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$UPDATE_BODY" || exit 1
  echo ">> Task fields: updated"
fi

if $DO_ASSIGN; then
  echo ">> Assigned to: $ASSIGN_GID"
fi
if $DO_UNASSIGN; then
  echo ">> Assignee: unset"
fi
if [[ -n "$SET_BOARD_STATE" ]]; then
  echo ">> Board State: $SET_BOARD_STATE"
fi
if [[ -n "$SET_PRIORITY" ]]; then
  echo ">> Priority: $SET_PRIORITY"
fi
if [[ -n "$SET_RELEASE" ]]; then
  echo ">> Release: $SET_RELEASE"
fi
if [[ -n "$SET_DEVELOPER_GID" ]]; then
  echo ">> Developer field: set"
fi

# --set-current-state <file>: rewrite ONLY the agent-maintained tail of the task
# description. Reads the current notes, drops everything from
# CURRENT_STATE_DELIM down, and re-appends the delimiter plus the file's body
# marked by agent-authored-text.sh. Replacing rather than appending is what makes
# a re-run idempotent: the section never stacks, and operator prose above the
# delimiter is preserved byte-for-byte.
if [[ -n "$SET_CURRENT_STATE_FILE" ]]; then
  [[ -f "$SET_CURRENT_STATE_FILE" ]] || {
    echo "Error: --set-current-state file not found: $SET_CURRENT_STATE_FILE" >&2; exit 1; }
  CS_BODY="$(cat "$SET_CURRENT_STATE_FILE")"
  [[ -n "${CS_BODY//[[:space:]]/}" ]] || {
    echo "Error: --set-current-state file is empty: $SET_CURRENT_STATE_FILE" >&2; exit 1; }

  CS_NOTES="$(curl -sf "$ASANA_API/tasks/$TASK_GID?opt_fields=notes" \
      -H "Authorization: Bearer $ASANA_TOKEN" 2>/dev/null | jq -r '.data.notes // ""')" || {
    echo ">> CURRENT STATE: FAILED (could not read notes for task $TASK_GID)" >&2; exit 1; }

  # Everything above the delimiter, with trailing whitespace trimmed so the
  # rebuilt notes get exactly one blank line before the delimiter.
  CS_PROSE="$(printf '%s\n' "$CS_NOTES" \
    | awk -v d="$CURRENT_STATE_DELIM" 'index($0, d) > 0 { exit } { print }')"
  CS_PROSE="${CS_PROSE%"${CS_PROSE##*[![:space:]]}"}"

  CS_MARKER="$HOME/.config/agent-watcher/agent-authored-text.sh"
  if [[ -x "$CS_MARKER" ]]; then
    CS_BODY="$(printf '%s' "$CS_BODY" | "$CS_MARKER")"
  fi

  CS_NEW="$(printf '%s\n\n%s\n%s\n' "$CS_PROSE" "$CURRENT_STATE_DELIM" "$CS_BODY")"
  CS_PATCH="$(jq -n --arg n "$CS_NEW" '{data:{notes:$n}}')"
  if curl -sf -X PUT "$ASANA_API/tasks/$TASK_GID" \
      -H "Authorization: Bearer $ASANA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$CS_PATCH" > /dev/null 2>&1; then
    echo ">> CURRENT STATE: updated on task $TASK_GID (operator prose above the delimiter preserved)"
  else
    echo ">> CURRENT STATE: FAILED (PUT rejected for task $TASK_GID)" >&2
    exit 1
  fi
fi
