#!/usr/bin/env bash
# tdd-doc-links.sh — resolve the committed TDD doc for a repo checkout and emit
# its two citation forms. Single writer for both URL shapes, so the run report
# and the PR body can never disagree about where the doc lives.
#
# The two forms are NOT interchangeable, per operator ruling (2026-07-28):
#   BRANCH url  -> PR body. Follows the branch HEAD, so a reviewer opening the
#                  PR always lands on the doc as it stands with the code.
#   PINNED url  -> run report. Frozen at the commit the report described, so a
#                  report stays true to the state it audited.
#
# A gist-hosted doc (tdd output-target public-gist / secret-gist) has no
# committed file to find, so when the repo carries none this falls back to the
# pointer gist-doc-publish.sh writes for the task. Same three keys either way,
# so callers never branch on where the doc lives: BRANCH_URL is the live gist,
# PINNED_URL its frozen revision.
#
# Usage: tdd-doc-links.sh [repo-dir]        (default: cwd)
# stdout: TDD_DOC / TDD_BRANCH_URL / TDD_PINNED_URL, one KEY=VALUE per line.
# Exit: 0 = resolved, 3 = no doc anywhere (normal before the TDD is written),
#       1 = not a git repo / no github remote, 2 = usage.
set -euo pipefail

REPO_DIR="${1:-$PWD}"
[ -d "$REPO_DIR" ] || { echo "usage: tdd-doc-links.sh [repo-dir]" >&2; exit 2; }

git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git repo: $REPO_DIR" >&2; exit 1; }

REMOTE=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
SLUG=$(printf '%s' "$REMOTE" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
case "$SLUG" in
  */*) ;;
  *) echo "ERROR: no github origin on $REPO_DIR" >&2; exit 1 ;;
esac

# Committed docs only. Most-recently-committed wins when a repo carries several.
DOC=""
LATEST=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  ts=$(git -C "$REPO_DIR" log -1 --format=%ct -- "$f" 2>/dev/null || echo 0)
  if [ "${ts:-0}" -ge "$LATEST" ]; then LATEST="$ts"; DOC="$f"; fi
done < <(git -C "$REPO_DIR" ls-files 'src/docs/*.md' 2>/dev/null)
if [ -z "$DOC" ]; then
  # No committed doc: fall back to a gist pointer for this task, if one exists.
  PTR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/tdd-doc/${AGENT_TASK_GID:-}.env"
  if [ -n "${AGENT_TASK_GID:-}" ] && [ -f "$PTR" ]; then
    grep -E '^TDD_(DOC|BRANCH_URL|PINNED_URL)=' "$PTR"
    exit 0
  fi
  exit 3
fi

BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "")
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { echo "ERROR: detached HEAD in $REPO_DIR" >&2; exit 1; }

echo "TDD_DOC=$DOC"
echo "TDD_BRANCH_URL=https://github.com/$SLUG/blob/$BRANCH/$DOC"
echo "TDD_PINNED_URL=https://github.com/$SLUG/blob/$SHA/$DOC"
