#!/usr/bin/env bash
# pr-evidence-rehost.sh — Move a PR's evidence frames onto the object bucket.
#
# The table embeds each frame's URL twice (thumbnail src + click target), so URL
# length is what decides how many frames fit under GitHub's 65536-char body cap.
# An assets-branch raw URL runs ~180 chars; a short bucket key runs ~89, which
# roughly halves the per-frame cost and lifts the ceiling from ~105 frames to
# ~152. Frames already carrying a url are skipped, so a re-run is cheap.
#
# Originals stay on the assets branch: that is the durable record, and a bucket
# object can be deleted. Only the manifest's url field moves.
#
# Usage: pr-evidence-rehost.sh --repo <owner/repo> --pr <num> [--prefix <key-prefix>] [--quiet]
# Exit: 0 done, 1 error, 3 no manifest.
set -euo pipefail
ASSETS_REPO="EdgeApp/edge-dev-agents"; ASSETS_BRANCH="agent-pr-assets"
UPLOADER="$HOME/git/site-orch/upload-asset.sh"
REPO=""; PR=""; PREFIX=""; QUIET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;; --pr) PR="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;; --quiet) QUIET=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "usage: pr-evidence-rehost.sh --repo <owner/repo> --pr <num>" >&2; exit 1; }
[[ -x "$UPLOADER" ]] || { echo "no uploader at $UPLOADER" >&2; exit 1; }
log() { $QUIET || echo ">> pr-evidence-rehost: $*" >&2; }

RN="${REPO#*/}"; DEST="assets/$RN/pr-$PR"
[[ -n "$PREFIX" ]] || PREFIX="$(printf '%s' "$RN" | sed 's/^edge-//; s/[^a-z0-9]//g' | cut -c1-6)$PR"
MAN=$(gh api "repos/$ASSETS_REPO/contents/$DEST/manifest.json?ref=$ASSETS_BRANCH" --jq '.content' 2>/dev/null | base64 -d) \
  || { echo "no manifest for $REPO#$PR" >&2; exit 3; }
[[ -n "$MAN" ]] || { echo "no manifest for $REPO#$PR" >&2; exit 3; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '%s' "$MAN" > "$TMP/man.json"
# bash 3.2 (the macOS default) has no mapfile; read into the array by hand.
TODO=()
while IFS= read -r _line; do [ -n "$_line" ] && TODO+=("$_line"); done < <(node -e '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1]))
  for (const e of m.entries) if (!e.url) console.log(e.path)
' "$TMP/man.json")
log "${#TODO[@]} frame(s) to host (of $(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).entries.length)' "$TMP/man.json"))"
[[ ${#TODO[@]} -gt 0 ]] || { log "already hosted"; exit 0; }

: > "$TMP/map.tsv"; i=0
for p in "${TODO[@]}"; do
  i=$((i+1)); f="$TMP/$(basename "$p")"
  curl -sf --max-time 60 "https://raw.githubusercontent.com/$ASSETS_REPO/$ASSETS_BRANCH/$p" -o "$f" || { log "WARN download failed: $p"; continue; }
  slug=$(basename "$p" .png | sed -E 's/^[0-9]{8}-[0-9]{6}-//; s/^agent-proof-[0-9]+-//; s/^[0-9]+-//' | cut -c1-18 | tr -c 'a-zA-Z0-9-' '-' | sed 's/-*$//')
  key="$PREFIX/$(printf '%03d' "$i")-$slug-$(openssl rand -hex 3).png"
  url=$("$UPLOADER" --key "$key" "$f" 2>/dev/null | tail -1) || { log "WARN upload failed: $p"; continue; }
  printf '%s\t%s\n' "$p" "$url" >> "$TMP/map.tsv"
  rm -f "$f"
done
log "hosted $(wc -l < "$TMP/map.tsv" | tr -d ' ')"

node -e '
  const fs=require("fs")
  const man=JSON.parse(fs.readFileSync(process.argv[1]))
  const map=new Map(fs.readFileSync(process.argv[2],"utf8").trim().split("\n").filter(Boolean).map(l=>l.split("\t")))
  for (const e of man.entries) { const u=map.get(e.path); if (u) e.url=u }
  fs.writeFileSync(process.argv[3], JSON.stringify(man,null,2))
' "$TMP/man.json" "$TMP/map.tsv" "$TMP/new.json"

HEAD_SHA=$(gh api "repos/$ASSETS_REPO/git/ref/heads/$ASSETS_BRANCH" --jq .object.sha)
BASE_TREE=$(gh api "repos/$ASSETS_REPO/git/commits/$HEAD_SHA" --jq .tree.sha)
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[2],JSON.stringify({content:fs.readFileSync(process.argv[1]).toString("base64"),encoding:"base64"}))' "$TMP/new.json" "$TMP/blob.json"
MSHA=$(gh api "repos/$ASSETS_REPO/git/blobs" --input "$TMP/blob.json" --jq .sha)
node -e 'require("fs").writeFileSync(process.argv[4],JSON.stringify({base_tree:process.argv[1],tree:[{path:process.argv[3],mode:"100644",type:"blob",sha:process.argv[2]}]}))' "$BASE_TREE" "$MSHA" "$DEST/manifest.json" "$TMP/tree.json"
NT=$(gh api "repos/$ASSETS_REPO/git/trees" --input "$TMP/tree.json" --jq .sha)
NC=$(gh api "repos/$ASSETS_REPO/git/commits" -f message="evidence manifest: $RN#$PR (r2 hosted)" -f tree="$NT" -f "parents[]=$HEAD_SHA" --jq .sha)
gh api -X PATCH "repos/$ASSETS_REPO/git/refs/heads/$ASSETS_BRANCH" -f sha="$NC" >/dev/null

BODY=$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')
COMMITS=$(gh api "repos/$REPO/pulls/$PR/commits" --paginate --jq '[.[]|{sha:.sha,subject:(.commit.message|split("\n")[0])}]')
NEW=$(node -e '
  const m=require(process.env.HOME+"/.cursor/skills/pr-create/scripts/pr-evidence-table.js")
  const [man,body,repo,pr,base,commits]=process.argv.slice(1)
  process.stdout.write(m.splice(body, m.render(JSON.parse(man),{repo,pr,rawBase:base,commits:JSON.parse(commits)})))
' "$(cat "$TMP/new.json")" "$BODY" "$REPO" "$PR" "https://raw.githubusercontent.com/$ASSETS_REPO/$ASSETS_BRANCH/$DEST/" "$COMMITS")
LEN=${#NEW}
[[ "$LEN" -le 60000 ]] || { echo "$RN#$PR still $LEN chars after hosting — needs a render cap" >&2; exit 1; }
F=$(mktemp); printf '%s' "$NEW" > "$F"; gh pr edit "$PR" --repo "$REPO" --body-file "$F" >/dev/null; rm -f "$F"
echo "$RN#$PR hosted=$(wc -l < "$TMP/map.tsv" | tr -d ' ') body=$LEN chars"
