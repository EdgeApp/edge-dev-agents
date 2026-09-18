#!/usr/bin/env bash
# pr-attach-screenshots.sh — Publish test-evidence screenshots into a PR body.
#
# GitHub has NO official API for uploading images into a PR, so this uploads the
# images to a dedicated assets branch in the (public) infra repo via the Git Data
# API — keeping binary blobs OUT of the product repos' history — then renders
# them as ONE batch-grouped table inside the PR BODY, between invisible HTML
# sentinels. raw.githubusercontent.com URLs render inline on public repos.
#
# A BATCH is one invocation of this script at one head sha: the build those
# frames were shot against. Re-running at the SAME head sha grows that batch in
# place (re-attaching a file is a no-op, a re-shot frame replaces itself), so
# fixing one bad screenshot mid-build costs nothing. Landing at a DIFFERENT head
# sha opens a new batch, and what happens to the old one is the keep predicate's
# call — see pr-evidence-table.js, which owns the model.
#
# WHY DISPOSITIONS EXIST: before anyone has reviewed, a new build retires the
# previous frames, because the table's job is to show the current build rather
# than a pile of every state the branch has been in. That retirement is silent
# data loss if the script guesses, and stale pixels if it keeps everything, so it
# guesses at neither: it refuses until every retiring frame has a decision.
#   --carry-forward <scene>  the frame is still true at the new head. Re-points
#                            the existing blob into the new batch: no simulator,
#                            no recapture, no re-upload.
#   --retire <scene>         the change invalidated it.
# A frame re-shot in this same invocation needs no flag; supplying it IS the
# decision. After a human has reviewed, nothing retires and new frames simply
# append as their own row, so no disposition is ever asked for.
#
# Usage:
#   pr-attach-screenshots.sh --repo <owner/repo> --pr <num> \
#     [--carry-forward <scene|all>]... [--retire <scene|all>]... \
#     [--hack-note "<what was hacked>"] [<png>...]
#
#   --hack-note  REQUIRED when any filename carries the HACKED token; one short
#                line naming the exact hack. It renders in that batch's header
#                cell, so every frame under it inherits the disclosure.
#
# A scene is the caption slug a disposition names: `card-on-utxo-wallet` for
# `...-02-HACKED-card-on-utxo-wallet.png`. `all` is accepted by both flags, and
# an explicit scene beats a blanket `all`, so `--carry-forward all --retire
# stale-scene` reads exactly as it looks. The refusal prints the scenes and the
# command to re-run, so the list never has to be derived by hand.
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
# Exit codes: 0 = body updated, 1 = error, 2 = dispositions needed (nothing was
# uploaded; re-run with the flags the refusal printed).

set -euo pipefail

ASSETS_REPO="EdgeApp/edge-dev-agents"
ASSETS_BRANCH="agent-pr-assets"
export TABLE_JS="$HOME/.cursor/skills/pr-create/scripts/pr-evidence-table.js"

REPO=""; PR=""; HACK_NOTE=""
IMAGES=(); CARRY=(); RETIRE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          REPO="$2";      shift 2 ;;
    --pr)            PR="$2";        shift 2 ;;
    --carry-forward) CARRY+=("$2");  shift 2 ;;
    --retire)        RETIRE+=("$2"); shift 2 ;;
    --hack-note)     HACK_NOTE="$2"; shift 2 ;;
    --title)         shift 2 ;;  # retired: the table has no per-batch title
    --commit)        echo ">> pr-attach-screenshots: --commit is retired (frames group by capture batch, not commit); ignoring" >&2; shift 2 ;;
    *) IMAGES+=("$1"); shift ;;
  esac
