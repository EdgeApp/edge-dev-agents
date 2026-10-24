#!/usr/bin/env bash
# set-tested.sh — set the Asana "tested" multi-select field on an agent task to
# the testing method(s) actually performed. Companion to update-status.sh; same
# auth + PUT pattern, separate concern (testing method, not phase).
#
# Usage:
#   set-tested.sh <task_gid> <Option> [<Option> ...]
#   set-tested.sh <task_gid> <Option ...> --drop "<Option>" --reason "<why>"
#   set-tested.sh <task_gid> --clear --reason "<why>"   # set the field to empty
#   set-tested.sh <task_gid> ... --dry-run     # print payload, do not PUT
#
# Credit is KEPT by default: the script reads the field's current value and
# writes the union of it and the options passed, so a later segment that ran
# less (a rebase, review replies, a unit-test-only pass) cannot erase a method an
# earlier segment earned. A credited method leaves the field only through
# `--drop <Option>` (repeatable) or `--clear`, each with `--reason`: the reason
# names what invalidated the earlier evidence (shipped code changed after the
# drive, the drive is now known to be false). Every drop is appended to
# $STATE_DIR/tested-drops.jsonl and echoed, so the eval can audit it. `Untested`
# yields to any real method in the union; passing Untested over a real credit
# without dropping it exits 2.
#
# Options (multi-select; pass every method that genuinely ran). This block is
# the ONE definition of each option and the artifact that earns it: the
# completion judge reads it verbatim (rubric J4), so change it here only.
#   iOS Sim     — the change was driven in-app on the iOS sim (maestro / build +
#                 simctl launch, real action to terminal success). Artifact:
#                 proof frames /tmp/agent-proof-<gid>-*.png plus an attempt-log
#                 success entry. DEFAULT sim platform; quote it ("iOS Sim").
#   Android Sim — exercised on an Android EMULATOR. Artifact: in-app proof frames
#                 from the AVD drive, or for a build-only fix the gradle
#                 :app:assembleDebug log /tmp/agent-android-build-<gid>*.log (or the
#                 APK /tmp/agent-proof-<gid>-*.apk). Android tasks only.
#   Android Device — exercised on a PHYSICAL Android device (e.g. the S9).
#                 Artifact: proof frames captured from the device. Never record a
#                 physical drive as Android Sim.
#   Unit Tests  — jest / mocha / `npm test` ran (verify-repo's test step).
#                 Artifact: the suite's pass/fail result in the run report.
#   CouchDB     — a CouchDB-backed test ran (sync / server repos: edge-reports-
#                 server, edge-core-js sync, a couch/pouch integration test).
#                 Artifact: the test command and its result in the run report.
#   Other       — a real test method not listed above. Artifact: the run report
#                 names the method and its result.
#   Untested    — NO test method applied; mutually exclusive with the others
#                 (only static tsc/lint, or nothing). Never combine with a real
#                 method.
#
# Exit: 0 ok, 1 API/runtime error, 2 usage / unknown option.
set -euo pipefail

CONFIG="$HOME/.config/agent-watcher/asana-config.json"
CRED="$HOME/.config/agent-watcher/credentials.json"

usage() {
  echo "Usage: set-tested.sh <task_gid> <Option ...> [--drop <Option> ...] | --clear;  --reason <why> with --drop/--clear;  [--dry-run]" >&2
  echo "Options: $(jq -r '.custom_fields.tested.options | keys | join(", ")' "$CONFIG" 2>/dev/null)" >&2
  exit 2
}

TASK_GID="${1:-}"; shift || true
[[ -n "$TASK_GID" ]] || usage

