#!/usr/bin/env bash
# qa-gate.sh: the QA plan gate. Validates the working plan's shape, runs the judge
# (completion-judge.sh --event qa-plan, rubric qa-run/references/rubric.md P1-P4),
# and acts on an allow:
#   decision: cases -> copies the plan to <QA_DIR>/plan.md and writes <QA_DIR>/approved
#                      (holding the lane). The same session reruns qa-start.sh, which
#                      returns PHASE=run on the pool sim it was spawned with.
#   decision: skip  -> runs qa-verdict.sh --verdict Skipped, which posts the comment
#                      and report built from the plan's skip_reason.
#
# Usage: qa-gate.sh [--gid <gid>]      (plan: /tmp/qa-plan-<gid>.md)
# Plan shape checked here (the judge rules on substance):
#   frontmatter  decision: cases|skip, lane: ios|android|none, account: <text>,
#                skip_reason: <text> (skip only)
#   cases        1 to 7 `### C<n> <title>` headings (decision cases); 0 for skip
# Exit: 0 allowed (and acted on) | 1 deny (failed items on stdout: revise the plan
#       and rerun) | 3 judge unavailable (rerun once; a second 3 ends the pass with
#       qa-verdict.sh --abandon) | 4 plan shape invalid | 2 usage
set -uo pipefail
source "$HOME/.cursor/skills/qa-run/scripts/lib.sh"

GID="${AGENT_TASK_GID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    *) echo "qa-gate: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] || { echo "usage: qa-gate.sh [--gid <gid>]" >&2; exit 2; }
QD=$(qa_dir "$GID"); PLAN=$(qa_plan_file "$GID")
[ -f "$QD/pinned.json" ] || { echo "qa-gate: no pinned.json; run qa-start.sh first" >&2; exit 2; }
[ -s "$PLAN" ] || { echo "SHAPE: plan file $PLAN is missing or empty" ; exit 4; }

fm() { awk -v k="$1" 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1{ if (index($0, k":")==1) { sub("^"k":[ ]*",""); print; exit } }' "$PLAN"; }
DECISION=$(fm decision); LANE=$(fm lane); ACCOUNT=$(fm account); SKIP_REASON=$(fm skip_reason)
NCASES=$(grep -cE '^### C[0-9]+' "$PLAN" || true)
BAD=""
case "$DECISION" in cases|skip) ;; *) BAD="$BAD decision must be cases or skip (got '$DECISION');" ;; esac
case "$LANE" in ios|android|none) ;; *) BAD="$BAD lane must be ios, android or none (got '$LANE');" ;; esac
[ -n "$ACCOUNT" ] || BAD="$BAD account is empty;"
if [ "$DECISION" = cases ]; then
  [ "$NCASES" -ge 1 ] && [ "$NCASES" -le 7 ] || BAD="$BAD a cases plan needs 1 to 7 '### C<n>' headings (found $NCASES);"
elif [ "$DECISION" = skip ]; then
  [ -n "$SKIP_REASON" ] || BAD="$BAD a skip plan needs skip_reason;"
  [ "$NCASES" = 0 ] || BAD="$BAD a skip plan has no '### C<n>' cases (found $NCASES);"
fi
[ -z "$BAD" ] || { echo "SHAPE:$BAD"; exit 4; }

OUT=$("$QA_H/completion-judge.sh" --gid "$GID" --event qa-plan 2>&1); RC=$?
printf '%s\n' "$OUT"
case "$RC" in
  0) ;;
  1) echo "GATE: deny. Revise $PLAN per each failed item, then rerun qa-gate.sh."; exit 1 ;;
  *) echo "GATE: judge unavailable (rc $RC)."; exit 3 ;;
esac

cp -f "$PLAN" "$QD/plan.md"
if [ "$DECISION" = skip ]; then
  echo "GATE: allow (skip). Posting the Skipped verdict."
  exec "$QA_SCRIPTS/qa-verdict.sh" --gid "$GID" --verdict Skipped
fi
printf '%s\n' "$LANE" > "$QD/approved"
echo "GATE: allow ($NCASES cases, lane $LANE). The plan is approved. Rerun qa-start.sh now; it returns PHASE=run."