done
USAGE="Usage: pr-attach-screenshots.sh --repo <owner/repo> --pr <num> [--carry-forward <scene|all>] [--retire <scene|all>] [--hack-note '<what was hacked>'] [<png...>]"
[[ -n "$REPO" && -n "$PR" ]] || { echo "$USAGE" >&2; exit 1; }
[[ ${#IMAGES[@]} -gt 0 || ${#CARRY[@]} -gt 0 || ${#RETIRE[@]} -gt 0 ]] || { echo "Nothing to do: give images, or a --carry-forward/--retire disposition" >&2; echo "$USAGE" >&2; exit 1; }
for f in "${IMAGES[@]:-}"; do [[ -z "$f" || -f "$f" ]] || { echo "Not found: $f" >&2; exit 1; }; done

ANY_HACKED=false
for f in "${IMAGES[@]:-}"; do
  [[ -n "$f" && "$(basename "$f")" == *HACKED* ]] && ANY_HACKED=true
done
if $ANY_HACKED && [[ -z "$HACK_NOTE" ]]; then
  echo "HACKED image(s) present: pass --hack-note '<one short line: WHAT was hacked>' (e.g. --hack-note 'hard-coded the empty-state branch true in WalletList') so the PR banner is specific. See build-and-test hack-verify-visual-changes." >&2
  exit 1
fi

REPO_NAME="${REPO#*/}"
DEST_DIR="assets/${REPO_NAME}/pr-${PR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { echo ">> pr-attach-screenshots: $*" >&2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

json_array() { # json_array <item>... -> JSON array on stdout
  node -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' "$@"
}

# ── PR state: head sha, commit list, and the human-action timeline ────────────
# One GraphQL call rather than four REST ones. A Bot-typed author is what marks
# an automated review; the [bot] suffix is the fallback for an integration that
# posts as a User. The PR AUTHOR is excluded because the agent posts as the
# operator's own account, so the author's own comments are agent chatter and must
# not freeze a batch.
gh api graphql -f owner="${REPO%/*}" -f name="$REPO_NAME" -F number="$PR" -f query='
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      author{login}
      headRefOid
      commits(last:100){nodes{commit{oid messageHeadline}}}
      reviews(first:100){nodes{createdAt author{login __typename}}}
      comments(first:100){nodes{createdAt author{login __typename}}}
      reviewThreads(first:50){nodes{comments(first:50){nodes{createdAt author{login __typename}}}}}
    }
  }
}' > "$WORK/pr.json" || { echo "failed to read $REPO#$PR" >&2; exit 1; }

node -e '
  const fs = require("fs")
  const pr = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).data.repository.pullRequest
  const author = (pr.author || {}).login || ""
  const isBot = a => !a || a.__typename === "Bot" || /\[bot\]$/.test(a.login || "")
  const human = n => n && !isBot(n.author) && (n.author.login || "") !== author
  const acts = []
  for (const n of pr.reviews.nodes) if (human(n)) acts.push(n.createdAt)
  for (const n of pr.comments.nodes) if (human(n)) acts.push(n.createdAt)
  for (const t of pr.reviewThreads.nodes) for (const n of t.comments.nodes) if (human(n)) acts.push(n.createdAt)
  const commits = pr.commits.nodes.map(n => ({ sha: n.commit.oid, subject: n.commit.messageHeadline }))
  fs.writeFileSync(process.argv[2], pr.headRefOid)
  fs.writeFileSync(process.argv[3], JSON.stringify([...new Set(acts)].sort()))
  fs.writeFileSync(process.argv[4], JSON.stringify(commits))
' "$WORK/pr.json" "$WORK/head" "$WORK/actions.json" "$WORK/commits.json"

HEAD_SHA=$(cat "$WORK/head")
ACTIONS=$(cat "$WORK/actions.json")
PR_COMMITS=$(cat "$WORK/commits.json")
log "head $(echo "$HEAD_SHA" | cut -c1-7); human review actions: $(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$ACTIONS")"

# ── Existing manifest (the table's source of truth) ───────────────────────────
MANIFEST_PATH="$DEST_DIR/manifest.json"
gh api "repos/$ASSETS_REPO/contents/$MANIFEST_PATH?ref=$ASSETS_BRANCH" --jq '.content' 2>/dev/null | base64 -d > "$WORK/old.json" 2>/dev/null || true
[[ -s "$WORK/old.json" ]] || echo '{"version":2,"entries":[]}' > "$WORK/old.json"

