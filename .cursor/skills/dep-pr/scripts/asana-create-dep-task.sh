#!/usr/bin/env bash
# asana-create-dep-task.sh
# Create a dependent Asana task that blocks a parent task.
# Checks for existing dependencies first to avoid duplicates.
#
# Usage:
#   asana-create-dep-task.sh --parent <parent_gid> --name "task name" [--notes "description"] [--assignee <user_gid>]
#
# If --assignee is omitted, the task is assigned to the current user
# (resolved via asana-whoami.sh).
#
# Requires env var: ASANA_TOKEN
#
# Output:
#   TASK_GID: <gid>
#   TASK_URL: <url>
#   CREATED: true|false (false if task already existed)
#   ASSIGNED_TO: <user_gid>
#   FIELDS_SET: priority=<val>, status=<val>, planned=<val>, reviewer=<name>, implementor=<name>
#   DEPENDENCY_SET: <new_gid> blocks <parent_gid>
#
# Exit codes: 0 = success, 1 = error
set -euo pipefail

PARENT_GID=""
TASK_NAME=""
TASK_NOTES=""
ASSIGNEE_GID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parent) PARENT_GID="$2"; shift 2 ;;
    --name) TASK_NAME="$2"; shift 2 ;;
    --notes) TASK_NOTES="$2"; shift 2 ;;
    --assignee) ASSIGNEE_GID="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PARENT_GID" || -z "$TASK_NAME" ]]; then
  echo "Usage: asana-create-dep-task.sh --parent <gid> --name <name> [--notes <desc>] [--assignee <gid>]" >&2
  exit 1
fi

# The token normally arrives from the shell profile; a session not launched from
# a shell (the desktop app) has none, so fall back to the credentials file.
: "${ASANA_TOKEN:=$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
export ASANA_TOKEN
if [[ -z "${ASANA_TOKEN:-}" ]]; then
  echo "Error: ASANA_TOKEN not set" >&2
  exit 1
fi

API="https://app.asana.com/api/1.0"
AUTH="Authorization: Bearer $ASANA_TOKEN"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-resolve current user GID (used for assignee and implementor)
CURRENT_USER_GID=$("$SCRIPT_DIR/../../asana-whoami.sh" 2>/dev/null || true)

# Auto-resolve assignee to current user if not provided
if [[ -z "$ASSIGNEE_GID" ]]; then
  ASSIGNEE_GID="$CURRENT_USER_GID"
fi

