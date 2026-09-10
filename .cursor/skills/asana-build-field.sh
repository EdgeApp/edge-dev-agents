#!/usr/bin/env bash
# asana-build-field.sh — resolve a task's "Build (staging/cheese)" enum value,
# and classify it, so no caller has to know which cheeses exist.
#
# The field lives on the Engineering Board (gid 1213928707858644); tasks
# multi-homed into that project carry it. Consumers route on the KIND:
#   staging → /pr-land cherry-picks onto staging after land
#   cheese  → /one-shot kicks a cheese build (test-<value> hard-reset to the
#             PR head) before Complete
#   none    → no build routing
#
# THE FIELD IS THE ROSTER, NOT A LIST IN PROSE. The cheese names are operator
# data and they grow: the field carried Feta/Gouda/Halloumi/Cheddar when this
# script was written and now also carries Kraft, Colby, String, Parm, Swiss and
# Paneer. Every place that hardcoded the original four went stale, and on task
# 1218291556240193 (2026-09-09) a run read `String`, missed it against a
# four-name allowlist, and skipped an owed cheese build. So the classification
# is structural: the field is named "Build (staging/cheese)", so any value that
# is not Staging and not empty IS a cheese. Callers ask for --kind and never
# enumerate.
#
# Usage:
#   asana-build-field.sh <task-gid>           → the value, lowercased, or "none"
#   asana-build-field.sh <task-gid> --kind    → staging | cheese | none
# Exit: 0 = resolved (incl. none), 1 = auth/network error, 2 = usage.
set -euo pipefail

GID="${1:-}"
MODE="${2:-value}"
[ -n "$GID" ] || { echo "usage: asana-build-field.sh <task-gid> [--kind]" >&2; exit 2; }
case "$MODE" in value|--kind) ;; *) echo "usage: asana-build-field.sh <task-gid> [--kind]" >&2; exit 2 ;; esac

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "ERROR: no ASANA_TOKEN and no credentials.json token" >&2; exit 1; }

FIELD_GID="1213928707858644" # "Build (staging/cheese)" on the Engineering Board

resp=$(curl -sf --max-time 20 \
  "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.gid,custom_fields.name,custom_fields.display_value" \
  -H "Authorization: Bearer $TOKEN") || { echo "ERROR: asana fetch failed for $GID" >&2; exit 1; }

val=$(echo "$resp" | jq -r --arg g "$FIELD_GID" \
  'first(.data.custom_fields[]? | select(.gid == $g or ((.name // "") == "Build (staging/cheese)")) | .display_value) // empty')

if [ -z "$val" ] || [ "$val" = "null" ]; then
  val="none"
else
  val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
fi

if [ "$MODE" = "--kind" ]; then
  case "$val" in
    none) echo none ;;
    staging) echo staging ;;
    *) echo cheese ;;
  esac
else
  echo "$val"
fi