# ── Batch decision + disposition gate, BEFORE any upload ──────────────────────
# A refusal here costs no blobs and no commits on the assets branch.
SUPPLIED="[]"
if [[ ${#IMAGES[@]} -gt 0 ]]; then
  SUPPLIED=$(node -e '
    const m = require(process.env.TABLE_JS)
    process.stdout.write(JSON.stringify(process.argv.slice(1).map(p => m.sceneId(p.split("/").pop()))))
  ' "${IMAGES[@]}")
fi
CARRY_JSON=$(json_array "${CARRY[@]:-}")
RETIRE_JSON=$(json_array "${RETIRE[@]:-}")

node -e '
  const fs = require("fs")
  const m = require(process.env.TABLE_JS)
  const [manPath, actionsJson, headSha, nowIso, carryJson, retireJson, suppliedJson, hackNote, outPath] = process.argv.slice(1)
  const man = JSON.parse(fs.readFileSync(manPath, "utf8"))
  const actions = JSON.parse(actionsJson)
  const carry = JSON.parse(carryJson).filter(Boolean)
  const retire = JSON.parse(retireJson).filter(Boolean)
  const supplied = new Set(JSON.parse(suppliedJson))

  const batches = m.batchesOf(man)
  const prior = batches.length ? batches[batches.length - 1] : null
  const sameBatch = !!(prior && prior.headSha && prior.headSha === headSha && prior.batchAt)
  const batchAt = sameBatch ? prior.batchAt : nowIso

  const doomed = sameBatch ? [] : m.wouldRetire(man, actions, batchAt).flatMap(b => b.entries)
  const hits = (list, e) => list.some(t => t !== "all" && m.resolveScenes([e], t).length > 0)
  const all = list => list.includes("all")

  const carried = []
  const missing = []
  for (const e of doomed) {
    const sid = m.sceneId(e)
    if (supplied.has(sid)) continue                 // re-shot in this batch: that IS the decision
    const keep = hits(carry, e) ? true : hits(retire, e) ? false : all(retire) ? false : all(carry) ? true : null
    if (keep === null) { missing.push(sid); continue }
    // A carried HACKED frame adopts the --hack-note of this run when one is given,
    // which is how two runs that forced the same state with the same hack stop
    // rendering two near-identical notes on one row. Without the flag each frame
    // keeps the note it was captured with.
    if (keep) carried.push({ ...e, batchAt, headSha, carriedFrom: e.batchAt || m.LEGACY, hackNote: e.hacked ? (hackNote || e.hackNote || null) : null })
  }
  fs.writeFileSync(outPath, JSON.stringify({
    batchAt, sameBatch, carried,
    doomed: [...new Set(doomed.map(m.sceneId))],
    missing: [...new Set(missing)]
  }))
' "$WORK/old.json" "$ACTIONS" "$HEAD_SHA" "$NOW_UTC" "$CARRY_JSON" "$RETIRE_JSON" "$SUPPLIED" "$HACK_NOTE" "$WORK/gate.json"

MISSING=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).missing.join("\n"))' "$WORK/gate.json")
if [[ -n "$MISSING" ]]; then
  {
    echo ">> pr-attach-screenshots: REFUSING — nothing uploaded."
    echo "   The head sha moved, so this attach opens a new batch and the previous batch retires."
    echo "   No human has reviewed this PR yet, so those frames are not kept automatically."
    echo "   Each one needs a decision (a frame you re-shot in this same run needs none):"
    echo ""
    while IFS= read -r s; do [[ -n "$s" ]] && echo "     $s"; done <<< "$MISSING"
    echo ""
    echo "   Re-run adding, per scene:"
    echo "     --carry-forward <scene>   still true at the new head (no recapture, no re-upload)"
    echo "     --retire <scene>          the change invalidated it"
    echo "   Blanket forms: --carry-forward all / --retire all (an explicit scene beats either)."
    echo ""
    CMD="   e.g. ~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh --repo $REPO --pr $PR"
    while IFS= read -r s; do [[ -n "$s" ]] && CMD="$CMD --carry-forward $s"; done <<< "$MISSING"
    echo "$CMD ${IMAGES[*]:-}"
  } >&2
  exit 2
fi

BATCH_AT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).batchAt)' "$WORK/gate.json")
SAME_BATCH=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sameBatch)' "$WORK/gate.json")
CARRIED_N=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).carried.length)' "$WORK/gate.json")
if [[ "$SAME_BATCH" == "true" ]]; then
  log "same head as the last attach: growing batch $BATCH_AT in place"
