#!/usr/bin/env bash
# qa-evidence.sh: build the QA judge's evidence bundle. Called by
# ~/.config/agent-watcher/completion-judge.sh for the QA events; never by an agent.
#
# Usage: qa-evidence.sh --gid <gid> --event qa-plan|qa-passed|qa-blocked|qa-failed [--reason <t>]
#
# Bundle /tmp/agent-qa-evidence-<gid>-<event>.md, in this order:
#   task name + notes; every dev run report attached to the task (REPORT_ATTACH_RE,
#   newest first, the local /tmp copy as fallback); the PR body and diff at the
#   pinned sha; then per event:
#     qa-plan     the candidate plan /tmp/qa-plan-<gid>.md
#     verdicts    the approved plan, the staged report + comment (qa-verdict.sh
#                 copies them to <QA_DIR>/report.md and comment.txt before judging),
#                 attempt-log lines since run-started, proof frame names written
#                 since run-started, and the snapshot comparison
# The judge runs with no tools, so frames are listed by name and mtime only.
# Clock lines (generated:) stay out of the hash so an unchanged bundle reuses the
# cached verdict.
#
# Prints: path=<bundle> hash=<16 hex>.  Exit: 0 ok | 1 error | 2 usage
set -uo pipefail
source "$HOME/.cursor/skills/qa-run/scripts/lib.sh"
source "$QA_H/lib/attach-names.sh"

GID="" EVENT="" REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --base|--offline) [ "$1" = --base ] && shift 2 || shift ;;
    *) echo "qa-evidence: unknown arg $1" >&2; exit 2 ;;
  esac
done
case "$EVENT" in qa-plan|qa-passed|qa-blocked|qa-failed) ;; *) echo "usage: qa-evidence.sh --gid <gid> --event qa-plan|qa-passed|qa-blocked|qa-failed" >&2; exit 2 ;; esac
[ -n "$GID" ] || exit 2

QD=$(qa_dir "$GID")
OUT="/tmp/agent-qa-evidence-$GID-$EVENT.md"
TMP="$OUT.tmp"; : > "$TMP"
line() { printf '%s\n' "$*" >> "$TMP"; }
capped() { head -c "$2" "$1" >> "$TMP"; [ "$(wc -c < "$1")" -le "$2" ] || line "[... truncated at $2 bytes]"; line ""; }

TASK=$(qa_task_json "$GID") || { echo "qa-evidence: Asana task read failed" >&2; exit 1; }
line "# QA evidence: $EVENT"
line "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ -n "$REASON" ] && line "reason: $REASON"
line ""
line "## Task"
line "name: $(printf '%s' "$TASK" | jq -r .data.name)"
printf '%s' "$TASK" | jq -r .data.notes | head -c 6000 >> "$TMP"; line ""; line ""

line "## Dev run reports (newest first)"
W="/tmp/agent-qa-evidence-$GID-work"; mkdir -p "$W"
N=0
while IFS=$'\t' read -r agid aname acreated; do
  [ -n "$agid" ] || continue
  printf '%s' "$aname" | grep -qE "$REPORT_ATTACH_RE" || continue
  N=$((N + 1)); [ "$N" -le 3 ] || break
  URL=$(qa_asana_get "attachments/$agid?opt_fields=download_url" | jq -r '.data.download_url // empty')
  if [ -n "$URL" ] && curl -sf --max-time 30 -o "$W/r$N.md" "$URL"; then
    line "### $aname ($acreated)"; capped "$W/r$N.md" 16000
  else
    line "### $aname ($acreated): download failed"
  fi
done < <(qa_attachments "$GID" | sort -t$'\t' -k3 -r)
if [ "$N" = 0 ]; then
  LOCAL=$(ls -t /tmp/agent-run-report-"$GID"-*.md 2>/dev/null | head -1)
  if [ -n "$LOCAL" ]; then line "### local copy $(basename "$LOCAL")"; capped "$LOCAL" 16000
  else line "_No dev run report found._"; line ""; fi
fi

line "## Pull request at the pinned sha"
if [ -f "$QD/pinned.json" ]; then
  PR_URL=$(jq -r .pr_url "$QD/pinned.json"); SHA=$(jq -r .sha "$QD/pinned.json")
  line "pr: $PR_URL"; line "pinned_sha: $SHA"
  gh pr view "$PR_URL" --json body -q .body 2>/dev/null > "$W/body.md" && { line "### PR body"; capped "$W/body.md" 6000; }
  gh pr diff "$PR_URL" 2>/dev/null > "$W/diff.patch" && { line "### Diff"; line '```diff'; capped "$W/diff.patch" 40000; line '```'; }
else
  line "_No pinned PR (qa-start.sh did not reach the pin)._"; line ""
fi

if [ "$EVENT" = qa-plan ]; then
  PLAN=$(qa_plan_file "$GID")
  line "## Candidate plan ($PLAN)"
  if [ -s "$PLAN" ]; then capped "$PLAN" 20000; else line "_Plan file missing or empty._"; line ""; fi
else
  line "## Approved plan"
  if [ -s "$QD/plan.md" ]; then capped "$QD/plan.md" 20000
  elif [ -s "$(qa_plan_file "$GID")" ]; then line "_No approved plan in the state dir; the working plan follows (an abandon before the gate)._"; capped "$(qa_plan_file "$GID")" 20000
  else line "_None._"; line ""; fi
  line "## QA report (staged)"
  if [ -s "$QD/report.md" ]; then capped "$QD/report.md" 30000; else line "_Missing._"; line ""; fi
  line "## QA comment (staged)"
  if [ -s "$QD/comment.txt" ]; then capped "$QD/comment.txt" 8000; else line "_Missing._"; line ""; fi
  STARTED=$(cat "$QD/run-started" 2>/dev/null)
  line "## Attempt log since run start (${STARTED:-no run-started marker})"
  ALOG="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/attempts/$GID.jsonl"
  if [ -f "$ALOG" ] && [ -n "$STARTED" ]; then
    jq -r --arg s "$STARTED" 'select(.ts >= $s) | "\(.ts) [\(.category // "-")] \(.action) -> \(.result)"' "$ALOG" 2>/dev/null | tail -60 >> "$TMP"
  else
    line "_None._"
  fi
  line ""
  line "## Proof frames written since run start"
  if [ -n "$STARTED" ]; then
    MARK="$W/started.ref"; touch -d "$STARTED" "$MARK" 2>/dev/null || touch -t "$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$STARTED" +%Y%m%d%H%M.%S 2>/dev/null)" "$MARK" 2>/dev/null
    find -H /tmp -maxdepth 1 -name "agent-proof-$GID-*.png" -newer "$MARK" 2>/dev/null | sort | sed 's#^#- #' >> "$TMP"
  fi
  line ""
  line "## Snapshot check"
  if [ -f "$QD/snapshot.json" ] && [ -f "$QD/pinned.json" ]; then
    D=$(qa_snapshot_diff "$QD/snapshot.json" "$(jq -r .repo_dir "$QD/pinned.json")")
    if [ -n "$D" ]; then line "differs: $D"; else line "matches the snapshot taken at QA start"; fi
  else
    line "_No snapshot._"
  fi
fi

HASH=$(grep -v -E '^generated: ' "$TMP" | shasum -a 256 | cut -c1-16)
line ""; line "evidence_hash: $HASH"
mv -f "$TMP" "$OUT"
echo "path=$OUT hash=$HASH"
