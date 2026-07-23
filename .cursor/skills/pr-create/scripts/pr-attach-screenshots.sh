#!/usr/bin/env bash
# pr-attach-screenshots.sh — Attach test-evidence screenshots to a GitHub PR.
#
# GitHub has NO official API for uploading images into PR comments, so this
# uploads the images to a dedicated assets branch in the (public) infra repo via
# the Git Data API — keeping binary blobs OUT of the product repos' history —
# then posts ONE PR comment embedding the raw.githubusercontent.com URLs, which
# render inline on public repos.
#
# Usage:
#   pr-attach-screenshots.sh --repo <owner/repo> --pr <num> \
#     [--title "Test evidence"] <png> [<png>...]
#
# Each image may carry a caption via its filename: 01-quote-rendered.png →
# caption "quote rendered". Order on the comment = argument order.
#
# HACK-FORCED evidence: a filename carrying the literal token HACKED (e.g.
# agent-proof-<gid>-01-HACKED-empty-state.png, per build-and-test
# `hack-verify-visual-changes`) captured a state forced by an uncommitted local
# hack, not by the natural trigger. Such an image is captioned with a 🩹 marker
# and the comment carries a banner, so a reviewer can never mistake it for an
# organically reproduced state. Detection is on the filename alone — no caller
# flag, no agent judgement.
#
# Exit codes: 0 = comment posted, 1 = error, 2 = no images given.

set -euo pipefail

ASSETS_REPO="EdgeApp/edge-dev-agents"
ASSETS_BRANCH="agent-pr-assets"

REPO=""; PR=""; TITLE="Test evidence"
IMAGES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2";  shift 2 ;;
    --pr)    PR="$2";    shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    *) IMAGES+=("$1"); shift ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "Usage: pr-attach-screenshots.sh --repo <owner/repo> --pr <num> <png...>" >&2; exit 1; }
