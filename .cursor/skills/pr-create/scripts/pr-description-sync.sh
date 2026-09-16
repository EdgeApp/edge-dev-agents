#!/usr/bin/env bash
# pr-description-sync.sh — Put the agent-owned Description block in a PR body.
#
# A TDD-bearing PR does not restate its design in the body. The description is
# the Asana link, then the doc's own title carrying the link, so the body stays
# short and cannot drift from the doc: re-running after the TDD is retitled
# rewrites the line in place, between sentinels, touching nothing else.
#
# Usage: pr-description-sync.sh --repo <owner/repo> --pr <num> [--repo-dir <path>]
#                               [--asana <gid-or-url>] [--dry-run]
# Exit: 0 written (or dry run), 1 error, 3 no TDD found (nothing to sync).
set -euo pipefail
REPO=""; PR=""; REPO_DIR="$PWD"; ASANA=""; DRY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --asana) ASANA="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$REPO" && -n "$PR" ]] || { echo "usage: pr-description-sync.sh --repo <owner/repo> --pr <num>" >&2; exit 1; }

# tdd-doc-links.sh is the single writer of both URL shapes; BRANCH is the PR form.
LINKS=$("$HOME/.cursor/skills/tdd/scripts/tdd-doc-links.sh" "$REPO_DIR" 2>/dev/null) || {
  echo "no TDD for this repo — nothing to sync" >&2; exit 3; }
TDD_DOC=$(printf '%s\n' "$LINKS" | sed -n 's/^TDD_DOC=//p')
TDD_URL=$(printf '%s\n' "$LINKS" | sed -n 's/^TDD_BRANCH_URL=//p')
[[ -n "$TDD_URL" ]] || { echo "tdd-doc-links.sh gave no TDD_BRANCH_URL" >&2; exit 3; }

TITLE=$(grep -m1 '^# ' "$REPO_DIR/$TDD_DOC" 2>/dev/null | sed 's/^# //')
[[ -n "$TITLE" ]] || { echo "no H1 title in $TDD_DOC" >&2; exit 1; }

ASANA_LINE=""
if [[ -n "$ASANA" ]]; then
  GID="${ASANA##*/}"
  ASANA_LINE="[Asana task](https://app.asana.com/0/0/$GID/f)"
fi

BODY=$(gh api "repos/$REPO/pulls/$PR" --jq '.body // ""')
NEW=$(node -e '
  const m = require(process.env.HOME + "/.cursor/skills/pr-create/scripts/pr-evidence-table.js")
  const [body, asana, title, url] = process.argv.slice(1)
  const block = [asana, asana ? "" : null, `\u{1F4C4} [${title}](${url})`].filter(v => v !== null && v !== "" || v === "").join("\n")
  const synced = m.splice("", block, { name: "description", heading: null })
  let out = m.removeSection(body, "Technical Design Document")
  out = m.replaceSection(out, "Description", synced)
  out = m.moveSectionFirst(out, "Description")
  process.stdout.write(out)
' "$BODY" "$ASANA_LINE" "$TITLE" "$TDD_URL")

if $DRY; then printf '%s\n' "$NEW" | sed -n '/agent-description:start/,/agent-description:end/p'; exit 0; fi
F=$(mktemp); printf '%s' "$NEW" > "$F"
gh pr edit "$PR" --repo "$REPO" --body-file "$F" >/dev/null; rm -f "$F"
echo ">> pr-description-sync: $REPO#$PR description synced to \"$TITLE\""
