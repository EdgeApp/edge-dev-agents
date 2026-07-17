#!/usr/bin/env bash
# check-followup-scope.sh — LIVE-fetch a task's followup scope against the run-report
# watermark, per one-shot's `followup-scope-is-the-deliverable`.
#
# Why a script: every watcher resume auto-compacts the session from a summary built
# BEFORE the followup comment existed (spawn-test-session answers the resume menu with
# "Resume from summary", which runs /compact — trigger "manual" in the transcript).
# So a resumed agent's memory is by construction pre-followup, and runs kept
# re-Completing without seeing new operator comments (the 1209296431612665 UTXO miss,
# 2026-07-02). The enumeration must therefore be a REAL fetch, never recalled context.
# The require-followup-scope-on-complete.sh hook enforces that this ran.
#
# What it does:
#   1. Fetch the task's attachments; watermark = newest agent-run-report*.md created_at
#      (no report ever attached -> watermark is empty -> ALL comments are scope).
#   2. Fetch the task's stories; enumerate comment_added stories NEWER than the watermark.
#   3. Fetch the task's LIVE fields and diff them against the previous segment's
#      snapshot (stamp-orch-version.sh records fields at every spawn/resume). A re-arm
#      with ZERO new comments but changed fields (e.g. Build or Force Land set after
#      Complete — the Nym case) is operator intent, not a spurious re-fire; the delta
#      says WHY the task came back. Best-effort: no baseline (pre-feature segments) or
#      a failed fetch degrades to "unavailable", never fails the comment check. The
#      snapshot is a delta baseline only — decisions keep reading fields live.
#   4. Print them, and write the marker /tmp/agent-followup-scope-<gid>.json recording
#      what was fetched and when (the hook checks marker freshness against live comments).
#
# Usage: check-followup-scope.sh --task-gid <gid>
# Exit: 0 = check completed (marker written; newer scope MAY exist — read the output),
#       1 = usage/API error (no marker written).

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
TASK_GID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid) TASK_GID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$TASK_GID" ]] || { echo "Usage: check-followup-scope.sh --task-gid <gid>" >&2; exit 1; }

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$DIR/credentials.json" 2>/dev/null)}"
[[ -n "$TOKEN" ]] || { echo "check-followup-scope: no Asana token" >&2; exit 1; }

API="https://app.asana.com/api/1.0"
ATT="$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
  "$API/tasks/$TASK_GID/attachments?opt_fields=name,created_at")" || { echo "check-followup-scope: attachments fetch failed" >&2; exit 1; }
STORIES="$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
  "$API/tasks/$TASK_GID/stories?opt_fields=created_at,resource_subtype,text,created_by.name")" || { echo "check-followup-scope: stories fetch failed" >&2; exit 1; }
echo "$ATT" | jq -e '.data' >/dev/null 2>&1 || { echo "check-followup-scope: attachments response invalid: $(echo "$ATT" | head -c 200)" >&2; exit 1; }
echo "$STORIES" | jq -e '.data' >/dev/null 2>&1 || { echo "check-followup-scope: stories response invalid: $(echo "$STORIES" | head -c 200)" >&2; exit 1; }

# Watermark: newest agent-run-report*.md attachment. ISO-8601 sorts lexically.
WATERMARK="$(echo "$ATT" | jq -r '[.data[] | select(.name | test("^agent-run-report.*\\.md$")) | .created_at] | sort | last // empty')"

# Comments newer than the watermark (all comments when no report was ever attached).
NEWER="$(echo "$STORIES" | jq --arg w "$WATERMARK" \
  '[.data[] | select(.resource_subtype == "comment_added") | select(($w == "") or (.created_at > $w))]')"
NEWER_COUNT="$(echo "$NEWER" | jq 'length')"
NEWEST_COMMENT_AT="$(echo "$STORIES" | jq -r '[.data[] | select(.resource_subtype == "comment_added") | .created_at] | sort | last // empty')"

