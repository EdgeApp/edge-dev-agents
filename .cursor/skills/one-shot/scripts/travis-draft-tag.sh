#!/usr/bin/env bash
# travis-draft-tag.sh — keep Travis out of the draft phase (operator policy
# 2026-08-06: Travis queues are shared and expensive; a draft build blocks
# other in-flight work for a HEAD nobody will land).
#
# Travis has no draft condition in its `if:` vocabulary, but it honors the
# per-service skip token in the HEAD commit message: `[skip travis]` prevents
# the build from ENQUEUING at all (GitHub Actions checks ignore it and still
# run on drafts). So:
#   add    append " [skip travis]" to HEAD's subject if absent. Run BEFORE the
#          first push of a draft-phase branch; the amend loop preserves it.
#   strip  remove the token from HEAD's message. Run at the ready-flip, BEFORE
#          the force-push that precedes `gh pr ready` — that push triggers the
#          one Travis build on the flip HEAD, queued while the bots review.
#
# Both ops are message-only amends (tree untouched). Idempotent. The merged
# history never carries the token: strip runs before ready, and watch-pr warns
# if a ready PR's HEAD still carries it (the visible-blocked backstop).
#
# Usage: travis-draft-tag.sh {add|strip} [repo-dir]
# Exit: 0 = done (including no-op), 1 = error, 2 = usage.
set -euo pipefail

OP="${1:-}"
REPO_DIR="${2:-$PWD}"
case "$OP" in add|strip) ;; *) echo "usage: travis-draft-tag.sh {add|strip} [repo-dir]" >&2; exit 2 ;; esac
git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git repo: $REPO_DIR" >&2; exit 1; }

MSG_FILE=$(mktemp -t travis-tag.XXXXXX)
trap 'rm -f "$MSG_FILE"' EXIT
git -C "$REPO_DIR" log -1 --format=%B > "$MSG_FILE"

if [ "$OP" = "add" ]; then
  if grep -q '\[skip travis\]' "$MSG_FILE"; then echo ">> travis-draft-tag: already tagged"; exit 0; fi
  # append to the subject line so the token survives subject-only tooling
  awk 'NR==1 { print $0 " [skip travis]"; next } { print }' "$MSG_FILE" > "$MSG_FILE.new" && mv "$MSG_FILE.new" "$MSG_FILE"
else
  if ! grep -q '\[skip travis\]' "$MSG_FILE"; then echo ">> travis-draft-tag: no tag present"; exit 0; fi
  sed -i '' 's/ *\[skip travis\]//g' "$MSG_FILE"
fi

GIT_EDITOR=true git -C "$REPO_DIR" commit --amend --allow-empty -F "$MSG_FILE" --no-verify >/dev/null
echo ">> travis-draft-tag: $OP done (HEAD $(git -C "$REPO_DIR" rev-parse --short HEAD))"
