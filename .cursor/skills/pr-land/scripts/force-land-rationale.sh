#!/usr/bin/env bash
# force-land-rationale.sh — post the pre-merge rationale comment a Force Land
# (admin) merge requires, and write the marker the merge gate reads.
#
# WHY: an admin merge lands with no approving review, so the PR carries no
# record of why review was skipped — a reader of the merge sees an admin
# override and nothing else. This puts that record ON THE PR, immediately
# before the merge: the change class that made review unnecessary (a docs-only
# change, a minor UI-only change) and the authority it landed under. The Asana
# disclosure required by pr-land `force-land-review-bypass` stays; it is read
# by a different audience.
#
# The comment goes out through pr-address.sh comment, so the body runs the same
# no-slop lint as every other outbound PR prose.
#
# Refusals (nothing is posted, no marker is written):
#   - the task's Force Land field is not `Land Approved`
#   - `gh pr checks` is not fully green: an admin merge never rides over a red,
#     queued, or running check (pr-land `force-land-review-bypass`)
#
# Usage:
#   force-land-rationale.sh --owner <o> --repo <r> --pr <n> --task-gid <gid> \
#     --rationale "<one clause: why this change needed no review>"
#
# Exit: 0 = posted and marker written, 1 = error, 2 = usage / no authority.
set -euo pipefail

OWNER="" REPO="" PR="" TASK_GID="" RATIONALE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --task-gid) TASK_GID="$2"; shift 2 ;;
    --rationale) RATIONALE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" || -z "$TASK_GID" || -z "$RATIONALE" ]]; then
  echo "usage: force-land-rationale.sh --owner <o> --repo <r> --pr <n> --task-gid <gid> --rationale \"<text>\"" >&2
  exit 2
fi

# Authority: the operator's Force Land field, read live. No field, no comment —
# and therefore no marker, so the gate keeps the admin merge blocked.
AUTHORITY=$("$HOME/.cursor/skills/asana-force-land.sh" "$TASK_GID")
if [[ "$AUTHORITY" != "land-approved" ]]; then
  echo "BLOCKED: task $TASK_GID has no Force Land authority (asana-force-land.sh: $AUTHORITY). An admin merge needs it; a human approval lands through auto-merge instead." >&2
  exit 2
fi

# Checks: green or nothing. `gh pr checks` exits 0 only when every check has
# completed successfully (8 = still pending, 1 = failing).
if ! gh pr checks "$PR" --repo "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "BLOCKED: checks on $OWNER/$REPO#$PR are not all green. Wait for the next clean BLOCKED_ON_REVIEW verdict before force landing." >&2
  exit 1
fi

SHA=$(gh pr view "$PR" --repo "$OWNER/$REPO" --json headRefOid -q .headRefOid)

BODY_FILE=$(mktemp /tmp/force-land-rationale.XXXXXX)
trap 'rm -f "$BODY_FILE"' EXIT
cat > "$BODY_FILE" <<EOF
Landing this without a review.

- Rationale: $RATIONALE
- Authority: Force Land = Land Approved on the linked Asana task ($TASK_GID)
- Bypassed: the approving-review requirement only. Every required check is green on \`$SHA\`.
EOF

"$HOME/.cursor/skills/pr-address/scripts/pr-address.sh" comment \
  --owner "$OWNER" --repo "$REPO" --pr "$PR" --body-file "$BODY_FILE"

MARKER="/tmp/agent-force-land-rationale-$OWNER-$REPO-$PR.json"
jq -n --arg owner "$OWNER" --arg repo "$REPO" --arg pr "$PR" --arg sha "$SHA" \
  --arg gid "$TASK_GID" --arg rationale "$RATIONALE" --arg at "$(date -u +%FT%TZ)" \
  '{owner: $owner, repo: $repo, pr: $pr, headSha: $sha, taskGid: $gid, rationale: $rationale, postedAt: $at}' \
  > "$MARKER"

echo ">> force-land rationale posted on $OWNER/$REPO#$PR (head $SHA)"
echo ">> marker: $MARKER"
