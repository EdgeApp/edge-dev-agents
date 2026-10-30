#!/usr/bin/env bash
# qa-verdict.sh: post a QA verdict. The ONLY writer of a terminal agent_qa value, the
# QA comment and the <N>-qa-report.md attachment.
#
# Usage:
#   qa-verdict.sh [--gid <gid>] --verdict Passed|Blocked|Failed --report <f> --comment <f>
#   qa-verdict.sh [--gid <gid>] --verdict Skipped     (qa-gate.sh calls this on a skip allow)
#   qa-verdict.sh  --gid <gid> --abandon "<reason>"  (a wall before any case ran; also
#                                                     the watcher's respawn cap)
#
# Order, each step refusing on failure:
#   1. Snapshot: the dev worktree matches <QA_DIR>/snapshot.json (HEAD, porcelain,
#      dep links, config.json/env.json/keys.json hashes). Not checked on --abandon.
#   2. Pinned sha: the PR head still equals the sha pinned at qa-start.
#   3. Report shape: frontmatter `verdict:` equals --verdict; Blocked carries
#      `blocker_class: precondition|harness|task-drafting`; Failed carries a
#      `## Failed cases` section (check-followup-scope.sh hands that section to the
#      dev followup as its scope).
#   4. Judge: completion-judge.sh --event qa-passed|qa-blocked|qa-failed on the staged
#      report and comment (<QA_DIR>/report.md, comment.txt). Skipped needs the cached
#      qa-plan allow instead. --abandon is not judged: its walls are mechanical.
#   5. Cap: a Failed verdict when the ledger already holds watcher.qa_rearm_cap Failed
#      verdicts posts as Blocked "auto re-arm cap reached".
#   6. Comment (asana-task-update.sh --comment-file), then the report attachment
#      (qa_attach_name with the next qa ordinal), then agent_qa, then the ledger
#      line, <QA_DIR>/verdict.json and a detached token-ledger.sh record (skipped
#      without a session id). Inside a qa-asana session the session is
#      killed about 45s later.
# Exit: 0 posted | 1 judge deny (items on stdout) | 3 judge unavailable |
#       4 refused (snapshot, pinned sha or report shape; reason on stdout) | 2 usage
set -uo pipefail
source "$HOME/.cursor/skills/qa-run/scripts/lib.sh"
source "$QA_H/lib/attach-names.sh"

GID="${AGENT_TASK_GID:-}" VERDICT="" REPORT="" COMMENT="" ABANDON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --verdict) VERDICT="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --comment) COMMENT="$2"; shift 2 ;;
    --abandon) ABANDON="$2"; VERDICT=Blocked; shift 2 ;;
    *) echo "qa-verdict: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] || { echo "usage: qa-verdict.sh --gid <gid> --verdict <V> ..." >&2; exit 2; }
case "$VERDICT" in Passed|Blocked|Failed|Skipped) ;; *) echo "qa-verdict: --verdict must be Passed, Blocked, Failed or Skipped" >&2; exit 2 ;; esac
if [ -z "$ABANDON" ] && [ "$VERDICT" != Skipped ]; then
  [ -s "$REPORT" ] && [ -s "$COMMENT" ] || { echo "qa-verdict: --report and --comment files are required for $VERDICT" >&2; exit 2; }
fi

QD=$(qa_dir "$GID"); mkdir -p "$QD"
refuse() { echo "REFUSED: $1"; exit 4; }
[ -f "$QD/verdict.json" ] && refuse "a verdict already posted for this pass ($(jq -r .verdict "$QD/verdict.json")); set agent_qa=Pending by hand for a fresh pass"

PR_URL=$(jq -r '.pr_url // empty' "$QD/pinned.json" 2>/dev/null)
SHA=$(jq -r '.sha // empty' "$QD/pinned.json" 2>/dev/null)
REPO_DIR=$(jq -r '.repo_dir // empty' "$QD/pinned.json" 2>/dev/null)

if [ -z "$ABANDON" ]; then
  [ -n "$SHA" ] || refuse "no pinned.json; qa-start.sh never pinned this pass"
  # 1. snapshot
  D=$(qa_snapshot_diff "$QD/snapshot.json" "$REPO_DIR")
  [ -z "$D" ] || refuse "the worktree differs from the QA-start snapshot in: $D. Revert every config switch and stray file (git status in $REPO_DIR), then rerun"
  # 2. pinned sha
  HEAD_NOW=$(gh pr view "$PR_URL" --json headRefOid -q .headRefOid 2>/dev/null)
  [ "$HEAD_NOW" = "$SHA" ] || refuse "the PR head moved from ${SHA:0:10} to ${HEAD_NOW:0:10}; this result is stale. End the pass with qa-verdict.sh --abandon \"dev branch moved during QA\""
fi

