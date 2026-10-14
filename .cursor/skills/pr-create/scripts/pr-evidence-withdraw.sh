#!/usr/bin/env bash
# pr-evidence-withdraw.sh: take published evidence frames back down.
#
# For a frame that should not be public after all (it shows something private
# the check missed, or it is wrong). Each named frame's object is deleted from
# the bucket, its entry leaves the PR's manifest, and the PR body's evidence
# table is re-rendered without it. A frame in a batch a reviewer already saw is
# withdrawn like any other: `--retire` on pr-attach-screenshots.sh only drops a
# frame from the current batch's table and leaves the object hosted.
#
# Usage:
#   pr-evidence-withdraw.sh --repo <owner/repo> --pr <num> [--dry-run] <frame>...
#
#   <frame>    the scene a disposition flag names (`wallet-list`), the frame's
#              file name without its timestamp, or its hosted URL. A scene that
#              several batches hold is withdrawn from all of them.
#   --dry-run  print what would be deleted; change nothing.
#
# ORDER: objects first, then the PR body, then the manifest. The manifest goes
# last so a run that fails part-way still finds its frames there, and running
# the same command again finishes the job (deleting a deleted object succeeds).
#
# The table is the only part of the body this rewrites. A withdrawn URL quoted
# elsewhere (prose, a PR comment) is named on stderr; pr-evidence-relink.sh
# with a null map value removes those.
#
# Exit codes: 0 = withdrawn (or dry run), 1 = error or no such frame (nothing
# was changed when no frame matched).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUCKET="$DIR/evidence-bucket.sh"
export TABLE_JS="$DIR/pr-evidence-table.js"

REPO=""; PR=""; DRY=0; TARGETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --pr)      PR="$2";   shift 2 ;;
    --dry-run) DRY=1;     shift ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done
