#!/usr/bin/env bash
# pr-evidence-migrate.sh — Convert a PR's legacy screenshot COMMENTS into the
# single commit-grouped evidence table in the PR body.
#
# For PRs whose frames were attached before the table existed. The images are
# already on the assets branch, so nothing is re-uploaded: this reads them out
# of the comments, writes the per-PR manifest, renders the table into the body,
# and (with --delete-comments) removes the comments it migrated.
#
# ATTRIBUTION is mechanical, never inferred from the picture. A batch of frames
# belongs to the newest commit whose AUTHOR date is at or before the comment's
# time; when that commit is a `fixup!`, the frames are filed under its TARGET
# subject, because autosquash will fold it there and a row keyed on the fixup
# would disappear.
#
# Usage:
#   pr-evidence-migrate.sh --repo <owner/repo> --pr <num> [--apply] [--delete-comments]
#
#   (default)           dry run: prints the mapping and exits, writing nothing
#   --apply             write the manifest and rewrite the PR body
#   --delete-comments   after a successful --apply, delete the migrated comments
#                       (refuses unless every image reached the body)
#
# AUTHORSHIP: refuses a PR opened by anyone but the authenticated user. This
# rewrites a body and deletes comments, so running it on a teammate's or an
# outside contributor's PR destroys their content. A task's Asana links reach
# every PR involved in the work, not only the ones you opened, so the caller's
# scope list cannot be trusted to have filtered them out.
#
# Exit: 0 ok, 1 error, 2 nothing to migrate, 4 not your PR.
set -euo pipefail
ASSETS_REPO="EdgeApp/edge-dev-agents"; ASSETS_BRANCH="agent-pr-assets"
REPO=""; PR=""; APPLY=false; DELETE=false; QUIET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --delete-comments) DELETE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "Usage: pr-evidence-migrate.sh --repo <owner/repo> --pr <num> [--apply] [--delete-comments]" >&2; exit 1; }
log() { $QUIET || echo ">> pr-evidence-migrate: $*" >&2; }

REPO_NAME="${REPO#*/}"; DEST_DIR="assets/${REPO_NAME}/pr-${PR}"
ME=$(gh api user --jq '.login' 2>/dev/null)
AUTHOR=$(gh api "repos/$REPO/pulls/$PR" --jq '.user.login' 2>/dev/null)
if [[ -z "$ME" || -z "$AUTHOR" ]]; then
  echo "could not resolve PR author or current user for $REPO#$PR" >&2; exit 1
fi
if [[ "$ME" != "$AUTHOR" ]]; then
  echo "$REPO#$PR is authored by $AUTHOR, not $ME — refusing (this edits the body and deletes comments)" >&2
  exit 4
fi

COMMENTS=$(gh api "repos/$REPO/issues/$PR/comments" --paginate)
COMMITS=$(gh api "repos/$REPO/pulls/$PR/commits" --paginate \
  --jq '[.[] | {sha: .sha, subject: (.commit.message | split("\n")[0]), date: .commit.author.date}]')
BODY=$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')

PLAN=$(node "$HOME/.cursor/skills/pr-create/scripts/pr-evidence-migrate.js" \
  "$COMMENTS" "$COMMITS" "$DEST_DIR") || exit $?
COUNT=$(node -e 'console.log(JSON.parse(process.argv[1]).entries.length)' "$PLAN")
[[ "$COUNT" -gt 0 ]] || { log "no screenshot comments found"; exit 2; }

if $QUIET; then
  node -e '
    const p = JSON.parse(process.argv[1])
    const groups = new Set(p.entries.map(e => e.subject)).size
    const hacked = p.entries.filter(e => e.hacked).length
    console.log(process.argv[2] + "#" + process.argv[3] + " frames=" + p.entries.length + " groups=" + groups + " hacked=" + hacked + " comments=" + p.commentIds.length)
  ' "$PLAN" "$REPO_NAME" "$PR"
else
  node -e '
    const p = JSON.parse(process.argv[1])
    const by = {}
    for (const e of p.entries) (by[e.subject] ||= []).push(e)
    for (const [s, es] of Object.entries(by)) {
      console.log("  " + s + "  (" + es.length + " frame(s)" + (es.some(e=>e.hacked) ? ", hack-forced present" : "") + ")")
      for (const e of es) console.log("      " + (e.hacked ? "HACKED " : "") + e.caption)
    }
    console.log("  comments to retire: " + p.commentIds.join(", "))
  ' "$PLAN"
fi

$APPLY || { log "DRY RUN — re-run with --apply to write"; exit 0; }

