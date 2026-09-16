#!/usr/bin/env bash
# pr-attach-screenshots.sh — Publish test-evidence screenshots into a PR body.
#
# GitHub has NO official API for uploading images into a PR, so this uploads the
# images to a dedicated assets branch in the (public) infra repo via the Git Data
# API — keeping binary blobs OUT of the product repos' history — then renders
# them as ONE commit-grouped table inside the PR BODY, between invisible HTML
# sentinels. raw.githubusercontent.com URLs render inline on public repos.
#
# The table is rebuilt from a per-PR manifest on every run, so a later re-test
# GROWS it in place instead of stacking another comment. Re-attaching the same
# file is a no-op. Layout, markers and the manifest contract: pr-evidence-table.js.
#
# Usage:
#   pr-attach-screenshots.sh --repo <owner/repo> --pr <num> \
#     [--commit <sha-or-subject>] [--hack-note "<what was hacked>"] <png> [<png>...]
#
#   --commit     which commit on the PR these frames evidence; accepts a sha
#                prefix or the exact commit subject. Default: the PR's newest
#                commit. Frames group under this commit's row in the table.
#   --hack-note  REQUIRED when any filename carries the HACKED token; one short
#                line naming the exact hack. It renders in that commit's header
#                cell, so every frame under it inherits the disclosure.
#
# FILENAME MARKERS (uppercase tokens; lowercase words are description only):
#   HACKED  the frame was forced by a temporary uncommitted edit
#   BEFORE  the frame shows behavior PRIOR to the fix
#   AFTER   explicitly the post-fix frame (optional; untokened = current HEAD)
# Uppercase is what makes a marker: "slider-before-slide" is a gesture, while
# "BEFORE-slider-resets" is a pre-fix frame.
#
# SCALING: every image is downscaled to max width 720px (ratio preserved) before
# upload — the table renders at 200px and links the 720px original. Originals on
# disk are never mutated (eval/validator checks stat the original /tmp paths).
#
# Exit codes: 0 = body updated, 1 = error, 2 = no images given.

set -euo pipefail

ASSETS_REPO="EdgeApp/edge-dev-agents"
ASSETS_BRANCH="agent-pr-assets"

REPO=""; PR=""; HACK_NOTE=""; COMMIT_REF=""
IMAGES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2";      shift 2 ;;
    --pr)        PR="$2";        shift 2 ;;
    --commit)    COMMIT_REF="$2"; shift 2 ;;
    --title)     shift 2 ;;  # retired: the table has no per-batch title
    --hack-note) HACK_NOTE="$2"; shift 2 ;;
    *) IMAGES+=("$1"); shift ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "Usage: pr-attach-screenshots.sh --repo <owner/repo> --pr <num> [--commit <sha-or-subject>] [--hack-note '<what was hacked>'] <png...>" >&2; exit 1; }
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

# ── Resolve which commit these frames belong to ───────────────────────────────
# The manifest groups on the commit SUBJECT, not its sha (see pr-evidence-table.js).
PR_COMMITS=$(gh api "repos/$REPO/pulls/$PR/commits" --paginate \
  --jq '[.[] | {sha: .sha, subject: (.commit.message | split("\n")[0])}]')