USAGE="Usage: pr-evidence-withdraw.sh --repo <owner/repo> --pr <num> [--dry-run] <scene|file name|url>..."
[[ -n "$REPO" && -n "$PR" && ${#TARGETS[@]} -gt 0 ]] || { echo "$USAGE" >&2; exit 1; }

log() { echo ">> pr-evidence-withdraw: $*" >&2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$BUCKET" check || { echo "no asset bucket configured (see the config path in evidence-bucket.js): nothing changed." >&2; exit 1; }

MANIFEST_RC=0
"$BUCKET" manifest-get "$REPO" "$PR" "$WORK/old.json" 2> "$WORK/manifest.err" || MANIFEST_RC=$?
if [[ "$MANIFEST_RC" -eq 4 ]]; then
  echo "$REPO#$PR has no evidence manifest: nothing to withdraw." >&2
  exit 1
elif [[ "$MANIFEST_RC" -ne 0 ]]; then
  echo "could not read the manifest for $REPO#$PR, nothing changed: $(cat "$WORK/manifest.err")" >&2
  exit 1
fi

# The public URL of a key is <base>/<key>, so a probe key gives the base.
BASE="$("$BUCKET" url withdraw-probe)"
BASE="${BASE%withdraw-probe}"

# -- Resolve every target before anything is deleted ---------------------------
node -e '
  const fs = require("fs")
  const m = require(process.env.TABLE_JS)
  const [manPath, base, outPath, newPath, ...targets] = process.argv.slice(1)
  const man = JSON.parse(fs.readFileSync(manPath, "utf8"))
  const entries = Array.isArray(man.entries) ? man.entries : []
  const gone = new Set()
  const unmatched = []
  for (const t of targets) {
    const hits = /^https?:\/\//.test(t) ? entries.filter(e => e.url === t) : m.resolveScenes(entries, t)
    if (hits.length === 0) unmatched.push(t)
    for (const e of hits) gone.add(e)
  }
  // An object goes when no remaining entry still points at it.
  const kept = entries.filter(e => !gone.has(e))
  const keptUrls = new Set(kept.map(e => e.url))
  const frames = [...gone].map(e => ({
    scene: m.sceneId(e),
    url: e.url,
    key: typeof e.url === "string" && e.url.startsWith(base) && !keptUrls.has(e.url) ? decodeURIComponent(e.url.slice(base.length)) : null,
    shared: keptUrls.has(e.url)
  }))
  fs.writeFileSync(outPath, JSON.stringify({ unmatched, frames, scenes: [...new Set(entries.map(m.sceneId))] }))
  fs.writeFileSync(newPath, JSON.stringify({ ...man, entries: kept }, null, 2))
' "$WORK/old.json" "$BASE" "$WORK/plan.json" "$WORK/new.json" "${TARGETS[@]}"

# Print one expression over the plan, newline-terminated so `read` sees the last line.
plan() { node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const out = String(eval(process.argv[2])); if (out !== "") console.log(out)' "$WORK/plan.json" "$1"; }

UNMATCHED="$(plan 'p.unmatched.join("\n")')"
if [[ -n "$UNMATCHED" ]]; then
  {
    echo ">> pr-evidence-withdraw: nothing changed. No frame in $REPO#$PR matches:"
    while IFS= read -r s; do echo "     $s"; done <<< "$UNMATCHED"
    echo "   The manifest holds these scenes:"
    plan 'p.scenes.map(s => "     " + s).join("\n")'
  } >&2
  exit 1
fi

if [[ "$DRY" -eq 1 ]]; then
  plan 'p.frames.map(f => "would withdraw " + f.scene + " " + f.url + (f.key ? "" : f.shared ? " (object kept: another entry uses it)" : " (not a bucket object: table entry only)")).join("\n")'
  exit 0
fi

# -- Delete the objects --------------------------------------------------------
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  "$BUCKET" delete "$key" || { echo "bucket delete failed: $key (PR body and manifest untouched; re-run to retry)" >&2; exit 1; }
  RC=0
  "$BUCKET" exists "$key" || RC=$?
  [[ "$RC" -eq 4 ]] || { echo "the bucket still serves $key after the delete (PR body and manifest untouched; re-run to retry)" >&2; exit 1; }
  log "deleted bucket object $key"
done < <(plan 'p.frames.filter(f => f.key).map(f => f.key).join("\n")')

# -- Re-render the table without them ------------------------------------------
PR_COMMITS=$(OWNER="${REPO%/*}" NAME="${REPO#*/}" NUMBER="$PR" node -e '
  const { spawnSync } = require("child_process")
  const r = spawnSync("gh", ["api", "graphql", "-f", "owner=" + process.env.OWNER, "-f", "name=" + process.env.NAME, "-F", "number=" + process.env.NUMBER,
    "-f", "query=query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){commits(last:100){nodes{commit{oid messageHeadline}}}}}}"],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
  if (r.status !== 0) { process.stderr.write(r.stderr || ""); process.exit(1) }
  const pr = JSON.parse(r.stdout).data.repository.pullRequest
  process.stdout.write(JSON.stringify(pr.commits.nodes.map(n => ({ sha: n.commit.oid, subject: n.commit.messageHeadline }))))
') || { echo "failed to read $REPO#$PR (objects deleted; re-run to finish the body and manifest)" >&2; exit 1; }

CUR_BODY=$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')
NEW_BODY=$(node -e '
  const m = require(process.env.TABLE_JS)
  const fs = require("fs")
  const [manPath, body, repo, pr, commits] = process.argv.slice(1)
  const man = JSON.parse(fs.readFileSync(manPath, "utf8"))
  if (man.entries.length > 0) {
    process.stdout.write(m.splice(body, m.render(man, { repo, pr, commits: JSON.parse(commits) })))
  } else {
    // No frame left: an empty table is noise, so the whole block goes.
    const [START, END] = m.marks("test-evidence")
    const i = body.indexOf(START), j = body.indexOf(END)
    process.stdout.write(i >= 0 && j > i ? (body.slice(0, i).replace(/\s*$/, "") + "\n" + body.slice(j + END.length).replace(/^\s*\n/, "\n")).replace(/\s*$/, "\n") : body)
  }
' "$WORK/new.json" "$CUR_BODY" "$REPO" "$PR" "$PR_COMMITS") || { echo "could not re-render the table (objects deleted; repair the body, then re-run)" >&2; exit 1; }

if [[ "$NEW_BODY" != "$CUR_BODY" ]]; then
  printf '%s' "$NEW_BODY" > "$WORK/body.md"
  gh pr edit "$PR" --repo "$REPO" --body-file "$WORK/body.md" >/dev/null || { echo "PR body edit failed (objects deleted; re-run to finish the body and manifest)" >&2; exit 1; }
fi

"$BUCKET" manifest-put "$REPO" "$PR" "$WORK/new.json" > /dev/null || { echo "manifest write failed for $REPO#$PR (objects deleted, body updated; re-run to retry)" >&2; exit 1; }

# A withdrawn URL the table did not own is still in the body.
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  if [[ "$NEW_BODY" == *"$url"* ]]; then
    log "WARN: $url is still quoted in the PR body outside the table; remove it with pr-evidence-relink.sh (map it to null)"
  fi
done < <(plan 'p.frames.filter(f => !f.shared).map(f => f.url).join("\n")')

LEFT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).entries.length)' "$WORK/new.json")
log "PASS: withdrew $(plan 'p.frames.length') frame(s) from $REPO#$PR; the table now holds $LEFT"