# ── manifest onto the assets branch (images are already there) ────────────────
MANIFEST=$(node -e 'const p=JSON.parse(process.argv[1]);console.log(JSON.stringify({version:1,entries:p.entries},null,2))' "$PLAN")
HEAD_SHA=$(gh api "repos/$ASSETS_REPO/git/ref/heads/$ASSETS_BRANCH" --jq .object.sha)
BASE_TREE=$(gh api "repos/$ASSETS_REPO/git/commits/$HEAD_SHA" --jq .tree.sha)
MT=$(mktemp); node -e 'const fs=require("fs");fs.writeFileSync(process.argv[2],JSON.stringify({content:Buffer.from(process.argv[1]).toString("base64"),encoding:"base64"}))' "$MANIFEST" "$MT"
MSHA=$(gh api "repos/$ASSETS_REPO/git/blobs" --input "$MT" --jq .sha); rm -f "$MT"
TT=$(mktemp); node -e 'require("fs").writeFileSync(process.argv[3],JSON.stringify({base_tree:process.argv[1],tree:[{path:process.argv[4],mode:"100644",type:"blob",sha:process.argv[2]}]}))' "$BASE_TREE" "$MSHA" "$TT" "$DEST_DIR/manifest.json"
NEW_TREE=$(gh api "repos/$ASSETS_REPO/git/trees" --input "$TT" --jq .sha); rm -f "$TT"
NEW_COMMIT=$(gh api "repos/$ASSETS_REPO/git/commits" -f message="evidence manifest: $REPO_NAME#$PR (migrated)" -f tree="$NEW_TREE" -f "parents[]=$HEAD_SHA" --jq .sha)
gh api -X PATCH "repos/$ASSETS_REPO/git/refs/heads/$ASSETS_BRANCH" -f sha="$NEW_COMMIT" >/dev/null
log "manifest committed ${NEW_COMMIT:0:8}"

NEW_BODY=$(node -e '
  const m = require(process.env.HOME + "/.cursor/skills/pr-create/scripts/pr-evidence-table.js")
  const [manifest, body, repo, pr, rawBase, commits] = process.argv.slice(1)
  process.stdout.write(m.splice(body, m.render(JSON.parse(manifest), { repo, pr, rawBase, commits: JSON.parse(commits) })))
' "$MANIFEST" "$BODY" "$REPO" "$PR" "https://raw.githubusercontent.com/$ASSETS_REPO/$ASSETS_BRANCH/$DEST_DIR/" "$COMMITS")
# GitHub caps a PR body at 65536 chars; past that the edit is rejected and the
# table would be lost, so refuse while the old body is still intact.
BODY_LEN=${#NEW_BODY}
if [[ "$BODY_LEN" -gt 60000 ]]; then
  echo "refusing: rendered body is $BODY_LEN chars, over the 60000 safety margin (GitHub caps at 65536). Prune frames for this PR." >&2
  exit 1
fi
BF=$(mktemp); printf '%s' "$NEW_BODY" > "$BF"
gh pr edit "$PR" --repo "$REPO" --body-file "$BF" >/dev/null; rm -f "$BF"
VERIFY=$(node -e '
  const [plan, body] = process.argv.slice(1)
  const p = JSON.parse(plan)
  const missing = p.entries.filter(e => !body.includes(e.path.split("/").pop())).length
  const sentinels = (body.match(/agent-test-evidence:(start|end)/g) || []).length
  console.log(missing === 0 && sentinels === 2 ? "ok" : "missing=" + missing + " sentinels=" + sentinels)
' "$PLAN" "$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')")
[[ "$VERIFY" == "ok" ]] || { echo "$REPO_NAME#$PR VERIFY-FAILED $VERIFY" >&2; exit 1; }
log "body updated with $COUNT frame(s)"

$DELETE || { log "PASS — comments left in place (pass --delete-comments to retire them)"; exit 0; }

# ── verify every migrated image reached the body before deleting anything ─────
LIVE=$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')
MISSING=$(node -e '
  const [plan, body] = process.argv.slice(1)
  const miss = JSON.parse(plan).entries.map(e => e.path.split("/").pop()).filter(f => !body.includes(f))
  console.log(miss.join(","))
' "$PLAN" "$LIVE")
[[ -z "$MISSING" ]] || { echo "refusing to delete: these frames are not in the body: $MISSING" >&2; exit 1; }
for id in $(node -e 'console.log(JSON.parse(process.argv[1]).commentIds.join(" "))' "$PLAN"); do
  gh api --method DELETE "repos/$REPO/issues/comments/$id" --silent && log "deleted comment $id"
done
log "PASS — $COUNT frame(s) in the body, migrated comments retired"
