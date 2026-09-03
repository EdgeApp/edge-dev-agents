#!/usr/bin/env bash
# require-tdd-current.sh — PreToolUse(Bash).
# On a TDD-flagged task, block `update-status.sh <gid> Complete` while the
# committed TDD is OLDER than the code it documents.
#
# Followups edit the doc surgically (patch the section they touched) and leave
# the rest describing a previous phase's implementation. The remedy is a WHOLE
# doc re-read against the current diff, which is what the deny message demands.
#
# Deterministic, two generations:
#   STAMPED doc (tdd-stamp.sh wrote `<!-- tdd-code-fingerprint: <sha> -->`):
#     current when the stamp equals the fingerprint of HEAD's code tree (every
#     blob outside src/docs). History position is irrelevant, which is the
#     point: the doc rides in the branch's FIRST commit (tdd
#     doc-rides-the-first-commit) and every revision folds into it, so "last
#     doc commit older than last code commit" is true on every healthy branch.
#   UNSTAMPED doc (written before the stamp existed): the older comparison,
#     last commit touching src/docs vs last commit touching code.
# No judgment, no agent goodwill. Fails OPEN on anything it cannot determine
# (no worktree, no doc, no field, git/API error) — a gate that guesses would
# block clean runs.
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
STAMP_SH="$HOME/.cursor/skills/tdd/scripts/tdd-stamp.sh"
DOC_REL="${DOC#$REPO_DIR}"; DOC_REL="${DOC_REL#/}"
# Stamped doc: compare against the COMMITTED doc at HEAD (the gate is about what
# ships, not what sits unstaged in the worktree).
if [ -x "$STAMP_SH" ] && git -C "$REPO_DIR" show "HEAD:$DOC_REL" 2>/dev/null | grep -q 'tdd-code-fingerprint:'; then
  STAMPED=$(git -C "$REPO_DIR" show "HEAD:$DOC_REL" | grep -oE 'tdd-code-fingerprint: [0-9a-f]{40}' | head -1 | awk '{print $2}')
  HEAD_FP=$("$STAMP_SH" "$REPO_DIR" --fingerprint 2>/dev/null || echo "")
  [ -n "$HEAD_FP" ] || exit 0
  [ "$STAMPED" = "$HEAD_FP" ] && exit 0
  cat >&2 <<MSG
BLOCKED: the committed TDD documents a different code tree than HEAD.
  doc:   $(basename "$DOC") stamped $STAMPED
  HEAD:  code fingerprint $HEAD_FP (every blob outside src/docs)
Code changed after the doc was last stamped. Re-read the WHOLE doc against
\`git diff $BASE..HEAD\` (not just the section you touched: followups drift by
patching one section while the rest describes an earlier phase, tdd
current-state-body-phases-in-one-section), rewrite what reality moved, append
this phase's entry under ## Phase history, then:
  $STAMP_SH $REPO_DIR $DOC_REL
  ~/.cursor/skills/lint-commit.sh --fixup \$(git rev-list --reverse $BASE..HEAD | head -1) $DOC_REL
(the doc rides in the branch's FIRST commit, tdd doc-rides-the-first-commit;
lint-commit autosquashes the fixup into it).
Legitimately no doc change owed? Write /tmp/agent-tdd-current-waiver-$AGENT_TASK_GID.md
with the reason (audited by /eval-run).
MSG
  exit 2
fi
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
  - Stamp it ($STAMP_SH $REPO_DIR $DOC_REL) and fold it into the branch's
    FIRST commit: ~/.cursor/skills/lint-commit.sh --fixup <first-commit-sha> $DOC_REL
    (tdd doc-rides-the-first-commit).
Legitimately no doc change owed? Write /tmp/agent-tdd-current-waiver-$AGENT_TASK_GID.md
with the reason (audited by /eval-run).
MSG
exit 2
