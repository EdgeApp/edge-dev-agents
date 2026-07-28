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
#     [--title "Test evidence"] [--hack-note "<what was hacked>"] <png> [<png>...]
#
# Each image may carry a caption via its filename: 01-quote-rendered.png →
# caption "quote rendered". The agent-proof-<gid>- and NN order prefixes are
# stripped robustly, so the caption is just the short human slug. Order on the
# comment = argument order.
#
# SCALING: every image is downscaled to max width 720px (ratio preserved)
# before upload — 2x the comment's 360px render width, so it stays crisp on
# retina while the blob shrinks ~4x. Originals on disk are never mutated
# (eval/validator checks stat the original /tmp paths).
#
# HACK-FORCED evidence: a filename carrying the literal token HACKED (e.g.
# agent-proof-<gid>-01-HACKED-empty-state.png, per build-and-test
# `hack-verify-visual-changes`) captured a state forced by an uncommitted local
# hack, not by the natural trigger. Such an image is captioned with a 🪓 marker
# and the comment banner states WHAT was hacked, taken from --hack-note (one
# short line, e.g. "hard-coded the empty-state branch true in WalletList").
# --hack-note is REQUIRED when any HACKED image is present, so the banner is
# specific instead of a repeated generic paragraph. Detection is on the
# filename alone — no caller flag, no agent judgement.
#
# Exit codes: 0 = comment posted, 1 = error, 2 = no images given.

set -euo pipefail

ASSETS_REPO="EdgeApp/edge-dev-agents"
ASSETS_BRANCH="agent-pr-assets"

REPO=""; PR=""; TITLE="Test evidence"; HACK_NOTE=""
IMAGES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2";      shift 2 ;;
    --pr)        PR="$2";        shift 2 ;;
    --title)     TITLE="$2";     shift 2 ;;
    --hack-note) HACK_NOTE="$2"; shift 2 ;;
    *) IMAGES+=("$1"); shift ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "Usage: pr-attach-screenshots.sh --repo <owner/repo> --pr <num> [--hack-note '<what was hacked>'] <png...>" >&2; exit 1; }
[[ ${#IMAGES[@]} -gt 0 ]] || { echo "No images given" >&2; exit 2; }
for f in "${IMAGES[@]}"; do [[ -f "$f" ]] || { echo "Not found: $f" >&2; exit 1; }; done

ANY_HACKED=false
for f in "${IMAGES[@]}"; do
  [[ "$(basename "$f")" == *HACKED* ]] && ANY_HACKED=true
done
if $ANY_HACKED && [[ -z "$HACK_NOTE" ]]; then
  echo "HACKED image(s) present: pass --hack-note '<one short line: WHAT was hacked>' (e.g. --hack-note 'hard-coded the empty-state branch true in WalletList') so the PR banner is specific. See build-and-test hack-verify-visual-changes." >&2
  exit 1
fi

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

# ── Downscale to max width 720 (ratio preserved) into temp copies ─────────────
# 720 = 2x the comment's 360px render width (crisp on retina, ~4x smaller blob).
# Originals are never mutated; narrower images pass through unscaled.
MAX_W=720
SCALE_DIR=$(mktemp -d)
trap 'rm -rf "$SCALE_DIR"' EXIT
UPLOADS=()
for f in "${IMAGES[@]}"; do
  w=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  if [[ -n "$w" && "$w" -gt "$MAX_W" ]]; then
    scaled="$SCALE_DIR/$(basename "$f")"
    if sips --resampleWidth "$MAX_W" "$f" --out "$scaled" >/dev/null 2>&1; then
      UPLOADS+=("$scaled")
      log "scaled $(basename "$f") ${w}px → ${MAX_W}px"
      continue
    fi
    log "WARN: sips failed on $(basename "$f") — uploading original"
  fi
  UPLOADS+=("$f")
done

# ── Upload blobs + build one commit containing all images ─────────────────────
HEAD_SHA=$(gh api "repos/$ASSETS_REPO/git/ref/heads/$ASSETS_BRANCH" --jq .object.sha)
BASE_TREE=$(gh api "repos/$ASSETS_REPO/git/commits/$HEAD_SHA" --jq .tree.sha)

# Tree entries are accumulated as JSON via node (base64 payloads exceed ARG_MAX
# as -f args, so each blob is POSTed via --input from a temp JSON file).
ENTRIES="[]"
URLS=()
for f in "${UPLOADS[@]}"; do
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
BODY=$(mktemp)
{
  if $ANY_HACKED; then
    echo "## 📸🪓 $TITLE"
    echo
    echo "> 🪓 **Hack-forced evidence:** ${HACK_NOTE%.}. Temporary uncommitted edit, reverted before commit; the marked frames prove the rendering, not the trigger."
  else
    echo "## 📸 $TITLE"
  fi
  echo
  i=0
  for f in "${IMAGES[@]}"; do
    base="$(basename "$f")"
    # caption: the short human slug only — strip extension, any agent-proof
    # prefix (with or without a gid, any case/separator), and the NN order
    # number; dashes → spaces
    cap="$(printf '%s' "${base%.*}" | sed -E 's/^[Aa][Gg][Ee][Nn][Tt][-_]?[Pp][Rr][Oo][Oo][Ff][-_]//; s/^[0-9]+[-_]//; s/^[0-9]+[-_]//; s/[-_]+/ /g')"
    if [[ "$base" == *HACKED* ]]; then
      # Strip the marker out of the words and re-add it as an explicit label:
      cap="$(printf '%s' "$cap" | sed -E 's/[[:space:]]*HACKED[[:space:]]*/ /g; s/^ +| +$//g')"
      cap="🪓 HACK-FORCED: ${cap}"
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
