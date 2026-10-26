#!/usr/bin/env bash
# qa-start.sh: enter the QA pass for a task and print which phase this session runs.
#
# Usage: qa-start.sh [--gid <gid>]     (default $AGENT_TASK_GID)
#
# Phase is decided from the pass state dir (lib.sh header lists the files):
#   verdict.json present            -> PHASE=done (the verdict already posted)
#   approved present                -> PHASE=run: an ios lane needs AGENT_SIM_UDID
#                                      (the watcher spawns every QA session with a
#                                      pool sim and slot); writes run-started once,
#                                      sets agent_qa=Running
#   otherwise                       -> PHASE=plan: resolves the dev worktree (re-
#                                      provisioned on the PR head branch with
#                                      setup-task-workspace.sh --existing-branch when it
#                                      was pruned), pins the PR head sha, takes the
#                                      snapshot once, sets agent_qa=Planning
#
# The pinned sha must equal the open PR's head. A merged/closed PR, a missing PR or
# a HEAD that differs from the PR head exits 3 with REASON=<text>: the caller ends
# the pass with `qa-verdict.sh --abandon "<text>"`.
#
# Output: KEY=value lines (PHASE, REPO_DIR, SHA, PR_URL, PLAN_FILE, APPROVED_PLAN, LANE).
# Exit: 0 ok | 3 cannot test (REASON line) | 1 error | 2 usage
set -uo pipefail
source "$HOME/.cursor/skills/qa-run/scripts/lib.sh"

GID="${AGENT_TASK_GID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    *) echo "qa-start: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] || { echo "usage: qa-start.sh [--gid <gid>]" >&2; exit 2; }
[ "${AGENT_MODE:-}" = qa ] || { echo "qa-start: AGENT_MODE is not qa; this script runs only inside a qa-asana-<gid> session" >&2; exit 2; }

QD=$(qa_dir "$GID"); mkdir -p "$QD"
cannot() { echo "REASON=$1"; exit 3; }

if [ -f "$QD/verdict.json" ]; then
  echo "PHASE=done"
  echo "VERDICT=$(jq -r .verdict "$QD/verdict.json")"
  exit 0
fi

if [ -f "$QD/approved" ]; then
  LANE=$(cat "$QD/approved")
  [ "$LANE" != ios ] || [ -n "${AGENT_SIM_UDID:-}" ] || cannot "approved ios plan but this session has no pool sim (AGENT_SIM_UDID unset); the watcher spawns every QA session with one"
  REPO_DIR=$(jq -r .repo_dir "$QD/pinned.json")
  DIFF=$(qa_snapshot_diff "$QD/snapshot.json" "$REPO_DIR")
  [ -z "$DIFF" ] || cannot "worktree changed since the QA snapshot ($DIFF); the dev tree moved under QA"
  [ -f "$QD/run-started" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$QD/run-started"
  "$QA_H/set-agent-field.sh" "$GID" agent_qa Running >/dev/null || { echo "qa-start: could not set agent_qa=Running" >&2; exit 1; }
  echo "PHASE=run"
  echo "REPO_DIR=$REPO_DIR"
  echo "SHA=$(jq -r .sha "$QD/pinned.json")"
  echo "PR_URL=$(jq -r .pr_url "$QD/pinned.json")"
  echo "APPROVED_PLAN=$QD/plan.md"
  echo "LANE=$LANE"
  echo "SIM=$AGENT_SIM_UDID METRO_PORT=${AGENT_METRO_PORT:-}"
  exit 0
fi

# ---- PHASE=plan ----
REPO_DIR=$(qa_repo_dir "$GID")
if [ -z "$REPO_DIR" ]; then
  # Re-provision on the PR head branch: find the task's GitHub PR attachment.
  PR_LINK=$(qa_asana_get "tasks/$GID/attachments?opt_fields=view_url,name&limit=100" \
    | jq -r '[.data[]? | (.view_url // .name // "") | select(test("github\\.com/[^/]+/[^/]+/pull/[0-9]+"))][0] // empty')
  [ -n "$PR_LINK" ] || cannot "dev worktree is gone and the task has no GitHub PR attachment to re-provision from"
  REPO=$(printf '%s' "$PR_LINK" | sed -E 's#.*github\.com/[^/]+/([^/]+)/pull/.*#\1#')
  BRANCH=$(gh pr view "$PR_LINK" --json headRefName -q .headRefName 2>/dev/null)
  [ -n "$BRANCH" ] || cannot "could not read the head branch of $PR_LINK"
  REPO_DIR=$("$QA_H/setup-task-workspace.sh" --task-gid "$GID" --repo "$REPO" --existing-branch "$BRANCH" 2>/dev/null | tail -1)
  [ -d "$REPO_DIR" ] || cannot "re-provisioning the dev worktree on $BRANCH failed"
fi

PR_JSON=$(cd "$REPO_DIR" && gh pr view --json url,headRefOid,state 2>/dev/null)
[ -n "$PR_JSON" ] || cannot "no pull request for the worktree branch in $REPO_DIR"
PR_URL=$(printf '%s' "$PR_JSON" | jq -r .url)
PR_STATE=$(printf '%s' "$PR_JSON" | jq -r .state)
PR_HEAD=$(printf '%s' "$PR_JSON" | jq -r .headRefOid)
[ "$PR_STATE" = OPEN ] || cannot "the PR $PR_URL is $PR_STATE; QA tests an open PR head only"
HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
[ "$HEAD" = "$PR_HEAD" ] || cannot "worktree HEAD ${HEAD:0:10} is not the PR head ${PR_HEAD:0:10}; QA never checks anything out"

[ -f "$QD/snapshot.json" ] || qa_snapshot "$REPO_DIR" > "$QD/snapshot.json"
[ -f "$QD/pinned.json" ] || jq -cn --arg r "$REPO_DIR" --arg s "$HEAD" --arg u "$PR_URL" '{repo_dir:$r, sha:$s, pr_url:$u}' > "$QD/pinned.json"
PINNED=$(jq -r .sha "$QD/pinned.json")
[ "$PINNED" = "$HEAD" ] || cannot "the PR head moved from ${PINNED:0:10} to ${HEAD:0:10} during this QA pass"

"$QA_H/set-agent-field.sh" "$GID" agent_qa Planning >/dev/null || { echo "qa-start: could not set agent_qa=Planning" >&2; exit 1; }
echo "PHASE=plan"
echo "REPO_DIR=$REPO_DIR"
echo "SHA=$HEAD"
echo "PR_URL=$PR_URL"
echo "PLAN_FILE=$(qa_plan_file "$GID")"
