#!/usr/bin/env bash
# git-branch-ops.sh
# Shared deterministic git branch operations used by Cursor skills.
#
# Usage:
#   git-branch-ops.sh autosquash [--base <ref> | --merge-base-with <ref>]
#   git-branch-ops.sh push [--remote <name>] [--branch <name>] [--force-with-lease]
#
# Exit codes:
#   0 - success
#   1 - error
set -euo pipefail

CMD="${1:-}"
shift || true

BASE=""
MERGE_BASE_WITH=""
REMOTE="origin"
BRANCH=""
FORCE_WITH_LEASE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE="$2"
      shift 2
      ;;
    --merge-base-with)
      MERGE_BASE_WITH="$2"
      shift 2
      ;;
    --remote)
      REMOTE="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --force-with-lease)
      FORCE_WITH_LEASE="true"
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

resolve_default_upstream() {
  local upstream
  upstream="$(
    git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
      || echo "origin/$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')" \
      || echo "origin/master"
  )"
  if [[ -z "$upstream" || "$upstream" == "origin/" ]]; then
    echo "origin/master"
  else
    echo "$upstream"
  fi
}

run_autosquash() {
  if [[ -n "$BASE" && -n "$MERGE_BASE_WITH" ]]; then
    echo "Error: Use either --base or --merge-base-with, not both" >&2
    exit 1
  fi

  if [[ -z "$BASE" ]]; then
    if [[ -z "$MERGE_BASE_WITH" ]]; then
      MERGE_BASE_WITH="$(resolve_default_upstream)"
    fi

    BASE="$(git merge-base "$MERGE_BASE_WITH" HEAD 2>/dev/null || true)"
    if [[ -z "$BASE" ]]; then
      echo "Error: Could not determine merge-base with '$MERGE_BASE_WITH'" >&2
      exit 1
    fi
  fi

  rm -f "$(git rev-parse --git-path index.lock)"
  GIT_EDITOR=true GIT_SEQUENCE_EDITOR=: git rebase -i "$BASE" --autosquash
  echo ">> Autosquash complete (base: $BASE)"
}

run_push() {
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(git branch --show-current)"
  fi
  if [[ -z "$BRANCH" ]]; then
    echo "Error: Could not determine current branch" >&2
    exit 1
  fi

  if [[ "$FORCE_WITH_LEASE" == "true" ]]; then
    git push --force-with-lease "$REMOTE" "$BRANCH"
    echo ">> Push complete ($REMOTE/$BRANCH, mode: force-with-lease)"
  else
    git push "$REMOTE" "$BRANCH"
    echo ">> Push complete ($REMOTE/$BRANCH, mode: plain)"
  fi
}

case "$CMD" in
  autosquash)
    run_autosquash
    ;;
  push)
    run_push
    ;;
  *)
    echo "Usage: git-branch-ops.sh {autosquash|push} [args]" >&2
    exit 1
    ;;
esac