else
  log "new batch $BATCH_AT at $(echo "$HEAD_SHA" | cut -c1-7) (carried forward: $CARRIED_N)"
fi

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
# 720 = 2x the table's 360px render width (crisp on retina, ~4x smaller blob).
# Originals are never mutated; narrower images pass through unscaled.
MAX_W=720
UPLOADS=()
for f in "${IMAGES[@]:-}"; do
  [[ -n "$f" ]] || continue
  w=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  if [[ -n "$w" && "$w" -gt "$MAX_W" ]]; then
    scaled="$WORK/scaled-$(basename "$f")"
    if sips --resampleWidth "$MAX_W" "$f" --out "$scaled" >/dev/null 2>&1; then
      UPLOADS+=("$scaled")
      log "scaled $(basename "$f") ${w}px → ${MAX_W}px"
      continue
    fi
    log "WARN: sips failed on $(basename "$f") — uploading original"
  fi
  UPLOADS+=("$f")
done

# ── Upload blobs + build one commit containing all images + the manifest ──────
HEAD_ASSETS=$(gh api "repos/$ASSETS_REPO/git/ref/heads/$ASSETS_BRANCH" --jq .object.sha)
BASE_TREE=$(gh api "repos/$ASSETS_REPO/git/commits/$HEAD_ASSETS" --jq .tree.sha)