# Field deltas: live fields vs the previous segment's snapshot in versions/<gid>.jsonl.
# Inside the task's own session the NEWEST fields-bearing stamp was just written by
# THIS segment's spawn/resume — skip it so the baseline is the segment before.
VERSIONS_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions/$TASK_GID.jsonl"
FIELD_DELTAS="[]"
BASELINE_TS=""
DELTA_STATUS="unavailable: no prior field snapshot"
LIVE_FIELDS="null"
RESP=$(curl -sf --max-time 20 -H "Authorization: Bearer $TOKEN" \
  "$API/tasks/$TASK_GID?opt_fields=completed,custom_fields.name,custom_fields.display_value" 2>/dev/null) \
  && LIVE_FIELDS=$(echo "$RESP" | jq -c '{completed: .data.completed}
       + ([.data.custom_fields[]? | {(.name // "?"): (.display_value // null)}] | add // {})' 2>/dev/null) \
  || LIVE_FIELDS="null"
[[ -n "$LIVE_FIELDS" ]] || LIVE_FIELDS="null"

if [[ "$LIVE_FIELDS" == "null" ]]; then
  DELTA_STATUS="unavailable: live field fetch failed"
elif [[ -f "$VERSIONS_FILE" ]]; then
  SNAPS=$(jq -cs '[.[] | select(.fields != null)]' "$VERSIONS_FILE" 2>/dev/null || echo "[]")
  if [[ "${AGENT_TASK_GID:-}" == "$TASK_GID" ]]; then
    SNAPS=$(echo "$SNAPS" | jq -c '.[0:-1]')
  fi
  BASELINE=$(echo "$SNAPS" | jq -c 'last // empty')
  if [[ -n "$BASELINE" ]]; then
    BASELINE_TS=$(echo "$BASELINE" | jq -r '.ts')
    FIELD_DELTAS=$(jq -nc \
      --argjson old "$(echo "$BASELINE" | jq -c '.fields')" \
      --argjson new "$LIVE_FIELDS" \
      '[ (($old | keys) + ($new | keys) | unique)[]
         | select($old[.] != $new[.])
         | {field: ., was: $old[.], now: $new[.]} ]' 2>/dev/null || echo "[]")
    DELTA_STATUS="ok"
  fi
fi

MARKER="/tmp/agent-followup-scope-$TASK_GID.json"
jq -n \
  --arg gid "$TASK_GID" \
  --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg watermark "$WATERMARK" \
  --arg newest_comment_at "$NEWEST_COMMENT_AT" \
  --argjson newer_count "$NEWER_COUNT" \
  --argjson comments "$(echo "$NEWER" | jq '[.[] | {created_at, by: (.created_by.name // "?"), text: (.text // "" | .[0:400])}]')" \
  --arg delta_status "$DELTA_STATUS" \
  --arg baseline_ts "$BASELINE_TS" \
  --argjson field_deltas "$FIELD_DELTAS" \
  '{task_gid: $gid, checked_at: $checked_at, watermark: $watermark, newest_comment_at: $newest_comment_at, newer_count: $newer_count, comments: $comments,
    field_delta_status: $delta_status, field_baseline_ts: $baseline_ts, field_deltas: $field_deltas}' \
  > "$MARKER"

echo ">> check-followup-scope: task $TASK_GID"
if [[ -n "$WATERMARK" ]]; then
  echo ">>   watermark (latest agent-run-report*.md): $WATERMARK"
else
  echo ">>   watermark: NONE — no run-report ever attached; EVERY comment is undischarged scope"
fi
if [[ "$NEWER_COUNT" -eq 0 ]]; then
  echo ">>   0 comments newer than the watermark — no new comment scope"
else
  echo ">>   $NEWER_COUNT comment(s) NEWER than the watermark — this is THIS run's scope (followup-scope-is-the-deliverable):"
  echo "$NEWER" | jq -r '.[] | "     [\(.created_at)] \(.created_by.name // "?"): \(.text // "" | gsub("\\s+"; " ") | .[0:200])"'
fi
if [[ "$DELTA_STATUS" == "ok" ]]; then
  DELTA_COUNT=$(echo "$FIELD_DELTAS" | jq 'length')
  if [[ "$DELTA_COUNT" -eq 0 ]]; then
    echo ">>   0 field changes since previous segment snapshot ($BASELINE_TS)"
  else
    echo ">>   $DELTA_COUNT field change(s) since previous segment snapshot ($BASELINE_TS) — operator intent, NOT a spurious re-fire:"
    echo "$FIELD_DELTAS" | jq -r '.[] | "     \(.field): \(if .was == null then "(unset)" else (.was|tostring) end) -> \(if .now == null then "(unset)" else (.now|tostring) end)"'
    echo ">>   re-confirm the finalize gate — its LIVE reads (asana-build-field.sh, asana-force-land.sh) consume these values"
  fi
else
  echo ">>   field deltas: $DELTA_STATUS"
fi
echo ">>   marker written: $MARKER"