if [[ -n "$COMMIT_REF" ]]; then
  SUBJECT=$(node -e '
    const [json, ref] = process.argv.slice(1)
    const cs = JSON.parse(json)
    const hit = cs.find(c => c.sha.startsWith(ref)) || cs.find(c => c.subject === ref)
    if (!hit) { console.error("no commit on this PR matches: " + ref); process.exit(1) }
    console.log(hit.subject)
  ' "$PR_COMMITS" "$COMMIT_REF") || exit 1
else
  SUBJECT=$(node -e 'const c=JSON.parse(process.argv[1]); console.log(c.length ? c[c.length-1].subject : "")' "$PR_COMMITS")
fi
[[ -n "$SUBJECT" ]] || { echo "could not resolve a commit subject for $REPO#$PR" >&2; exit 1; }
log "frames attributed to commit: $SUBJECT"

# ── Upload blobs + build one commit containing all images + the manifest ──────
HEAD_SHA=$(gh api "repos/$ASSETS_REPO/git/ref/heads/$ASSETS_BRANCH" --jq .object.sha)
BASE_TREE=$(gh api "repos/$ASSETS_REPO/git/commits/$HEAD_SHA" --jq .tree.sha)

ENTRIES="[]"
PATHS="[]"
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
  PATHS=$(node -e 'const [j,p]=process.argv.slice(1);const a=JSON.parse(j);a.push(p);console.log(JSON.stringify(a))' "$PATHS" "$path")
  log "uploaded $base → $path"
done

# ── Merge into the per-PR manifest (the table's source of truth) ──────────────
MANIFEST_PATH="$DEST_DIR/manifest.json"
OLD_MANIFEST=$(gh api "repos/$ASSETS_REPO/contents/$MANIFEST_PATH?ref=$ASSETS_BRANCH" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo '')
NEW_MANIFEST=$(node -e '
  const m = require(process.env.HOME + "/.cursor/skills/pr-create/scripts/pr-evidence-table.js")
  const [oldJson, pathsJson, subject, hackNote] = process.argv.slice(1)
  const old = oldJson ? JSON.parse(oldJson) : null
  const entries = JSON.parse(pathsJson).map(p => {
    const meta = m.parseName(p.split("/").pop())
    return { path: p, ...meta, subject, hackNote: meta.hacked ? (hackNote || null) : null, addedAt: new Date().toISOString() }
  })
  console.log(JSON.stringify(m.mergeManifest(old, entries), null, 2))
' "$OLD_MANIFEST" "$PATHS" "$SUBJECT" "$HACK_NOTE")

MTMP=$(mktemp)
node -e 'const fs=require("fs");const [c,o]=process.argv.slice(1);fs.writeFileSync(o,JSON.stringify({content:Buffer.from(c).toString("base64"),encoding:"base64"}))' "$NEW_MANIFEST" "$MTMP"
MSHA=$(gh api "repos/$ASSETS_REPO/git/blobs" --input "$MTMP" --jq .sha)
rm -f "$MTMP"
ENTRIES=$(node -e '
  const [entries,path,sha]=process.argv.slice(1);
  const a=JSON.parse(entries); a.push({path, mode:"100644", type:"blob", sha});
  console.log(JSON.stringify(a));
' "$ENTRIES" "$MANIFEST_PATH" "$MSHA")

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

# ── Re-render the whole table into the PR body between its sentinels ──────────
CUR_BODY=$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')
NEW_BODY=$(node -e '
  const m = require(process.env.HOME + "/.cursor/skills/pr-create/scripts/pr-evidence-table.js")
  const [manifest, body, repo, pr, rawBase, commits] = process.argv.slice(1)
  const table = m.render(JSON.parse(manifest), { repo, pr, rawBase, commits: JSON.parse(commits) })
  process.stdout.write(m.splice(body, table))
' "$NEW_MANIFEST" "$CUR_BODY" "$REPO" "$PR" \
  "https://raw.githubusercontent.com/$ASSETS_REPO/$ASSETS_BRANCH/$DEST_DIR/" "$PR_COMMITS") || exit 1

# GitHub caps a PR body at 65536 chars; past that the edit is rejected and the
# table would be lost, so refuse while the old body is still intact.
BODY_LEN=${#NEW_BODY}
if [[ "$BODY_LEN" -gt 60000 ]]; then
  echo "refusing: rendered body is $BODY_LEN chars, over the 60000 safety margin (GitHub caps at 65536). Prune frames for this PR." >&2
  exit 1
fi
BODYF=$(mktemp)
printf '%s' "$NEW_BODY" > "$BODYF"
gh pr edit "$PR" --repo "$REPO" --body-file "$BODYF" >/dev/null
rm -f "$BODYF"
TOTAL=$(node -e 'console.log(JSON.parse(process.argv[1]).entries.length)' "$NEW_MANIFEST")
log "PASS — ${#IMAGES[@]} new screenshot(s); table in $REPO#$PR body now holds $TOTAL"
