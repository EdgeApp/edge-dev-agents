#!/usr/bin/env bash
# asana-review-field.sh — resolve a task's `agent_review` value and turn it into
# the review VARIANT an orch run passes to the code-review-sonnet workflow, so
# no caller has to know which values exist or how they map.
#
# The field carries operator INTENT (how much review this task is worth), never
# workflow syntax. The mapping from intent to variant lives here alone, so
# changing what `quick` costs is an edit to this file and not to a single task,
# and the board never has to learn the workflow's flag vocabulary.
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
#   quick    → ONE agent of review work: one finder, one diff pass, no verify,
#              no synthesis, capped at 4 findings, running on the caller's own
#              model AND effort. Cheapest review that is still a review. The one
#              thing it does not inherit is the context: it stays an isolated
#              agent, so the review never lands in the orch session's window.
#   deep     → the full Sonnet fan-out at the workflow's default level, which is
#              what /pr-review's deep mode has always run: correctness angles in
#              parallel, an independent verifier per location, then synthesis.
#   a level  → passed through verbatim (low|medium|high|xhigh|max), so a level
#              added to the workflow works from the board on arrival.
#
# STRUCTURAL, NOT AN ALLOWLIST. asana-build-field.sh learned this the hard way:
# a four-name list of cheeses went stale and a run silently skipped an owed
# build. So an UNRECOGNIZED value is never "no review" — an operator who typed
# something wants one. It resolves to the cheapest variant, which honors the
# intent without spending deep-review money on a typo.
#
# Usage:
#   asana-review-field.sh <task-gid>             → the resolved value, lowercased
#                                                  ("none" when no review is owed)
#   asana-review-field.sh <task-gid> --variant   → "none", or workflow args
#                                                  ("low model=inherit effort=inherit",
#                                                   "high")
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

# The cheapest preset is named once: the unrecognized-value arm below resolves
# to the SAME string, and writing it twice means retuning `quick` silently
# leaves typo'd tasks on the old variant.
QUICK_VARIANT="low model=inherit effort=inherit"

case "$val" in
  none|off)                      echo "none" ;;
  quick)                         echo "$QUICK_VARIANT" ;;
  deep)                          echo "high" ;;
  low|medium|high|xhigh|max)     echo "$val" ;;
  *)                             echo "$QUICK_VARIANT" ;;
esac
