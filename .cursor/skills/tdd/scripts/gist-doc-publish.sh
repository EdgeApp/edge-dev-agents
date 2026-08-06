#!/usr/bin/env bash
# gist-doc-publish.sh — publish or update a markdown doc as a gist, printing the
# live URL plus the immutable revision (snapshot) URLs.
#
# Usage:
#   gist-doc-publish.sh --file <doc.md> [--gist <gist-id>] [--desc "<description>"]
#                       [--visibility public|secret]
#
# Without --gist: creates a gist. With --gist: updates that gist in place (same
# live URL, new revision); --visibility is ignored there, since GitHub cannot
# flip an existing gist between public and secret.
#
# --visibility (default secret):
#   secret  unlisted, NOT access-controlled: anyone with the URL can read it,
#           and it stays readable after the link is shared onward. Use it to
#           keep a doc off the profile, never to protect a secret.
#   public  listed on the owner's profile and indexable. Opt in explicitly.
#
# The default is secret so that forgetting the flag cannot publish a doc to a
# public profile. Publishing publicly is the choice that has to be typed.
#
# Output:
#   GIST_URL: <live url>
#   REV: <full revision sha>
#   PINNED_URL: <live url>/<sha>          (immutable rendered snapshot)
#   RAW_PINNED_URL: <raw url at sha>      (immutable raw markdown)
#
# Orchestration pointer: when AGENT_TASK_GID is set, the same values are written
# to $XDG_STATE_HOME/agent-watcher/tdd-doc/<gid>.env. tdd-doc-links.sh reads that
# file when the repo carries no committed doc, so a gist-hosted TDD still
# resolves for the run report's tdd_doc field and the PR-body link hook. Without
# it a gist-hosted TDD is invisible to the orch and reports as "none".
#
# Exit 0 = success, 1 = error.
set -euo pipefail

FILE=""
GIST_ID=""
DESC=""
VISIBILITY="secret"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="$2"; shift 2 ;;
    --gist) GIST_ID="$2"; shift 2 ;;
    --desc) DESC="$2"; shift 2 ;;
    --visibility) VISIBILITY="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done
[[ -f "$FILE" ]] || { echo "ERROR: --file <doc.md> required and must exist" >&2; exit 1; }
case "$VISIBILITY" in
  public|secret) ;;
  *) echo "ERROR: --visibility must be public or secret" >&2; exit 1 ;;
esac
BASENAME=$(basename "$FILE")

if [[ -z "$GIST_ID" ]]; then
  args=()
  [[ "$VISIBILITY" == "public" ]] && args+=(--public)
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

if [[ -n "${AGENT_TASK_GID:-}" ]]; then
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/tdd-doc"
  mkdir -p "$STATE_DIR"
  cat > "$STATE_DIR/$AGENT_TASK_GID.env" <<EOF
TDD_DOC=$BASENAME
TDD_BRANCH_URL=$GIST_URL
TDD_PINNED_URL=$GIST_URL/$REV
TDD_GIST_ID=$GIST_ID
TDD_VISIBILITY=$VISIBILITY
EOF
  echo "STATE: $STATE_DIR/$AGENT_TASK_GID.env"
fi
