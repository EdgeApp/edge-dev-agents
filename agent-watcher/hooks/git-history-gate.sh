#!/usr/bin/env bash
# git-history-gate.sh — PreToolUse(Bash). One concept: git HISTORY MUTATIONS go
# through the scripts that own them. (Renamed from block-raw-git-commit.sh
# 2026-07-28 when squash discipline joined commit discipline.)
#
#   COMMITS  go through lint-commit.sh, per im's commit contract. Deterministic
#   counterpart to the advisory `im-owns-implementation` rule: 11/13 audited
#   runs (2026-06-10) committed raw despite the prose rule. Allowed raw:
#   `git commit --amend` (one-shot's pr-watch-loop-amend-pattern). Never
#   allowed: `--no-verify`.
#
#   PUSHES (while a review is active) go through pr-finalize-fixups.sh too —
#   one push per address round (2026-07-31 bugbot credit gate: reviewer bots
#   bill per push, and mid-pass pushes buy reviews of known-incomplete HEADs).
#   Raw `git push` is blocked only when the review-mode oracle says PRESERVE;
#   pre-review pushes (the amend+watch loop on a draft) resolve to
#   autosquash/none and stay raw and free.
#
#   SQUASHES go through pr-finalize-fixups.sh, whose review-mode oracle
#   (pr-address.sh review-mode) owns squash-vs-preserve. A raw
#   `git rebase --autosquash` (or a direct git-branch-ops.sh autosquash, the
#   policy-free plumbing) is blocked when the oracle says PRESERVE — squashing
#   mid-review destroys the reviewer's delta view, the exact off-book move of
#   the swapter run (PR #475, 2026-07-28: agent autosquashed to clear a red
#   block-wip-pr while CHANGES_REQUESTED stood; watch-pr now classifies that
#   red as green-wip-preserve so the temptation is gone too). Typed commands
#   invoking pr-finalize-fixups.sh itself don't match here — that script IS
#   the sanctioned path and does its own mode logic. Fails OPEN when the mode
#   cannot be determined (no PR, network error): a gate that guesses would
#   block legitimate pre-review autosquashes.
#
# Scope: no-ops unless AGENT_TASK_GID is set (exported by spawn-test-session.sh),
# so interactive human sessions are never affected.
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
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

case "$CMD" in
  *lint-commit.sh*) exit 0 ;;
  *pr-finalize-fixups.sh*) exit 0 ;;
esac

# ---- commit discipline ------------------------------------------------------
if echo "$CMD_M" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$)'; then
  if echo "$CMD_M" | grep -q -- '--no-verify'; then
    echo "BLOCKED: 'git commit --no-verify' is forbidden in agent sessions. A failing hook is a halt-on-error signal — fix the underlying failure (tsc/eslint/jest diagnostics are auto-fixable, max 2 attempts) or stop and report. Commit via ~/.cursor/skills/lint-commit.sh." >&2
    exit 2
  fi
  if echo "$CMD_M" | grep -q -- '--amend'; then
    exit 0
  fi
  echo "BLOCKED: raw 'git commit' is forbidden in agent sessions. Use ~/.cursor/skills/lint-commit.sh -m \"...\" [files...] (or --fixup <hash>) per ~/.cursor/skills/im/SKILL.md. The only raw-git exception is 'git commit --amend' inside the step-6 watch loop." >&2
  exit 2
fi

# ---- squash + push discipline -----------------------------------------------
NEEDS_MODE=""
if echo "$CMD_M" | grep -qE -- '--autosquash|git-branch-ops\.sh[[:space:]]+autosquash'; then
  NEEDS_MODE="squash"
elif echo "$CMD_M" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]|$)'; then
  NEEDS_MODE="push"
fi
if [ -n "$NEEDS_MODE" ]; then
  # Resolve the PR for the branch the command targets. Compound commands are
  # usually `cd <worktree> && git rebase ...` while the hook's own cwd is
  # elsewhere — honor the command's leading cd. Fail open when indeterminate.
  MODE=""
  TARGET_DIR=$(printf '%s' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^"&;|[:space:]]+)"?.*/\1/p' | head -1)
  TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
  [ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ] && cd "$TARGET_DIR" 2>/dev/null || true
  PRJSON=$(gh pr view --json number,headRepositoryOwner,headRepository 2>/dev/null || true)
  if [ -n "$PRJSON" ]; then
    PRNUM=$(printf '%s' "$PRJSON" | jq -r '.number // empty')
    OWNER=$(printf '%s' "$PRJSON" | jq -r '.headRepositoryOwner.login // empty')
    RNAME=$(printf '%s' "$PRJSON" | jq -r '.headRepository.name // empty')
    if [ -n "$PRNUM" ] && [ -n "$OWNER" ] && [ -n "$RNAME" ]; then
      MODE=$("$HOME/.cursor/skills/pr-address/scripts/pr-address.sh" review-mode \
        --owner "$OWNER" --repo "$RNAME" --pr "$PRNUM" 2>/dev/null \
        | jq -r '.mode // empty' 2>/dev/null || true)
    fi
  fi
  if [ "$MODE" = "preserve" ]; then
    if [ "$NEEDS_MODE" = "squash" ]; then
      cat >&2 <<'MSG'
BLOCKED: autosquash while review-mode is PRESERVE (a human reviewer is active
on this PR). Preserved fixup! commits are what let the reviewer see exactly
what changed since their review — squashing now destroys that.
  - A red wip-guard CI check (block-wip-pr) is EXPECTED in this state; watch-pr
    reports it as `green-wip-preserve`, not a failure. Never squash to clear it.
  - Squashing becomes legitimate when the review is APPROVED/DISMISSED; run
    ~/.cursor/skills/pr-finalize-fixups.sh then — it re-checks the mode itself
    and squashes only when allowed.
MSG
    else
      cat >&2 <<'MSG'
BLOCKED: raw `git push` while review-mode is PRESERVE (a review is active on
this PR). Reviewer bots bill PER PUSH (bugbot credit gate, 2026-07-31): finish
the WHOLE address round locally (fixups + amends per one-fixup-per-target-per-
turn), then push ONCE via ~/.cursor/skills/pr-finalize-fixups.sh — it owns the
push (and the squash-vs-preserve decision). Never push mid-round to "see CI";
that buys a bot review of a HEAD you already know is incomplete.
MSG
    fi
    exit 2
  fi
fi

exit 0
