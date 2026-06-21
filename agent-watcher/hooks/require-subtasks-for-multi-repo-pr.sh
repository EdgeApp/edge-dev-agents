#!/usr/bin/env bash
# require-subtasks-for-multi-repo-pr.sh — PreToolUse(Bash).
# When a task's run produced PRs across MORE THAN ONE repo, the PRs must be structured
# subtask-per-PR (one-shot `multi-repo-subtasks`), never flat-attached onto the main
# task. A run is multi-repo when its worktree root holds >1 repo on a FEATURE branch
# (not the base develop/master/main). Block a `/pr-create` that flat-attaches in that
# case; `--no-asana-attach` or a `--create-subtask ... --attach-pr` call passes.
# Enforcement-over-prose: the 2026-06-20 eval cohort had a run flat-attach a 2-repo PR set.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Only gate pr-create invocations.
case "$CMD" in *pr-create*) ;; *) exit 0 ;; esac
# The compliant multi-repo paths are explicitly allowed.
printf '%s' "$CMD" | grep -q -- '--no-asana-attach' && exit 0
printf '%s' "$CMD" | grep -q -- '--create-subtask' && exit 0

WT="$HOME/git/.agent-worktrees/$AGENT_TASK_GID"
[ -d "$WT" ] || exit 0

# Count repo worktrees that are on a FEATURE branch (real PR work), not the base.
feature_repos=0
names=""
for d in "$WT"/*/; do
  [ -e "$d/.git" ] || continue
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  case "$br" in
    develop|master|main|"") ;;                     # base / detached — not PR work
    *) feature_repos=$((feature_repos + 1)); names="$names $(basename "$d")" ;;
  esac
done

if [ "$feature_repos" -gt 1 ]; then
  echo "BLOCKED: this run has feature branches in $feature_repos repos ($names ) — a multi-repo run must NOT flat-attach PRs onto the main task. Run /pr-create with --no-asana-attach, then create a subtask per PR and attach each via 'asana-task-update.sh --create-subtask --subtask-name ... --attach-pr ...' (one-shot rule multi-repo-subtasks). Single-repo runs attach their one PR directly." >&2
  exit 2
fi
exit 0
