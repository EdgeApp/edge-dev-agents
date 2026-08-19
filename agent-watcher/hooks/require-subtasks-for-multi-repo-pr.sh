#!/usr/bin/env bash
# require-subtasks-for-multi-repo-pr.sh — PreToolUse(Bash).
# When a task's run produced PRs across MORE THAN ONE repo, the PRs must be structured
# subtask-per-PR (one-shot `multi-repo-subtasks`), never flat-attached onto the main
# task. A run is multi-repo when its worktree root holds >1 repo on a feature branch
# WITH commits ahead of the origin base (a provisioned branch with zero commits is
# not PR work). Block a pr-create.sh EXECUTION that flat-attaches in that case;
# `--no-asana-attach` or a `--create-subtask ... --attach-pr` call passes, and
# read-only commands that merely name the script path never fire it.
# Enforcement-over-prose: the 2026-06-20 eval cohort had a run flat-attach a 2-repo PR set.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

# Only gate pr-create.sh EXECUTIONS: the script token must sit in command
# position (start of command, or after ;, &, |, ( or $( or an explicit
# bash/sh/source). A read-only command that merely NAMES the script path in
# argument position (grep/sed/cat against it) must not fire — that shape
# blocked 3 read-only greps on the 2026-08-19 eCash run (5-run FP class,
# 3rd cohort in a row). Match the SCRIPT, not the directory: a bare
# *pr-create* also matched sibling helpers under skills/pr-create/scripts/
# (pr-attach-screenshots.sh) with no compliant way through.
printf '%s' "$CMD_M" | grep -qE '(^|[;&|(]|\$\(|\b(bash|sh|source)[[:space:]]+)[[:space:]]*[^[:space:]]*pr-create\.sh([[:space:]]|$)' || exit 0
# The compliant multi-repo paths are explicitly allowed.
printf '%s' "$CMD_M" | grep -q -- '--no-asana-attach' && exit 0
printf '%s' "$CMD_M" | grep -q -- '--create-subtask' && exit 0

WT="$HOME/git/.agent-worktrees/$AGENT_TASK_GID"
[ -d "$WT" ] || exit 0

# Count repo worktrees holding REAL PR work: a feature branch WITH commits ahead
# of the origin base. Branch name alone over-counted — the harness provisions
# every worktree on a feature-named branch, so zero-commit and harness-only
# worktrees misfired (Cacao/AVAX/Nym/Swapuz, 2026-08-19 cohort). Detached HEAD
# ("HEAD") is skipped explicitly. A repo with no resolvable origin base falls
# back to the old name-only test (fail toward enforcement, never silently open).
feature_repos=0
names=""
for d in "$WT"/*/; do
  [ -e "$d/.git" ] || continue
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  case "$br" in
    develop|master|main|HEAD|"") continue ;;       # base / detached — not PR work
  esac
  base=""
  for b in origin/develop origin/master origin/main; do
    if git -C "$d" rev-parse --verify -q "$b" >/dev/null 2>&1; then base="$b"; break; fi
  done
  if [ -n "$base" ]; then
    ahead=$(git -C "$d" rev-list --count "$base..HEAD" 2>/dev/null || echo 1)
    [ "${ahead:-1}" -gt 0 ] 2>/dev/null || continue  # provisioned but no commits — not PR work
  fi
  feature_repos=$((feature_repos + 1)); names="$names $(basename "$d")"
done

if [ "$feature_repos" -gt 1 ]; then
  echo "BLOCKED: this run has feature branches in $feature_repos repos ($names ) — a multi-repo run must NOT flat-attach PRs onto the main task. Run /pr-create with --no-asana-attach, then create a subtask per PR and attach each via 'asana-task-update.sh --create-subtask --subtask-name ... --attach-pr ...' (one-shot rule multi-repo-subtasks). Single-repo runs attach their one PR directly." >&2
  exit 2
fi
exit 0
