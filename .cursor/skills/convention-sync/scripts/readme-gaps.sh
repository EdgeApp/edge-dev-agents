#!/usr/bin/env bash
# readme-gaps.sh -- the mechanical half of convention-sync `readme-current`:
# list files this sync ADDS whose name no README carries, and files it DELETES
# whose name a README still carries. Behavior changes inside an already-listed
# file are judgment and are not checked here.
#
# A file counts as documented when its basename appears in either README:
#   ~/.cursor/README.md                        (the repo front page)
#   ~/.config/agent-watcher/hooks/README.md    (the hook registry)
# Tests, fixtures and retired files never need a mention and are skipped.
#
# Usage: readme-gaps.sh [repo-dir]
# stdout: one line per gap, `MISSING <repo-path>` or `STALE <repo-path> (<readme>)`.
# Exit: 0 no gaps, 1 gaps listed, 2 the dry run or a README could not be read.
set -euo pipefail

REPO_DIR="${1:-}"
SYNC="$HOME/.cursor/skills/convention-sync/scripts/convention-sync.sh"
FRONT="$HOME/.cursor/README.md"
HOOKS="$HOME/.config/agent-watcher/hooks/README.md"
[ -x "$SYNC" ] || { echo "ERROR: $SYNC not found" >&2; exit 2; }
[ -r "$FRONT" ] || { echo "ERROR: $FRONT not readable" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not on PATH" >&2; exit 2; }

DRY=$("$SYNC" ${REPO_DIR:+"$REPO_DIR"} 2>/dev/null) || { echo "ERROR: sync dry-run failed" >&2; exit 2; }
REPO=$(printf '%s' "$DRY" | jq -r '.repoDir')

skip() {  # paths that never need a README mention
  case "$1" in
    */tests/*|*/fixtures/*|*/retired/*|*.lock.json|*/references/*|*/node_modules/*) return 0 ;;
  esac
  return 1
}
documented() { grep -qF -- "$1" "$FRONT" || { [ -r "$HOOKS" ] && grep -qF -- "$1" "$HOOKS"; }; }

GAPS=0
# Added: `.new` is relative to ~/.cursor; an `.extra` row is new when the repo
# does not track that path yet.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  skip "$rel" && continue
  documented "${rel##*/}" || { echo "MISSING $rel"; GAPS=1; }
done < <(printf '%s' "$DRY" | jq -r --arg repo "$REPO" '
    [.new[]? | ".cursor/" + .] + [.extra[]? | select(test(": deleting$") | not) | sub("/\\./"; "/")] | unique | .[]' |
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    git -C "$REPO" cat-file -e "HEAD:$rp" 2>/dev/null || echo "$rp"
  done)

# Deleted: a name a README still carries describes something that is gone.
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  skip "$rel" && continue
  base="${rel##*/}"
  for f in "$FRONT" "$HOOKS"; do
    [ -r "$f" ] && grep -qF -- "$base" "$f" && { echo "STALE $rel (${f/#$HOME/~})"; GAPS=1; }
  done
done < <(printf '%s' "$DRY" | jq -r '
    [.deleted[]? | ".cursor/" + .] + [.extra[]? | select(test(": deleting$")) | sub(": deleting$"; "") | sub("/\\./"; "/")] | unique | .[]')

exit "$GAPS"