# Phase 1: Check if a dependency with a matching name already exists
# Task text reaches Python through the environment, never spliced into the
# source: a name or note holding a quote would otherwise end the string
# literal and run as code.
existing=$(curl -s "$API/tasks/$PARENT_GID/dependencies?opt_fields=name&limit=100" \
  -H "$AUTH" | TASK_NAME="$TASK_NAME" python3 -c "
import os, sys, json
data = json.load(sys.stdin).get('data', [])
target = os.environ['TASK_NAME']
for dep in data:
    if dep.get('name', '').strip().lower() == target.strip().lower():
        print(dep['gid'])
        sys.exit(0)
print('')
")

if [[ -n "$existing" ]]; then
  echo "TASK_GID: $existing"
  echo "TASK_URL: https://app.asana.com/0/0/$existing"
  echo "CREATED: false"
  exit 0
fi

# Phase 2: Get parent task's project and custom fields to copy
parent_info=$(curl -s "$API/tasks/$PARENT_GID?opt_fields=workspace.gid,memberships.project.gid,memberships.project.name,custom_fields.gid,custom_fields.enum_value.gid,custom_fields.enum_value.name,custom_fields.people_value.gid,custom_fields.people_value.name" \
  -H "$AUTH")

read -r WORKSPACE_GID PROJECT_GIDS PRIORITY_INFO RELEASE_INFO < <(echo "$parent_info" | python3 -c "
import sys, json, re
data = json.load(sys.stdin)['data']
ws = data.get('workspace', {}).get('gid', '')

# Collect all parent projects (including release-version projects like 4.46.0)
projects = []
for m in data.get('memberships', []):
    p = m.get('project', {})
    gid = p.get('gid', '')
    if gid:
        projects.append(gid)
if not projects and data.get('memberships'):
    projects.append(data['memberships'][0]['project']['gid'])
proj_str = ','.join(projects)

# Engineering Board fields a blocking dep inherits: it has to be scheduled with
# its parent, so Priority and Release carry over. Repo, LOE and Category describe
# the parent's own work and are left for the dep task to set. Other boards'
# fields on the parent (a task GET lists them too) are never copied.
ENUM_FIELDS = {
    '1213843686985522': 'priority',
    '1213939602865824': 'release',
}

enum_results = {}
for f in data.get('custom_fields', []):
    fgid = f['gid']
    if fgid in ENUM_FIELDS and f.get('enum_value'):
        enum_results[ENUM_FIELDS[fgid]] = (fgid, f['enum_value']['gid'], f['enum_value'].get('name', ''))

def fmt_enum(key):
    if key in enum_results:
        return ':'.join(enum_results[key])
    return '::'

print(f\"{ws} {proj_str} {fmt_enum('priority')} {fmt_enum('release')}\")
")

PRIORITY_ENUM=$(echo "$PRIORITY_INFO" | cut -d: -f2)
PRIORITY_NAME=$(echo "$PRIORITY_INFO" | cut -d: -f3)
RELEASE_ENUM=$(echo "$RELEASE_INFO" | cut -d: -f2)
RELEASE_NAME=$(echo "$RELEASE_INFO" | cut -d: -f3)

# The Engineering Board's developer field is the current user.
DEVELOPER_GID="$CURRENT_USER_GID"

# Phase 3: Create the task
# Mark agent-authored description (🥋 / 👊), idempotently — same markers the MCP
# write path gets via hooks/mark-agent-authored-asana.sh.
_MARKER="$HOME/.config/agent-watcher/agent-authored-text.sh"
[[ -x "$_MARKER" ]] && TASK_NOTES="$("$_MARKER" <<< "$TASK_NOTES")"

new_task=$(curl -s "$API/tasks" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  -d "$(TASK_NAME="$TASK_NAME" TASK_NOTES="$TASK_NOTES" PROJECT_GIDS="$PROJECT_GIDS" \
        ASSIGNEE_GID="$ASSIGNEE_GID" WORKSPACE_GID="$WORKSPACE_GID" python3 -c "
import json, os
projects = os.environ['PROJECT_GIDS'].split(',')
assignee = os.environ['ASSIGNEE_GID'] or None
# A caller's literal backslash-n still becomes a newline, as it did when the
# notes were a Python string literal.
notes = os.environ['TASK_NOTES'].replace(chr(92) + 'n', chr(10))
data = {
    'data': {
        'name': os.environ['TASK_NAME'],
        'notes': notes,
        'projects': [p for p in projects if p],
        'workspace': os.environ['WORKSPACE_GID']
    }
}
if assignee:
    data['data']['assignee'] = assignee
print(json.dumps(data))
")")

NEW_GID=$(echo "$new_task" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'errors' in data:
    print('ERROR: ' + json.dumps(data['errors']), file=sys.stderr)
    sys.exit(1)
print(data['data']['gid'])
")

if [[ -z "$NEW_GID" || "$NEW_GID" == "ERROR"* ]]; then
  echo "Error creating task" >&2
  exit 1
fi

# Phase 3b: Set copied fields via shared updater script
UPDATE_CMD=("$SCRIPT_DIR/../../asana-task-update/scripts/asana-task-update.sh" "--task" "$NEW_GID")
if [[ -n "$PRIORITY_ENUM" ]]; then
  UPDATE_CMD+=("--set-priority" "$PRIORITY_ENUM")
fi
if [[ -n "$RELEASE_ENUM" ]]; then
  UPDATE_CMD+=("--set-release" "$RELEASE_ENUM")
fi
if [[ -n "$DEVELOPER_GID" ]]; then
  UPDATE_CMD+=("--set-developer" "$DEVELOPER_GID")
fi
if [[ ${#UPDATE_CMD[@]} -gt 3 ]]; then
  "${UPDATE_CMD[@]}" > /dev/null
fi

FIRST_PROJECT=$(echo "$PROJECT_GIDS" | cut -d, -f1)
echo "TASK_GID: $NEW_GID"
echo "TASK_URL: https://app.asana.com/0/$FIRST_PROJECT/$NEW_GID"
echo "CREATED: true"
[[ -n "$ASSIGNEE_GID" ]] && echo "ASSIGNED_TO: $ASSIGNEE_GID"

# Phase 4: Set as blocking dependency
# curl -s exits 0 on an Asana 4xx/5xx, so the body is what says whether the
# link was made. The task above already exists: name its gid so the caller
# retries the link alone.
dep_resp=$(curl -s -X POST "$API/tasks/$PARENT_GID/addDependencies" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  -d "{\"data\": {\"dependencies\": [\"$NEW_GID\"]}}") || dep_resp=""
if ! printf '%s' "$dep_resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(1 if 'errors' in d else 0)
"; then
  echo "ERROR: task $NEW_GID was created but addDependencies on $PARENT_GID failed: ${dep_resp:0:300}" >&2
  exit 1
fi

echo "DEPENDENCY_SET: $NEW_GID blocks $PARENT_GID"

fields_msg=""
[[ -n "$PRIORITY_NAME" ]] && fields_msg="priority=$PRIORITY_NAME"
[[ -n "$RELEASE_NAME" ]] && fields_msg="${fields_msg:+$fields_msg, }release=$RELEASE_NAME"
[[ -n "$DEVELOPER_GID" ]] && fields_msg="${fields_msg:+$fields_msg, }developer=current user"
[[ -n "$fields_msg" ]] && echo "FIELDS_SET: $fields_msg"
