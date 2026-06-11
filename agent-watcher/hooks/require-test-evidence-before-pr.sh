#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks pr-create.sh in orchestrated agent
# sessions until in-app test evidence exists, per build-and-test's
# test-on-sim-by-default and gui-dependency-integration rules. Deterministic
# counterpart to the prose rules that 4/7 dep-repo runs skipped (2026-06-10 audit).
#
# Scope: no-ops unless AGENT_TASK_GID is set. Draft dependency PRs created with
# `gh pr create --draft` are not gated (per one-shot's dep-pr-draft-vs-bump).
#
# Evidence, either of:
#   1. A proof screenshot: /tmp/agent-proof-<gid>-*.png  (build-and-test writes these)
#   2. A sanctioned-blocker note: /tmp/agent-test-blocker-<gid>.md — written by the
#      agent, stating WHICH playbook-sanctioned blocker applies (provider halt,
#      genuinely funded attempt hit a documented crash, repo is not a gui dependency).
#      The note is auditable by /eval-run; an unjustified note is a finding.
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

case "$CMD" in
  *pr-create.sh*) ;;
  *) exit 0 ;;
esac

if ls /tmp/agent-proof-"$AGENT_TASK_GID"-*.png >/dev/null 2>&1; then
  exit 0
fi
if [ -s "/tmp/agent-test-blocker-$AGENT_TASK_GID.md" ]; then
  exit 0
fi

echo "BLOCKED: no in-app test evidence for task $AGENT_TASK_GID. Before creating the PR, run /build-and-test and drive the changed behavior on the sim to its terminal state (proof screenshots land at /tmp/agent-proof-$AGENT_TASK_GID-NN-<slug>.png). For a gui-dependency repo this includes the gui integration test. If a playbook-sanctioned blocker genuinely applies (provider halt; a funded attempt hit a documented crash; repo is not a gui dependency), write the specific justification to /tmp/agent-test-blocker-$AGENT_TASK_GID.md and retry — the note is audited. NOT valid blockers: 'no funds' (swap-to-fund per the playbook); task scope ('deliverable is dep-repo only', 'prototype', 'gui wiring deferred' — local gui-worktree wiring is test scaffolding, not a production change); 'unvetted code + real funds' (small sanctioned-roster swaps through new plugins are the prescribed test)." >&2
exit 2
