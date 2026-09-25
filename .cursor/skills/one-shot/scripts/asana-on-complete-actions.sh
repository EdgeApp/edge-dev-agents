#!/usr/bin/env bash
# asana-on-complete-actions.sh
# Read and record the post-completion actions the operator put in a task's
# `agent_on_complete` text field (one-shot finalize / task-run step 5, `on-complete-actions` rule).
#
# The field is operator-written; agents never set it. One action per line or
# bullet (`- `, `* `, `• ` prefixes are stripped; blank lines ignored). Each
# gets a stable id: the first 8 hex of sha1 over its whitespace-normalized
# text, so re-ordering keeps ids and an edited line re-arms.
#
# State lives in marker comments on the task, one per run:
#   ON COMPLETE <id>=<state>[: <reason>]      one line per action
# state is done | skipped | failed | note. The newest marker per id wins.
# `note` marks a line that is not an action (a condition or a remark) so it
# stops listing as pending. `failed` stays pending for the next run of the task.
#
# Usage:
#   asana-on-complete-actions.sh --task <gid>                 # JSON: field present + actions with state
#   asana-on-complete-actions.sh --task <gid> --pending       # "<id>\t<text>" per pending action
#   asana-on-complete-actions.sh --task <gid> --mark <id>=<state>[:reason] [...]
#                                                         # post one marker comment
#
# Output for the JSON mode:
#   {"task":"<gid>","field":true|false,
#    "actions":[{"id":"..","index":1,"text":"..","state":"pending|done|skipped|failed|note","reason":".."}]}
#
# Exit: 0 = ok (an empty field is still 0, field:false), 1 = error, 2 = usage.
set -euo pipefail

TASK_GID=""
MODE="json"
MARKS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_GID="$2"; shift 2 ;;
    --pending) MODE="pending"; shift ;;
    --mark) MODE="mark"; MARKS+=("$2"); shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TASK_GID" ]] || { echo "usage: --task <gid> [--pending | --mark <id>=<state>[:reason] ...]" >&2; exit 2; }
TASK_GID="${TASK_GID##*/}"

if [[ -z "${ASANA_TOKEN:-}" ]]; then
  CRED="$HOME/.config/agent-watcher/credentials.json"
  [[ -f "$CRED" ]] && ASANA_TOKEN="$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)"
fi
[[ -n "${ASANA_TOKEN:-}" ]] || { echo "Error: ASANA_TOKEN not set and not found in credentials.json" >&2; exit 1; }
export ASANA_TOKEN
API="https://app.asana.com/api/1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE="$SCRIPT_DIR/../../asana-task-update/scripts/asana-task-update.sh"

# Test seam: ON_COMPLETE_TASK_FILE / ON_COMPLETE_STORIES_FILE hold the two API
# responses verbatim, so the parser runs against fixtures with no network.
if [[ -n "${ON_COMPLETE_TASK_FILE:-}" ]]; then
  TASK_JSON="$(cat "$ON_COMPLETE_TASK_FILE")"
  STORIES_JSON="$(cat "${ON_COMPLETE_STORIES_FILE:-/dev/null}")"
  [[ -n "$STORIES_JSON" ]] || STORIES_JSON='{"data":[]}'
else
  TASK_JSON="$(curl -sf --max-time 30 -H "Authorization: Bearer $ASANA_TOKEN" \
    "$API/tasks/$TASK_GID?opt_fields=custom_fields.name,custom_fields.resource_subtype,custom_fields.text_value")" \
    || { echo "Error: could not read task $TASK_GID" >&2; exit 1; }
  STORIES_JSON="$(curl -sf --max-time 30 -H "Authorization: Bearer $ASANA_TOKEN" \
    "$API/tasks/$TASK_GID/stories?opt_fields=resource_subtype,text,created_at&limit=100")" \
    || { echo "Error: could not read stories for task $TASK_GID" >&2; exit 1; }
fi

STATE_JSON="$(TASK_JSON="$TASK_JSON" STORIES_JSON="$STORIES_JSON" TASK_GID="$TASK_GID" node -e '
const crypto = require("crypto")
const fields = (JSON.parse(process.env.TASK_JSON).data.custom_fields) || []
const stories = JSON.parse(process.env.STORIES_JSON).data || []
const field = fields.find(f => (f.name || "").trim().toLowerCase() === "agent_on_complete")
const raw = field && field.text_value ? field.text_value : ""
const actions = raw.split(/\r?\n/).map(l => l.replace(/^\s*[-*\u2022]\s+/, "").trim()).filter(Boolean)
const idOf = t => crypto.createHash("sha1").update(t.replace(/\s+/g, " ").trim().toLowerCase()).digest("hex").slice(0, 8)
const marks = {}
for (const s of stories) {
  if (s.resource_subtype !== "comment_added") continue
  const text = (s.text || "").replace(/^\s*🥋\s*/, "").replace(/\s*👊\s*$/, "")
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*ON COMPLETE ([0-9a-f]{8})=(done|skipped|failed|note)(?::\s*(.*))?\s*$/)
    if (m) marks[m[1]] = { state: m[2], reason: m[3] || "", at: s.created_at }
  }
}
const out = actions.map((text, k) => {
  const id = idOf(text)
  const m = marks[id]
  const state = m && m.state !== "failed" ? m.state : "pending"
  return { id, index: k + 1, text, state, reason: m ? m.reason : "", last: m ? m.state : "" }
})
console.log(JSON.stringify({ task: process.env.TASK_GID, field: !!field, actions: out }))
')"

case "$MODE" in
  json) printf '%s\n' "$STATE_JSON" ;;
  pending)
    printf '%s\n' "$STATE_JSON" | jq -r '.actions[] | select(.state == "pending") | "\(.id)\t\(.text)"'
    ;;
  mark)
    BODY="$(mktemp "${TMPDIR:-/tmp}/on-complete-mark.XXXXXX")"
    for m in "${MARKS[@]}"; do
      id="${m%%=*}"; rest="${m#*=}"; state="${rest%%:*}"; reason=""
      [[ "$rest" == *:* ]] && reason="${rest#*:}"
      case "$state" in done|skipped|failed|note) ;; *) echo "Error: bad state in --mark $m (done|skipped|failed|note)" >&2; exit 2 ;; esac
      printf '%s\n' "$STATE_JSON" | jq -e --arg id "$id" '.actions[] | select(.id == $id)' >/dev/null \
        || { echo "Error: no agent_on_complete action with id $id on task $TASK_GID" >&2; exit 2; }
      text="$(printf '%s\n' "$STATE_JSON" | jq -r --arg id "$id" '.actions[] | select(.id == $id) | .text')"
      printf 'ON COMPLETE %s=%s%s\n  %s\n' "$id" "$state" "${reason:+: ${reason# }}" "$text" >> "$BODY"
    done
    "$UPDATE" --task "$TASK_GID" --comment-file "$BODY"
    rm -f "$BODY"
    ;;
esac
