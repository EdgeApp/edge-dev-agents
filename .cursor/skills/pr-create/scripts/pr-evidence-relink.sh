#!/usr/bin/env bash
# pr-evidence-relink.sh — Re-point evidence image URLs inside one owned PR body
# or PR comment, in place.
#
# For moving hosted evidence frames from one host to another without touching
# the prose around them. The caller supplies a map of old URL to new URL; the
# script fetches the LIVE text immediately before writing, substitutes exactly
# the URLs the map names, and writes the result back. Nothing else in the text
# changes, which is why this funnel runs no prose lint: it cannot introduce
# prose. A map value of null marks a frame that is no longer hosted anywhere:
# its image markup (the <a><img></a> pair, a bare <img>, or a markdown image)
# is replaced by the words "Frame withdrawn." so no broken image is left.
#
# Author-scoped: refuses text whose author is not the authenticated gh user.
# A write that hits a GitHub rate limit waits out `retry-after` (or 60s, then
# doubling) and retries, up to 5 times.
#
# Usage: pr-evidence-relink.sh --repo <owner/repo> (--pr <num> | --comment-id <id>)
#                              --map <map.json> [--save-original <path>] [--dry-run]
#   --map            JSON object: { "<old url>": "<new url>" | null, ... }
#   --comment-id     an issue comment on a PR (the REST database id)
#   --save-original  write the pre-edit text there before changing anything
#   --dry-run        print the result line and the new text; write nothing
# Output: one JSON line {target, author, changed, relinked, withdrawn}.
# Exit: 0 written, unchanged or dry run; 1 error; 3 refused (not the author, or
#       a withdrawn URL sits in markup this script does not know how to remove).
set -euo pipefail
REPO=""; PR=""; COMMENT=""; MAP=""; SAVE=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --comment-id) COMMENT="$2"; shift 2 ;;
    --map) MAP="$2"; shift 2 ;;
    --save-original) SAVE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
USAGE="usage: pr-evidence-relink.sh --repo <owner/repo> (--pr <num> | --comment-id <id>) --map <map.json> [--save-original <path>] [--dry-run]"
[[ -n "$REPO" && -n "$MAP" ]] || { echo "$USAGE" >&2; exit 1; }
[[ -n "$PR" || -n "$COMMENT" ]] || { echo "$USAGE" >&2; exit 1; }
[[ -z "$PR" || -z "$COMMENT" ]] || { echo "pass --pr or --comment-id, not both" >&2; exit 1; }
[[ -f "$MAP" ]] || { echo "map file not found: $MAP" >&2; exit 1; }

if [[ -n "$PR" ]]; then ENDPOINT="repos/$REPO/pulls/$PR"; TARGET="$REPO#$PR body"
else ENDPOINT="repos/$REPO/issues/comments/$COMMENT"; TARGET="$REPO comment $COMMENT"; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ME=$(gh api user --jq .login)
gh api "$ENDPOINT" > "$TMP/live.json"

set +e
node -e '
  const fs = require("fs")
  const [liveFile, mapFile, me, target, outFile, payloadFile, saveFile] = process.argv.slice(1)
  const live = JSON.parse(fs.readFileSync(liveFile, "utf8"))
  const map = JSON.parse(fs.readFileSync(mapFile, "utf8"))
  const author = (live.user && live.user.login) || null
  if (author !== me) { console.error(`refusing: ${target} is authored by ${author}, not ${me}`); process.exit(3) }
  const before = live.body || ""
  if (saveFile) fs.writeFileSync(saveFile, before)
  const NOTE = "<em>Frame withdrawn.</em>"
  const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  let text = before, relinked = 0, withdrawn = 0
  // Withdrawn frames first: their markup goes as a unit, widest shape first.
  for (const [url, to] of Object.entries(map)) {
    if (to !== null || !text.includes(url)) continue
    const u = esc(url)
    const img = `<img\\b[^>]*\\bsrc="${u}"[^>]*>`
    const md = `!\\[[^\\]]*\\]\\(${u}(?:\\s+"[^"]*")?\\)`
    const shapes = [
      new RegExp(`<a\\b[^>]*\\bhref="${u}"[^>]*>\\s*${img}\\s*</a>`, "g"),
      new RegExp(img, "g"),
      new RegExp(`\\[${md}\\]\\(${u}\\)`, "g"),
      new RegExp(md, "g")
    ]
    for (const re of shapes) text = text.replace(re, () => { withdrawn++; return NOTE })
    if (text.includes(url)) { console.error(`refusing: ${target} shows a withdrawn frame in markup this script cannot remove: ${url}`); process.exit(3) }
  }
  // Then plain substitution, one whole URL token at a time, so a key that is a
  // prefix of a longer URL never matches inside it.
  text = text.replace(/https?:\/\/[^\s"\x27<>()\[\]`]+/g, tok => {
    if (!Object.prototype.hasOwnProperty.call(map, tok) || map[tok] === null) return tok
    relinked++
    return map[tok]
  })
  fs.writeFileSync(outFile, text)
  fs.writeFileSync(payloadFile, JSON.stringify({ body: text }))
  console.log(JSON.stringify({ target, author, changed: text !== before, relinked, withdrawn }))
' "$TMP/live.json" "$MAP" "$ME" "$TARGET" "$TMP/new.txt" "$TMP/payload.json" "$SAVE" > "$TMP/result.json"
RC=$?
set -e
[[ $RC -eq 0 ]] || exit "$RC"

if [[ $DRY -eq 1 ]]; then cat "$TMP/result.json"; cat "$TMP/new.txt"; exit 0; fi
if grep -q '"changed":false' "$TMP/result.json"; then cat "$TMP/result.json"; exit 0; fi

WAIT=60
for ATTEMPT in 1 2 3 4 5; do
  set +e
  gh api -i -X PATCH "$ENDPOINT" --input "$TMP/payload.json" > "$TMP/resp.txt" 2> "$TMP/resp.err"
  RC=$?
  set -e
  if [[ $RC -eq 0 ]]; then cat "$TMP/result.json"; exit 0; fi
  STATUS=$(head -1 "$TMP/resp.txt" | awk '{print $2}')
  if [[ "$STATUS" == "403" || "$STATUS" == "429" ]] && grep -qiE 'rate limit|retry-after' "$TMP/resp.txt" "$TMP/resp.err"; then
    RA=$(grep -i '^retry-after:' "$TMP/resp.txt" | head -1 | tr -dc '0-9' || true)
    SLEEP=${RA:-$WAIT}
    echo ">> pr-evidence-relink: rate limited on $TARGET (HTTP $STATUS), waiting ${SLEEP}s (attempt $ATTEMPT of 5)" >&2
    sleep "$SLEEP"
    WAIT=$((WAIT * 2))
    continue
  fi
  echo "write failed for $TARGET (HTTP ${STATUS:-unknown}):" >&2
  cat "$TMP/resp.err" >&2
  exit 1
done
echo "write failed for $TARGET: still rate limited after 5 attempts" >&2
exit 1