DRY_RUN=false
CLEAR=false
OPTS=()
DROPS=()
REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --clear)   CLEAR=true ;;
    --drop)    [[ $# -ge 2 ]] || usage; DROPS+=("$2"); shift ;;
    --reason)  [[ $# -ge 2 ]] || usage; REASON="$2"; shift ;;
    *)         OPTS+=("$1") ;;
  esac
  shift
done
{ [[ "$CLEAR" == true ]] || [[ ${#OPTS[@]} -gt 0 ]] || [[ ${#DROPS[@]} -gt 0 ]]; } || usage
if { [[ "$CLEAR" == true ]] || [[ ${#DROPS[@]} -gt 0 ]]; } && [[ -z "$REASON" ]]; then
  echo "--drop and --clear need --reason naming what invalidated the earlier evidence." >&2; exit 2
fi

FIELD_GID=$(jq -r .custom_fields.tested.gid "$CONFIG")
[[ -n "$FIELD_GID" && "$FIELD_GID" != "null" ]] || { echo "tested field not configured in $CONFIG" >&2; exit 1; }

opt_gid() { jq -r --arg n "$1" '.custom_fields.tested.options[$n] // empty' "$CONFIG"; }
for name in "${OPTS[@]:-}" "${DROPS[@]:-}"; do
  [[ -z "$name" ]] && continue
  [[ -n "$(opt_gid "$name")" ]] || { echo "Unknown option: $name" >&2; usage; }
done
# Untested is mutually exclusive with real methods — reject the contradiction.
if [[ " ${OPTS[*]:-} " == *" Untested "* ]] && [[ ${#OPTS[@]} -gt 1 ]]; then
  echo "Untested cannot be combined with another method." >&2; exit 2
fi

TOKEN=""
# The current value, as option names. SET_TESTED_CURRENT (comma-separated
# names) stands in for the Asana read in tests; it is never set by callers.
if [[ -n "${SET_TESTED_CURRENT+x}" ]]; then
  CURRENT="$SET_TESTED_CURRENT"
else
  TOKEN=$(jq -r .asana_token "$CRED")
  CUR_JSON=$(curl -sS --max-time 20 -H "Authorization: Bearer $TOKEN" \
    "https://app.asana.com/api/1.0/tasks/$TASK_GID?opt_fields=custom_fields.gid,custom_fields.multi_enum_values.name") \
    || { echo "could not read the current tested value for $TASK_GID; refusing to write blind" >&2; exit 1; }
  if echo "$CUR_JSON" | jq -e .errors >/dev/null 2>&1; then
    echo "Asana API error reading $TASK_GID: $(echo "$CUR_JSON" | jq -c .errors)" >&2; exit 1
  fi
  CURRENT=$(echo "$CUR_JSON" | jq -r --arg f "$FIELD_GID" '[.data.custom_fields[]? | select(.gid == $f) | .multi_enum_values[]?.name] | join(",")')
fi

# Final set: (current ∪ passed) − dropped, or empty on --clear; Untested yields to
# any real method. Prints one name per line; exit 2 on Untested over a kept credit.
FINAL=$(CUR="$CURRENT" CLEAR="$CLEAR" node -e '
  const [opts, drops] = [process.argv[1], process.argv[2]].map(s => s.split("\n").filter(Boolean))
  const cur = (process.env.CUR || "").split(",").map(s => s.trim()).filter(Boolean)
  if (process.env.CLEAR === "true") process.exit(0)
  const real = n => n !== "Untested"
  const kept = cur.filter(n => real(n) && !drops.includes(n))
  if (opts.includes("Untested") && kept.length) {
    console.error("Untested would erase earlier credit [" + kept.join(", ") + "]: drop each with --drop and --reason, or pass the methods that ran.")
    process.exit(2)
  }
  const out = [...new Set([...kept, ...opts.filter(n => !drops.includes(n))])]
  const final = out.some(real) ? out.filter(real) : out
  process.stdout.write(final.join("\n"))
' "$(printf '%s\n' "${OPTS[@]:-}")" "$(printf '%s\n' "${DROPS[@]:-}")") || exit $?

DROPPED=$(CUR="$CURRENT" node -e '
  const final = process.argv[1].split("\n").filter(Boolean)
  const cur = (process.env.CUR || "").split(",").map(s => s.trim()).filter(n => n && n !== "Untested")
  process.stdout.write(cur.filter(n => !final.includes(n)).join(", "))
' "$FINAL")

OPT_GIDS=()
while IFS= read -r name; do
  [[ -n "$name" ]] && OPT_GIDS+=("$(opt_gid "$name")")
done <<< "$FINAL"
FINAL_LIST=$(printf '%s' "$FINAL" | paste -sd, - | sed 's/,/, /g')

# multi_enum value is a JSON array of option GIDs ([] clears the field).
ARR=$(printf '%s\n' "${OPT_GIDS[@]:-}" | jq -R . | jq -cs 'map(select(length > 0))')
PAYLOAD=$(jq -n --arg f "$FIELD_GID" --argjson v "$ARR" '{data: {custom_fields: {($f): $v}}}')

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY-RUN current=[${CURRENT//,/, }] final=[$FINAL_LIST] dropped=[${DROPPED}]"
  echo "DRY-RUN payload for task $TASK_GID:"; echo "$PAYLOAD" | jq .
  exit 0
fi

[[ -n "$TOKEN" ]] || TOKEN=$(jq -r .asana_token "$CRED")
RESPONSE=$(curl -sS -X PUT \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "$PAYLOAD" "https://app.asana.com/api/1.0/tasks/$TASK_GID")

if echo "$RESPONSE" | jq -e .errors >/dev/null 2>&1; then
  echo "Asana API error: $(echo "$RESPONSE" | jq -c .errors)" >&2
  exit 1
fi
if [[ -n "$DROPPED" ]]; then
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"; mkdir -p "$STATE_DIR"
  jq -nc --arg gid "$TASK_GID" --arg prev "$CURRENT" --arg final "$FINAL_LIST" --arg dropped "$DROPPED" --arg reason "$REASON" \
    '{ts: (now | todate), gid: $gid, previous: $prev, final: $final, dropped: $dropped, reason: $reason}' >> "$STATE_DIR/tested-drops.jsonl"
  echo "Dropped earlier credit [$DROPPED] on task $TASK_GID: $REASON"
fi
KEPT=$(CUR="$CURRENT" node -e '
  const passed = process.argv[1].split("\n").filter(Boolean)
  const cur = (process.env.CUR || "").split(",").map(s => s.trim()).filter(n => n && n !== "Untested")
  process.stdout.write(cur.filter(n => !passed.includes(n) && process.argv[2].split(", ").includes(n)).join(", "))
' "$(printf '%s\n' "${OPTS[@]:-}")" "$FINAL_LIST")
echo "Set tested=[$FINAL_LIST] on task $TASK_GID${KEPT:+ (kept earlier credit: $KEPT)}"
