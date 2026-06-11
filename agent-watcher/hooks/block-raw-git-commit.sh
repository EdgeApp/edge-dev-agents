#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks raw `git commit` in orchestrated agent
# sessions so every commit goes through lint-commit.sh, per im's commit contract.
# Deterministic counterpart to the advisory `im-owns-implementation` rule: 11/13
# audited runs (2026-06-10) committed raw despite the prose rule.
#
# Scope: no-ops unless AGENT_TASK_GID is set (exported by spawn-test-session.sh),
# so interactive human sessions are never affected.
# Allowed in agent sessions: lint-commit.sh (any args), and `git commit --amend`
# (one-shot's pr-watch-loop-amend-pattern prescribes amend+force-push in the watch
# loop). `--no-verify` is never allowed.
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

case "$CMD" in
  *lint-commit.sh*) exit 0 ;;
esac

if echo "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$)'; then
  if echo "$CMD" | grep -q -- '--no-verify'; then
    echo "BLOCKED: 'git commit --no-verify' is forbidden in agent sessions. A failing hook is a halt-on-error signal — fix the underlying failure (tsc/eslint/jest diagnostics are auto-fixable, max 2 attempts) or stop and report. Commit via ~/.cursor/skills/lint-commit.sh." >&2
    exit 2
  fi
  if echo "$CMD" | grep -q -- '--amend'; then
    exit 0
  fi
  echo "BLOCKED: raw 'git commit' is forbidden in agent sessions. Use ~/.cursor/skills/lint-commit.sh -m \"...\" [files...] (or --fixup <hash>) per ~/.cursor/skills/im/SKILL.md. The only raw-git exception is 'git commit --amend' inside the step-6 watch loop." >&2
  exit 2
fi

exit 0
