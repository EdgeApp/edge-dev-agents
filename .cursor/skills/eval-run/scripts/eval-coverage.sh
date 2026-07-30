#!/usr/bin/env bash
# eval-coverage.sh — which runs (and which SEGMENTS) the evals have covered.
#
# The eval ledger (~/agent-evals/<date>/<gid>.md) is gid-granular, but tasks
# re-arm: a gid evaluated in the 07-09 cohort can have run five segments since,
# and those silently rejoin the backlog with nothing recording it. Coverage is
# therefore computed per SEGMENT: a gid is CURRENT only when its newest version
# stamp predates its newest eval file; STALE when segments postdate the eval;
# NEVER when no eval file exists. Zero-LLM, read-only.
#
# Partial-coverage caveat printed in the summary: the flow-proposals sweep
# (harvest-flow-proposals.sh) and consolidation passes only capture what runs
# SELF-TAGGED ([playbook]/[flow]); a visited report with zero tags (marker
# "no tagged bullets") contributes nothing, so sweep coverage never substitutes
# for an eval of that run.
#
# Usage: eval-coverage.sh [--stale-only]
# Output: TSV  gid<TAB>state<TAB>last_segment<TAB>last_eval<TAB>segments_since_eval<TAB>swept
set -euo pipefail

STALE_ONLY=0
[ "${1:-}" = "--stale-only" ] && STALE_ONLY=1

EVALS="$HOME/agent-evals"
VERSIONS="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions"
PROPOSALS="$HOME/maestro-flow-corpus/proposals"

printf 'gid\tstate\tlast_segment\tlast_eval\tsegments_since_eval\tswept\n'
for f in "$VERSIONS"/*.jsonl; do
  [ -f "$f" ] || continue
  gid=$(basename "$f" .jsonl)
  last_seg=$(tail -1 "$f" | jq -r '.ts // empty' 2>/dev/null || true)

  # Newest eval file mentioning this gid; the dated dir names the eval day.
  last_eval=""
  for d in "$EVALS"/*/; do
    day=$(basename "$d")
    case "$day" in [0-9][0-9][0-9][0-9]-*) ;; *) continue ;; esac
    if ls "$d"/"$gid"*.md >/dev/null 2>&1; then
      [ -z "$last_eval" ] || [ "$day" \> "$last_eval" ] && last_eval="$day"
    fi
  done

  if [ -z "$last_eval" ]; then
    state="NEVER"; since=$(grep -c . "$f" || true)
  else
    # Segments strictly after the eval day (segment ts date > eval date).
    since=$(jq -rs --arg d "${last_eval}T23:59:59Z" '[.[] | select(.ts > $d)] | length' "$f" 2>/dev/null || echo "?")
    if [ "$since" = "0" ]; then state="CURRENT"; else state="STALE"; fi
  fi

  swept="no"
  if [ -f "$PROPOSALS/$gid.md" ]; then
    grep -q "no tagged bullets" "$PROPOSALS/$gid.md" && swept="visited-untagged" || swept="proposals"
  fi

  [ "$STALE_ONLY" = 1 ] && [ "$state" = "CURRENT" ] && continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$gid" "$state" "${last_seg:-?}" "${last_eval:--}" "$since" "$swept"
done
