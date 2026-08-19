#!/usr/bin/env bash
# require-tdd-current.sh — PreToolUse(Bash).
# On a TDD-flagged task, block `update-status.sh <gid> Complete` while the
# committed TDD is OLDER than the code it documents.
#
# Followups edit the doc surgically (patch the section they touched) and leave
# the rest describing a previous phase's implementation. The remedy is a WHOLE
# doc re-read against the current diff, which is what the deny message demands.
#
# Deterministic: compares the last commit touching `src/docs/*.md` against the
# last commit touching code, on the task's branch. No judgment, no agent
# goodwill. Fails OPEN on anything it cannot determine (no worktree, no doc, no
# field, git/API error) — a gate that guesses would block clean runs.
#
# Escape hatch: /tmp/agent-tdd-current-waiver-<gid>.md explaining why the doc is
# legitimately unchanged (audited by /eval-run; an unjustified note is a finding).
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
printf '%s' "$CMD_M" | grep -qE 'update-status\.sh[^|;&]*[[:space:]]Complete([[:space:]]|$)' || exit 0

[ -f "/tmp/agent-tdd-current-waiver-$AGENT_TASK_GID.md" ] && exit 0

# TDD-flagged? (fail open on any resolution problem)
FIELD=$("$HOME/.cursor/skills/asana-field-value.sh" "$AGENT_TASK_GID" "TDD?" 2>/dev/null || echo "")
[ "$FIELD" = "tdd" ] || exit 0

# Locate the task's worktree (any repo under it that carries the doc).
WT_ROOT="$HOME/git/.agent-worktrees/$AGENT_TASK_GID"
[ -d "$WT_ROOT" ] || exit 0
DOC=""; REPO_DIR=""
for d in "$WT_ROOT"/*/; do
  [ -d "$d/src/docs" ] || continue
  f=$(ls "$d"/src/docs/*.md 2>/dev/null | head -1) || true
  if [ -n "$f" ]; then DOC="$f"; REPO_DIR="$d"; break; fi
done
# No committed doc yet: the write-after-building flow may legitimately still owe
# the first version, which tdd-flow grades post-hoc. Not this gate's business.
[ -n "$DOC" ] && [ -n "$REPO_DIR" ] || exit 0

BASE=$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "origin/develop")
DOC_TS=$(git -C "$REPO_DIR" log -1 --format=%ct -- src/docs 2>/dev/null || echo "")
CODE_TS=$(git -C "$REPO_DIR" log -1 --format=%ct -- . ':(exclude)src/docs' 2>/dev/null || echo "")
[ -n "$DOC_TS" ] && [ -n "$CODE_TS" ] || exit 0
[ "$CODE_TS" -le "$DOC_TS" ] 2>/dev/null && exit 0

NEWER=$(git -C "$REPO_DIR" log --oneline "$BASE..HEAD" --since="@$DOC_TS" -- . ':(exclude)src/docs' 2>/dev/null | head -5 || true)
cat >&2 <<MSG
BLOCKED: the committed TDD is older than the code it documents.
  doc:  $(basename "$DOC") (last touched $(date -r "$DOC_TS" '+%Y-%m-%d %H:%M'))
  code commits since:
$(printf '%s\n' "$NEWER" | sed 's/^/    /')

Update it before Complete, and re-read the WHOLE doc against the current diff —
not just the section you touched. Followups drift by patching one section while
the rest still describes an earlier phase (one-shot tdd-when-flagged, tdd
current-state-body-phases-in-one-section):
  - BODY: rewrite every section that reality moved, so it reads as current truth.
  - ## Phase history: append THIS phase's entry (queued / shipped / diverged).
  - Commit the doc on the PR branch via ~/.cursor/skills/lint-commit.sh.
Legitimately no doc change owed? Write /tmp/agent-tdd-current-waiver-$AGENT_TASK_GID.md
with the reason (audited by /eval-run).
MSG
exit 2
