#!/usr/bin/env bash
# gist-doc-publish.sh — publish or update a markdown doc as a public gist,
# printing the live URL plus the immutable revision (snapshot) URLs.
#
# Usage:
#   gist-doc-publish.sh --file <doc.md> [--gist <gist-id>] [--desc "<description>"]
#
# Without --gist: creates a new public gist. With --gist: updates that gist
# in place (same live URL, new revision).
#
# Output:
#   GIST_URL: <live url>
#   REV: <full revision sha>
#   PINNED_URL: <live url>/<sha>          (immutable rendered snapshot)
#   RAW_PINNED_URL: <raw url at sha>      (immutable raw markdown)
# Exit 0 = success, 1 = error.
set -euo pipefail

FILE=""
GIST_ID=""
DESC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --gist) GIST_ID="$2"; shift 2 ;;
    --desc) DESC="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done
[[ -f "$FILE" ]] || { echo "ERROR: --file <doc.md> required and must exist" >&2; exit 1; }
BASENAME=$(basename "$FILE")

if [[ -z "$GIST_ID" ]]; then
  args=(--public)
  [[ -n "$DESC" ]] && args+=(--desc "$DESC")
  url=$(gh gist create "${args[@]}" "$FILE" | tail -1)
  GIST_ID="${url##*/}"
else
  payload=$(jq -Rs --arg name "$BASENAME" '{files: {($name): {content: .}}}' "$FILE")
  [[ -n "$DESC" ]] && payload=$(echo "$payload" | jq --arg d "$DESC" '. + {description: $d}')
  echo "$payload" | gh api "gists/$GIST_ID" -X PATCH --input - > /dev/null
fi

info=$(gh api "gists/$GIST_ID" --jq '{url: .html_url, rev: .history[0].version, owner: .owner.login}')
GIST_URL=$(echo "$info" | jq -r '.url')
REV=$(echo "$info" | jq -r '.rev')
OWNER=$(echo "$info" | jq -r '.owner')

echo "GIST_URL: $GIST_URL"
echo "REV: $REV"
echo "PINNED_URL: $GIST_URL/$REV"
echo "RAW_PINNED_URL: https://gist.githubusercontent.com/$OWNER/$GIST_ID/raw/$REV/$BASENAME"
