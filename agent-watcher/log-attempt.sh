#!/usr/bin/env bash
# log-attempt.sh — append one structured ATTEMPT record to a task's attempt-log.
#
# The attempt-log is the authoritative, agent-LOCATION-INDEPENDENT record of every
# value-moving action (swap/send/sweep) and every test-drive/repro a run actually
# performed. Whoever does the attempt writes it here; whoever validates a CONCESSION
# (the concession-validation gate now — covering BOTH a formal `--blocked yes` and a
# silent DOWNGRADE-finalize that completes/opens a PR without reaching the prescribed
# in-app success — the eval post-hoc) reads it here. This decoupling is what survives
# the tester split: when testing becomes its own subagent, the test drive lands in the
# subagent's context — NOT the main agent's transcript — so a transcript grep would miss
# it. The attempt-log, keyed by gid on the shared filesystem, is written by the tester
# (whichever agent that is) and read by the main agent's concession gate and the eval all
# the same.
#
# Usage:
#   log-attempt.sh --gid <gid> --action "<what was attempted>" \
#       --result "success" | "failed:<why>" | "loss:<detail>" | "blocked:<precondition>" \
#       [--category swap|send|sweep|test-drive|repro|other]
#
# RESULT semantics (these drive the validator's grey-zone decision):
#   success          — the action reached its terminal success state
#   failed:<why>     — attempted, did NOT succeed, but principal is safe (fees only)
#   loss:<detail>    — attempted, FAILED, and principal did not arrive / is unrecoverable
#                      (the ONLY funds condition that legitimizes a block)
#   blocked:<precond>— attempted up to a precondition the slot genuinely cannot satisfy
#                      (real provider halt, geo-block confirmed by attempt, KYC, etc.)
#
# Exit codes: 0 = logged; 2 = usage error. Never wedges a caller.
set -euo pipefail

GID="" ACTION="" RESULT="" CATEGORY="other"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gid)      GID="$2";      shift 2 ;;
    --action)   ACTION="$2";   shift 2 ;;
    --result)   RESULT="$2";   shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    *) echo "log-attempt: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$GID" && -n "$ACTION" && -n "$RESULT" ]] || {
  echo "Usage: log-attempt.sh --gid <gid> --action \"<desc>\" --result success|failed:<why>|loss:<detail>|blocked:<precond> [--category <c>]" >&2
  exit 2
}

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/attempts"
mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/$GID.jsonl"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# One compact JSON object per line. jq builds it so embedded quotes/newlines are safe.
jq -cn \
  --arg ts "$TS" --arg gid "$GID" --arg action "$ACTION" \
  --arg result "$RESULT" --arg category "$CATEGORY" \
  --arg session "${AGENT_SESSION_UUID:-}" \
  '{ts:$ts, gid:$gid, category:$category, action:$action, result:$result, session:$session}' \
  >> "$LOG"

echo ">> log-attempt: [$CATEGORY] $ACTION → $RESULT  (logged to attempts/$GID.jsonl)"
