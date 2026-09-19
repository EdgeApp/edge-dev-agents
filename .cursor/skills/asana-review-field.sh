#!/usr/bin/env bash
# asana-review-field.sh — resolve a task's `agent_review` value into the review
# LEVEL an orch run passes to the code-review-sonnet workflow, so no caller has
# to know which values exist or what an unset field means.
#
# The field carries the workflow's own level vocabulary, ONE TO ONE. There are no
# preset names in front of it: the board says `high` and the workflow runs `high`,
# with the Sonnet fan-out pin the workflow defaults to, exactly as /pr-review runs
# it. One engine, one set of names, nothing to translate in either direction.
#
# Values and what they mean:
#   (unset)  → the fleet default (watcher.default_review in asana-config.json,
#              "none" today). This is the lever for turning a light review on
#              everywhere once its cost is known: one config edit, no task or
#              script change.
#   off      → an explicit no for THIS task, which OUTRANKS the fleet default.
#              It has to be its own value rather than a literal "none": an unset
#              field also reads as "none" through asana-field-value.sh, so the
#              two are indistinguishable there, and an operator needs a way to
#              opt one task out once the fleet default is on.
#   low      → one finder, one diff pass, no verify, no synthesis, cap 4.
#   medium   → 3 correctness angles + 1 cleanup finder, 6 candidates each, one
#              verifier per location judging on the plain ladder, cap 8.
#   high     → medium's shape at high effort, verifiers given the recall bias
#              as well, cap 10.
#   xhigh    → 5 angles + cleanup, 8 candidates each, plus a gap-hunting sweep,
#              cap 15.
#
# `max` is deliberately NOT reachable from the board. It is xhigh's fan-out at
# max effort, so it buys reasoning depth and no extra coverage, which is not a
# trade an orch run should make unattended. Typed anyway, it CLAMPS to xhigh:
# it is a real level, so it is a deliberate ask for the most depth available
# rather than a typo, and the cheapest-level fallback would invert it.
#
# Depth is the only dial the board turns. `model=` and `effort=` exist on the
# workflow for a caller who needs them, and nothing on this path passes either:
# a level alone means Sonnet at that level's effort.
#
# STRUCTURAL, NOT AN ALLOWLIST. asana-build-field.sh learned this the hard way:
# a four-name list of cheeses went stale and a run silently skipped an owed
# build. So an UNRECOGNIZED value is never "no review" — an operator who typed
# something wants one. It resolves to the cheapest level, which honors the
# intent without spending xhigh money on a typo.
#
# Usage:
#   asana-review-field.sh <task-gid>             → the resolved value, lowercased
#                                                  ("none" when no review is owed)
#   asana-review-field.sh <task-gid> --variant   → "none", or the workflow args
#                                                  (a bare level: "low".."xhigh")
# Exit: 0 = resolved (incl. none), 1 = auth/network error, 2 = usage.
set -euo pipefail

GID="${1:-}"
MODE="${2:-value}"
[ -n "$GID" ] || { echo "usage: asana-review-field.sh <task-gid> [--variant]" >&2; exit 2; }
case "$MODE" in value|--variant) ;; *) echo "usage: asana-review-field.sh <task-gid> [--variant]" >&2; exit 2 ;; esac

FIELD_NAME="agent_review"
CONFIG="$HOME/.config/agent-watcher/asana-config.json"

# The generic reader owns the Asana call, the name tolerance, and the "none"
# convention for an unset field (asana-field-value.sh).
val=$("$HOME/.cursor/skills/asana-field-value.sh" "$GID" "$FIELD_NAME") || exit 1
val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/ *$//')

# An unset field reads as "none" here and defers to the fleet default. `off` is
# the explicit per-task opt-out and never consults it.
if [ -z "$val" ] || [ "$val" = "none" ] || [ "$val" = "null" ]; then
  val=$(jq -r '.watcher.default_review // "none"' "$CONFIG" 2>/dev/null || echo none)
  [ -n "$val" ] && [ "$val" != "null" ] || val="none"
  val=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
fi

if [ "$MODE" = "value" ]; then
  echo "$val"
  exit 0
fi

# The cheapest level is named once: the unrecognized-value arm resolves to the
# SAME string, and writing it twice means changing the fallback in one place and
# not the other.
CHEAPEST_LEVEL="low"

case "$val" in
  none|off)                 echo "none" ;;
  low|medium|high|xhigh)    echo "$val" ;;
  # `max` is a real workflow level, so typing it is a deliberate ask for the most
  # depth available and NOT a typo. It clamps DOWN to xhigh rather than falling to
  # the cheapest arm, which would invert the one thing the operator asked for.
  max)                      echo "xhigh" ;;
  *)                        echo "$CHEAPEST_LEVEL" ;;
esac