ENTRIES="[]"
PATHS="[]"
for f in "${UPLOADS[@]:-}"; do
  [[ -n "$f" ]] || continue
  base="$(basename "$f")"; base="${base#scaled-}"
  safe="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')"
  path="$DEST_DIR/$STAMP-$safe"
  tmp="$WORK/blob.json"
  node -e '
    const fs=require("fs");
    const [src,out]=process.argv.slice(1);
    fs.writeFileSync(out, JSON.stringify({content: fs.readFileSync(src).toString("base64"), encoding:"base64"}));
  ' "$f" "$tmp"
  sha=$(gh api "repos/$ASSETS_REPO/git/blobs" --input "$tmp" --jq .sha)
  ENTRIES=$(node -e '
    const [entries,path,sha]=process.argv.slice(1);
    const a=JSON.parse(entries); a.push({path, mode:"100644", type:"blob", sha});
    console.log(JSON.stringify(a));
  ' "$ENTRIES" "$path" "$sha")
  PATHS=$(node -e 'const [j,p]=process.argv.slice(1);const a=JSON.parse(j);a.push(p);console.log(JSON.stringify(a))' "$PATHS" "$path")
  log "uploaded $base → $path"
done

# ── Merge this batch, then apply the keep predicate and write the manifest ────
node -e '
  const fs = require("fs")
  const m = require(process.env.TABLE_JS)
  const [manPath, gatePath, pathsJson, hackNote, headSha, actionsJson, retireJson, nowIso, outPath] = process.argv.slice(1)
  const old = JSON.parse(fs.readFileSync(manPath, "utf8"))
  const gate = JSON.parse(fs.readFileSync(gatePath, "utf8"))
  const retire = JSON.parse(retireJson).filter(Boolean)
  const batchAt = gate.batchAt

  const fresh = JSON.parse(pathsJson).map(p => {
    const meta = m.parseName(p.split("/").pop())
    return { path: p, ...meta, subject: null, hackNote: meta.hacked ? (hackNote || null) : null, batchAt, headSha, addedAt: nowIso }
  })
  let merged = m.mergeManifest(old, [...gate.carried, ...fresh])

  // An explicit --retire also prunes the CURRENT batch, which is how a bad frame
  // taken moments ago gets dropped. A frozen older batch is what a reviewer
  // already saw and is never rewritten.
  const explicit = retire.filter(t => t !== "all")
  if (explicit.length) {
    merged = { version: 2, entries: merged.entries.filter(e => !((e.batchAt || m.LEGACY) === batchAt && explicit.some(t => m.resolveScenes([e], t).length > 0))) }
  }

  const { manifest, dropped } = m.pruneBatches(merged, JSON.parse(actionsJson))
  fs.writeFileSync(outPath, JSON.stringify(manifest, null, 2))
  const retired = dropped.reduce((n, b) => n + b.entries.length, 0)
  if (retired) console.error(">> pr-attach-screenshots: retired " + retired + " frame(s) from " + dropped.length + " superseded batch(es)")
' "$WORK/old.json" "$WORK/gate.json" "$PATHS" "$HACK_NOTE" "$HEAD_SHA" "$ACTIONS" "$RETIRE_JSON" "$NOW_UTC" "$WORK/new.json"

node -e 'const fs=require("fs");const [c,o]=process.argv.slice(1);fs.writeFileSync(o,JSON.stringify({content:fs.readFileSync(c).toString("base64"),encoding:"base64"}))' "$WORK/new.json" "$WORK/mblob.json"
MSHA=$(gh api "repos/$ASSETS_REPO/git/blobs" --input "$WORK/mblob.json" --jq .sha)
ENTRIES=$(node -e '
  const [entries,path,sha]=process.argv.slice(1);
  const a=JSON.parse(entries); a.push({path, mode:"100644", type:"blob", sha});
  console.log(JSON.stringify(a));
' "$ENTRIES" "$MANIFEST_PATH" "$MSHA")

node -e '
  const [baseTree,entries,out]=process.argv.slice(1);
  require("fs").writeFileSync(out, JSON.stringify({base_tree: baseTree, tree: JSON.parse(entries)}));
' "$BASE_TREE" "$ENTRIES" "$WORK/tree.json"
NEW_TREE=$(gh api "repos/$ASSETS_REPO/git/trees" --input "$WORK/tree.json" --jq .sha)
NEW_COMMIT=$(gh api "repos/$ASSETS_REPO/git/commits" \
  -f message="evidence: $REPO_NAME#$PR (${#UPLOADS[@]} new, $CARRIED_N carried)" \
  -f tree="$NEW_TREE" -f "parents[]=$HEAD_ASSETS" --jq .sha)
gh api -X PATCH "repos/$ASSETS_REPO/git/refs/heads/$ASSETS_BRANCH" -f sha="$NEW_COMMIT" >/dev/null
log "committed $NEW_COMMIT to $ASSETS_BRANCH"

# ── Re-render the whole table into the PR body between its sentinels ──────────
CUR_BODY=$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')
NEW_BODY=$(node -e '
  const m = require(process.env.TABLE_JS)
  const fs = require("fs")
  const [manPath, body, repo, pr, rawBase, commits] = process.argv.slice(1)
  const table = m.render(JSON.parse(fs.readFileSync(manPath, "utf8")), { repo, pr, rawBase, commits: JSON.parse(commits) })
  process.stdout.write(m.splice(body, table))
' "$WORK/new.json" "$CUR_BODY" "$REPO" "$PR" \
  "https://raw.githubusercontent.com/$ASSETS_REPO/$ASSETS_BRANCH/$DEST_DIR/" "$PR_COMMITS") || exit 1

# GitHub caps a PR body at 65536 chars; past that the edit is rejected and the
# table would be lost, so refuse while the old body is still intact.
BODY_LEN=${#NEW_BODY}
if [[ "$BODY_LEN" -gt 60000 ]]; then
  echo "refusing: rendered body is $BODY_LEN chars, over the 60000 safety margin (GitHub caps at 65536). Prune frames for this PR." >&2
  exit 1
fi
printf '%s' "$NEW_BODY" > "$WORK/body.md"
gh pr edit "$PR" --repo "$REPO" --body-file "$WORK/body.md" >/dev/null
TOTAL=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).entries.length)' "$WORK/new.json")
log "PASS — ${#UPLOADS[@]} new, $CARRIED_N carried; table in $REPO#$PR body now holds $TOTAL"
