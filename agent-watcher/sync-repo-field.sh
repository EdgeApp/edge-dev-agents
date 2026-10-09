#!/usr/bin/env bash
# sync-repo-field.sh: keep the task's Repo field equal to the repos the task
# changed, adding and removing options on every Complete. "Changed" = the repo
# of each PR attached to the task or one of its subtasks (lib/task-pr-urls.sh)
# that is open or merged; a PR closed without merging is abandoned work. The
# write goes through asana-task-update.sh --set-repos, which owns the GitHub
# repo -> option map (asana-config custom_fields.repo.github_repo_options),
# only removes options that map covers, and records the write so the next
# segment's field-delta check does not read it as operator intent.
#
# A task with NO attached PR at all is left untouched: there is nothing to
# reflect (a research or no-PR deliverable), and clearing the field would erase
# what a person set. PRs attached but all closed unmerged means no repo changed,
# so the managed options come off.
#
# Called by update-status.sh after a Complete write succeeds (so only a
# completion that passed every gate syncs), and by asana-task-update.sh when a
# PR link is attached or detached on a task that is already Complete. Safe to
# run by hand.
#
# Usage: sync-repo-field.sh --task-gid <gid>
# Exit: 0 synced or nothing to do; 1 the Asana write failed; 2 usage.
set -uo pipefail

DIR="$HOME/.config/agent-watcher"
GID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid) GID="$2"; shift 2 ;;
    *) echo "sync-repo-field: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$GID" ]] || { echo "usage: sync-repo-field.sh --task-gid <gid>" >&2; exit 2; }

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$DIR/credentials.json" 2>/dev/null)}"
[[ -n "$TOKEN" ]] || { echo ">> Repo sync: no Asana token; skipped" >&2; exit 0; }
source "$DIR/lib/task-pr-urls.sh"

REPOS=(); ANY_PR=false
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  ANY_PR=true
  slug=$(sed -E 's#https://github.com/([^/]+/[^/]+)/pull/[0-9]+#\1#' <<<"$url")
  num="${url##*/}"
  state=$(gh pr view "$num" --repo "$slug" --json state -q .state 2>/dev/null || echo UNKNOWN)
  [[ "$state" == "CLOSED" ]] && continue
  REPOS+=("${slug##*/}")
done < <(task_pr_urls "$GID")

if ! $ANY_PR; then
  echo ">> Repo sync: no PR attached to task $GID or its subtasks; Repo left as is"
  exit 0
fi
CSV=""
[[ ${#REPOS[@]} -gt 0 ]] && CSV=$(printf '%s\n' "${REPOS[@]}" | sort -u | paste -sd, -)
# An empty set (every PR closed unmerged) still has to reach --set-repos, which
# then removes the managed options; a lone comma is an empty list to it.
"$HOME/.cursor/skills/asana-task-update/scripts/asana-task-update.sh" --task "$GID" --set-repos "${CSV:-,}"
