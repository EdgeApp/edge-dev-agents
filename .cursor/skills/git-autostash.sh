#!/usr/bin/env bash
# git-autostash.sh: stash a primary checkout's uncommitted work under a label,
# leaving gitignored config in place.
#
# `git stash --include-untracked` takes every file the CHECKED-OUT branch does not
# ignore. A branch cut before a file joined .gitignore sees that file as ordinary
# untracked work, so a stash there removes app config and secrets from the checkout.
# This script keeps any untracked file ignored by the root .gitignore of any named
# ref, read at run time, so a file added to .gitignore later is covered by no edit
# here. Nested .gitignore files are honored for the checked-out branch only, which
# is what git itself reads.
#
# Default refs: origin/HEAD, origin/develop, origin/main, origin/master (each if it
# resolves). --ignore-ref adds more, such as the branch about to be checked out.
#
# Usage: git-autostash.sh --repo <dir> --message "<label>" [--ignore-ref <ref>]...
# Stdout, one line: STASHED <label> | NOTHING
# Stderr: ">> git-autostash: kept in place: <file>" for each file left alone.
# Exit: 0 stashed or nothing to stash; 1 git refused (mid-rebase, conflict); 2 usage.
set -euo pipefail

REPO=""; MESSAGE=""; REFS=(origin/HEAD origin/develop origin/main origin/master)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --message) MESSAGE="${2:-}"; shift 2 ;;
    --ignore-ref) REFS+=("${2:-}"); shift 2 ;;
    *) echo "git-autostash: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" && -n "$MESSAGE" ]] || { echo "usage: git-autostash.sh --repo <dir> --message <label> [--ignore-ref <ref>]..." >&2; exit 2; }
cd "$REPO"
cd "$(git rev-parse --show-toplevel)"

if [[ -z "$(git status --porcelain)" ]]; then
  echo "NOTHING"
  exit 0
fi

PATTERNS="$(mktemp)"
trap 'rm -f "$PATTERNS"' EXIT
for ref in "${REFS[@]}"; do
  git show "$ref:.gitignore" 2>/dev/null >> "$PATTERNS" || true
  echo >> "$PATTERNS"
done

# Every path here is untracked and unignored by the checkout's own rules, so a
# check-ignore hit can only come from the patterns gathered above.
KEEP=()
while IFS= read -r f; do
  [[ -n "$f" ]] && KEEP+=("$f")
done < <(git ls-files --others --exclude-standard \
  | git -c core.excludesFile="$PATTERNS" check-ignore --stdin 2>/dev/null || true)

PATHSPEC=(.)
for f in ${KEEP[@]+"${KEEP[@]}"}; do
  echo ">> git-autostash: kept in place: $f" >&2
  PATHSPEC+=(":(exclude,top,literal)$f")
done

# With only kept files dirty there is no work to stash.
if [[ -z "$(git status --porcelain -- "${PATHSPEC[@]}")" ]]; then
  echo "NOTHING"
  exit 0
fi

git stash push --quiet --include-untracked -m "$MESSAGE" -- "${PATHSPEC[@]}" >&2 || exit 1
echo "STASHED $MESSAGE"