W="$QD/work"; mkdir -p "$W"
PLAN_SRC="$QD/plan.md"; [ -s "$PLAN_SRC" ] || PLAN_SRC=$(qa_plan_file "$GID")
fm() { awk -v k="$1" 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1{ if (index($0, k":")==1) { sub("^"k":[ ]*",""); print; exit } }' "$2"; }

# Generated report + comment for Skipped and --abandon.
if [ "$VERDICT" = Skipped ]; then
  JV="/tmp/agent-qa-verdict-$GID-qa-plan.json"
  [ "$(jq -r '.verdict // empty' "$JV" 2>/dev/null)" = allow ] || refuse "Skipped needs the qa-plan gate's allow; run qa-gate.sh"
  R=$(fm skip_reason "$PLAN_SRC")
  REPORT="$W/report.md"; COMMENT="$W/comment.txt"
  { printf -- '---\nverdict: Skipped\npr: %s\nsha: %s\n---\n\n# QA report\n\n## Verdict\n\nSkipped: %s\n\n## Plan\n\n' "$PR_URL" "$SHA" "$R"; cat "$PLAN_SRC"; } > "$REPORT"
  printf 'QA skipped this task: %s\nNo extra test case was worth running beyond what the dev run already proved. The approved plan is in the attached QA report.\n' "$R" > "$COMMENT"
elif [ -n "$ABANDON" ]; then
  REPORT="$W/report.md"; COMMENT="$W/comment.txt"
  { printf -- '---\nverdict: Blocked\nblocker_class: harness\npr: %s\nsha: %s\n---\n\n# QA report\n\n## Verdict\n\nBlocked before any case ran: %s\n' "${PR_URL:-unknown}" "${SHA:-unknown}" "$ABANDON"
    [ -s "$PLAN_SRC" ] && { printf '\n## Plan at the time\n\n'; cat "$PLAN_SRC"; }; } > "$REPORT"
  printf 'QA could not run on this task: %s\nNo case was tested and nothing was re-armed. Set agent_qa back to Pending to retry once the cause is fixed.\n' "$ABANDON" > "$COMMENT"
fi

# 3. report shape
RV=$(fm verdict "$REPORT")
[ "$RV" = "$VERDICT" ] || refuse "report frontmatter verdict is '$RV', expected '$VERDICT'"
if [ "$VERDICT" = Blocked ]; then
  case "$(fm blocker_class "$REPORT")" in precondition|harness|task-drafting) ;; *) refuse "a Blocked report needs blocker_class: precondition, harness or task-drafting" ;; esac
fi
if [ "$VERDICT" = Failed ]; then
  grep -q '^## Failed cases' "$REPORT" || refuse "a Failed report needs a '## Failed cases' section"
fi
[ "$REPORT" = "$QD/report.md" ] || cp -f "$REPORT" "$QD/report.md"
[ "$COMMENT" = "$QD/comment.txt" ] || cp -f "$COMMENT" "$QD/comment.txt"
REPORT="$QD/report.md"; COMMENT="$QD/comment.txt"

# 4. judge
if [ -z "$ABANDON" ] && [ "$VERDICT" != Skipped ]; then
  EV="qa-$(printf '%s' "$VERDICT" | tr '[:upper:]' '[:lower:]')"
  OUT=$("$QA_H/completion-judge.sh" --gid "$GID" --event "$EV" 2>&1); RC=$?
  printf '%s\n' "$OUT"
  case "$RC" in
    0) ;;
    1) echo "VERDICT GATE: deny. Fix each failed item (a Failed verdict without reproduction evidence is reclassified as Blocked), then rerun."; exit 1 ;;
    *) echo "VERDICT GATE: judge unavailable (rc $RC). Rerun once; a second failure ends the pass with --abandon."; exit 3 ;;
  esac
fi

# 5. cap
CAPPED=0
if [ "$VERDICT" = Failed ] && [ "$(qa_failed_count "$GID")" -ge "$(qa_rearm_cap)" ]; then
  CAPPED=1; VERDICT=Blocked
  awk 'NR>1 && !done && /^verdict: Failed$/ {print "verdict: Blocked"; print "blocker_class: harness"; done=1; next} {print}' "$REPORT" > "$W/r.tmp" && mv -f "$W/r.tmp" "$REPORT"
  { printf 'QA found a failure again, but the auto re-arm cap (%s) is reached, so the dev run was not re-armed. The operator decides the next step.\n\n' "$(qa_rearm_cap)"; cat "$COMMENT"; } > "$W/c.tmp" && mv -f "$W/c.tmp" "$COMMENT"
fi

# 6. post
AUP="$HOME/.cursor/skills/asana-task-update/scripts/asana-task-update.sh"
"$AUP" --task "$GID" --comment-file "$COMMENT" >"$W/post.log" 2>&1 || { cat "$W/post.log"; echo "qa-verdict: comment post failed; nothing else was written" >&2; exit 1; }
ORD=$(qa_attachments "$GID" | cut -f2 | next_attach_ordinal qa)
NAME=$(qa_attach_name "$ORD")
"$AUP" --task "$GID" --attach-file "$REPORT" --attach-name "$NAME" >>"$W/post.log" 2>&1 || { cat "$W/post.log"; echo "qa-verdict: report attach failed after the comment posted; attach $REPORT as $NAME by rerunning with the same files" >&2; exit 1; }
"$QA_H/set-agent-field.sh" "$GID" agent_qa "$VERDICT" >/dev/null || { echo "qa-verdict: agent_qa=$VERDICT write failed" >&2; exit 1; }

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -cn --arg ts "$TS" --arg gid "$GID" --arg v "$([ "$CAPPED" = 1 ] && echo Failed-capped || echo "$VERDICT")" --arg n "$NAME" --arg sha "$SHA" \
  '{ts:$ts, gid:$gid, verdict:$v, report:$n, sha:$sha}' >> "$(qa_ledger "$GID")"
jq -cn --arg ts "$TS" --arg v "$VERDICT" --arg n "$NAME" --argjson capped "$CAPPED" '{ts:$ts, verdict:$v, report:$n, capped:($capped==1)}' > "$QD/verdict.json"
[ -x "$HOME/.config/agent-watcher/token-ledger.sh" ] && nohup "$HOME/.config/agent-watcher/token-ledger.sh" record --gid "$GID" --kind qa \
  >>"${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/token-ledger.log" 2>&1 &
echo "POSTED: agent_qa=$VERDICT, comment, $NAME$([ "$CAPPED" = 1 ] && echo ' (auto re-arm cap reached)')"
if [ "${AGENT_MODE:-}" = qa ]; then
  qa_kill_self_later "$GID" 45
  echo "This QA session ends in about 45 seconds. End the turn now."
fi
