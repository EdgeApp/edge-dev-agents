#!/usr/bin/env bash
# eval-coverage.sh — which runs (and which SEGMENTS) each eval TYPE has covered.
#
# Two distinct lenses, never conflated (operator ruling 2026-07-29):
#   report-eval      graded the run REPORT against live GitHub/Asana state
#                    (ledger files ~/agent-evals/<date>/<gid>-report-eval.md).
#                    The cheap default; sees claims, not process.
#   transcript-eval  the full pass over the session TRANSCRIPT (process
#                    dimensions, friction, orch-eval; ledger files
#                    <gid>.md / <gid>-agent-eval.md — all pre-2026-07-29 evals
#                    are this type). The heavy one-off, run on named gids or
#                    ones a report-eval escalated.
#
# Coverage is per SEGMENT: a lens is CURRENT only when the gid's newest version
# stamp predates that lens's newest eval file; STALE when segments postdate it;
# NEVER when no file exists. Zero-LLM, read-only.
#
# The `swept` column reports the flow-proposals sweep (harvest-flow-proposals.sh)
# separately because it only captures what runs SELF-TAGGED — "visited-untagged"
# (marker "no tagged bullets") contributes nothing and never substitutes for
# either eval type (the piratechain case).
#
# Usage: eval-coverage.sh [--queue report|transcript]
#   --queue report      only rows where report-eval is STALE/NEVER (the default
#                       eval-run work list)
#   --queue transcript  only rows where transcript-eval is STALE/NEVER
# Output TSV: gid, report_eval, report_eval_date, transcript_eval,
#             transcript_eval_date, last_segment, swept
set -euo pipefail

QUEUE=""
while [ $# -gt 0 ]; do case "$1" in
  --queue) QUEUE="$2"; shift 2 ;;
  --stale-only) QUEUE="report"; shift ;;  # back-compat alias for the default queue
  *) echo "usage: eval-coverage.sh [--queue report|transcript]" >&2; exit 2 ;;
esac; done

EVALS="$HOME/agent-evals"
VERSIONS="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions"
PROPOSALS="$HOME/maestro-flow-corpus/proposals"

# lens_state <gid> <last_seg> <glob-suffix-regex> -> "STATE<TAB>date"
lens_state() {
  local gid="$1" last_seg="$2" kind="$3" last_eval="" d day f
  for d in "$EVALS"/*/; do
    day=$(basename "$d")
    case "$day" in [0-9][0-9][0-9][0-9]-*) ;; *) continue ;; esac
    for f in "$d$gid"*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        *-report-eval.md) [ "$kind" = report ] || continue ;;
        *) [ "$kind" = transcript ] || continue ;;
      esac
      { [ -z "$last_eval" ] || [ "$day" \> "$last_eval" ]; } && last_eval="$day"
    done
  done
  if [ -z "$last_eval" ]; then
    printf 'NEVER\t-'
  elif [ "${last_seg:0:10}" \> "$last_eval" ]; then
    printf 'STALE\t%s' "$last_eval"
  else
    printf 'CURRENT\t%s' "$last_eval"
  fi
}

printf 'gid\treport_eval\treport_eval_date\ttranscript_eval\ttranscript_eval_date\tlast_segment\tswept\n'
for f in "$VERSIONS"/*.jsonl; do
  [ -f "$f" ] || continue
  gid=$(basename "$f" .jsonl)
  last_seg=$(tail -1 "$f" | jq -r '.ts // empty' 2>/dev/null || true)

  IFS=$'\t' read -r r_state r_date <<<"$(lens_state "$gid" "$last_seg" report)"
  IFS=$'\t' read -r t_state t_date <<<"$(lens_state "$gid" "$last_seg" transcript)"

  swept="no"
  if [ -f "$PROPOSALS/$gid.md" ]; then
    grep -q "no tagged bullets" "$PROPOSALS/$gid.md" && swept="visited-untagged" || swept="proposals"
  fi

  case "$QUEUE" in
    report)     [ "$r_state" = "CURRENT" ] && continue ;;
    transcript) [ "$t_state" = "CURRENT" ] && continue ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gid" "$r_state" "$r_date" "$t_state" "$t_date" "${last_seg:-?}" "$swept"
done