[[ ${#IMAGES[@]} -gt 0 ]] || { echo "No images given" >&2; exit 2; }
for f in "${IMAGES[@]}"; do [[ -f "$f" ]] || { echo "Not found: $f" >&2; exit 1; }; done

REPO_NAME="${REPO#*/}"
DEST_DIR="assets/${REPO_NAME}/pr-${PR}"
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { echo ">> pr-attach-screenshots: $*" >&2; }

# ── Ensure the assets branch exists (orphan, created on first use) ────────────
if ! gh api "repos/$ASSETS_REPO/git/ref/heads/$ASSETS_BRANCH" >/dev/null 2>&1; then
  log "assets branch missing — creating orphan $ASSETS_BRANCH"
  README_BLOB=$(gh api "repos/$ASSETS_REPO/git/blobs" -f content="$(printf 'Agent PR test-evidence screenshots. Auto-managed by pr-attach-screenshots.sh; safe to prune old PR dirs.' | base64)" -f encoding=base64 --jq .sha)
  TREE=$(gh api "repos/$ASSETS_REPO/git/trees" \
    -f 'tree[][path]=README.md' -f 'tree[][mode]=100644' -f 'tree[][type]=blob' -f "tree[][sha]=$README_BLOB" --jq .sha)
  COMMIT=$(gh api "repos/$ASSETS_REPO/git/commits" -f message="init agent-pr-assets" -f tree="$TREE" --jq .sha)
  gh api "repos/$ASSETS_REPO/git/refs" -f ref="refs/heads/$ASSETS_BRANCH" -f sha="$COMMIT" >/dev/null
  log "created $ASSETS_BRANCH @ $COMMIT"
fi

# ── Upload blobs + build one commit containing all images ─────────────────────
HEAD_SHA=$(gh api "repos/$ASSETS_REPO/git/ref/heads/$ASSETS_BRANCH" --jq .object.sha)
BASE_TREE=$(gh api "repos/$ASSETS_REPO/git/commits/$HEAD_SHA" --jq .tree.sha)

# Tree entries are accumulated as JSON via node (base64 payloads exceed ARG_MAX
# as -f args, so each blob is POSTed via --input from a temp JSON file).
ENTRIES="[]"
URLS=()
for f in "${IMAGES[@]}"; do
  base="$(basename "$f")"
  safe="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')"
  path="$DEST_DIR/$STAMP-$safe"
  tmp=$(mktemp)
  node -e '
    const fs=require("fs");
    const [src,out]=process.argv.slice(1);
    fs.writeFileSync(out, JSON.stringify({content: fs.readFileSync(src).toString("base64"), encoding:"base64"}));
  ' "$f" "$tmp"
  sha=$(gh api "repos/$ASSETS_REPO/git/blobs" --input "$tmp" --jq .sha)
  rm -f "$tmp"
  ENTRIES=$(node -e '
    const [entries,path,sha]=process.argv.slice(1);
    const a=JSON.parse(entries); a.push({path, mode:"100644", type:"blob", sha});
    console.log(JSON.stringify(a));
  ' "$ENTRIES" "$path" "$sha")
  URLS+=("https://raw.githubusercontent.com/$ASSETS_REPO/$ASSETS_BRANCH/$path")
  log "uploaded $base → $path"
done

TREE_JSON=$(mktemp)
node -e '
  const [baseTree,entries,out]=process.argv.slice(1);
  require("fs").writeFileSync(out, JSON.stringify({base_tree: baseTree, tree: JSON.parse(entries)}));
' "$BASE_TREE" "$ENTRIES" "$TREE_JSON"
NEW_TREE=$(gh api "repos/$ASSETS_REPO/git/trees" --input "$TREE_JSON" --jq .sha)
rm -f "$TREE_JSON"
NEW_COMMIT=$(gh api "repos/$ASSETS_REPO/git/commits" \
  -f message="evidence: $REPO_NAME#$PR (${#IMAGES[@]} screenshot(s))" \
  -f tree="$NEW_TREE" -f "parents[]=$HEAD_SHA" --jq .sha)
gh api -X PATCH "repos/$ASSETS_REPO/git/refs/heads/$ASSETS_BRANCH" -f sha="$NEW_COMMIT" >/dev/null
log "committed $NEW_COMMIT to $ASSETS_BRANCH"

# ── Post ONE PR comment embedding all images ──────────────────────────────────
ANY_HACKED=false
for f in "${IMAGES[@]}"; do
  [[ "$(basename "$f")" == *HACKED* ]] && ANY_HACKED=true
done

BODY=$(mktemp)
{
  if $ANY_HACKED; then
    echo "## 📸🩹 $TITLE"
    echo
    echo "> 🩹 **Some screenshots below are HACK-FORCED.** The marked frames show a state forced by a temporary uncommitted local edit (the natural trigger could not be reproduced on the sim). The hack is not in this PR's diff; the pixels prove the rendering, not the trigger."
  else
    echo "## 📸 $TITLE"
  fi
  echo
  i=0
  for f in "${IMAGES[@]}"; do
    base="$(basename "$f")"
    # caption: filename minus extension, minus the agent-proof-<gid>- and
    # order-number prefixes, dashes → spaces
    cap="$(printf '%s' "${base%.*}" | sed -E 's/^agent-proof-[0-9]+-//; s/^[0-9]+[-_]//; s/[-_]+/ /g')"
    if [[ "$base" == *HACKED* ]]; then
      # Strip the marker out of the words and re-add it as an explicit label:
      cap="$(printf '%s' "$cap" | sed -E 's/[[:space:]]*HACKED[[:space:]]*/ /g; s/^ +| +$//g')"
      cap="🩹 HACK-FORCED: ${cap}"
    fi
    echo "**${cap}**"
    echo
    echo "<img src=\"${URLS[$i]}\" width=\"360\" alt=\"${cap}\" />"
    echo
    i=$((i+1))
  done
  echo "_Captured by the agent's in-app test run (build-and-test)._"
} > "$BODY"
gh pr comment "$PR" --repo "$REPO" --body-file "$BODY" >/dev/null
rm -f "$BODY"
log "PASS — posted 1 comment with ${#IMAGES[@]} screenshot(s) to $REPO#$PR"
