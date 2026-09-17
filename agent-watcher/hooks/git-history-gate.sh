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
#   OPERATOR-APPROVED REWRITE: the operator can authorize a history rewrite on
#   a PR under active review (a fold of a squiggly path the reviewer will
#   re-read anyway). The authority is the operator's task comment; the agent
#   records it as /tmp/agent-history-rewrite-approved-<gid>.md citing that
#   comment AND naming its scope on a `Targets:` line (shape and parser:
#   git-branch-ops.sh header, `note-scope`). The note is never blanket
#   permission: `Targets: all` is the ONLY shape that flips a whole-branch
#   autosquash here, because that rebase squashes every pending fixup on the
#   branch, including ones the reviewer has not read. A note naming specific
#   shas, or the legacy note with no `Targets:` line, authorizes only a
#   one-fixup fold (lint-commit.sh --fixup, which calls git-branch-ops.sh
#   fold-one) and leaves the whole-branch block standing. Any non-empty note
#   still flips the preserve-mode PUSH, which is how an approved rewrite
#   reaches the remote. Audited by /eval-run: a note with no matching operator
#   comment is a finding.
#
#   PUSHES that ADD REWRITES of published branch work are blocked when the
#   oracle says AUTOSQUASH (no human reviewer yet): a standalone commit whose
#   removed lines came from commits already on the remote branch is an
#   amendment of that earlier commit wearing a feature subject (im's
#   clean-history), the shape followup segments produce when they read new
#   operator scope as "new work". `git-branch-ops.sh self-rewrite --gate` owns
#   the detection, the thresholds, the remediation text and the concession
#   note; pr-finalize-fixups.sh runs the same check before its autosquash so
#   both push paths agree. Preserve mode skips it (fixups are the model there
#   and the raw push is blocked anyway).
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
# Scope: EVERY session, orchestrated or chat. A history rewrite loses the same
# work either way. Companion scripts are exempt by DIRECTORY.
# Was: no-ops unless AGENT_TASK_GID is set (exported by spawn-test-session.sh),
# so interactive human sessions are never affected.
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
set -euo pipefail


CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

# Companion scripts are exempt by DIRECTORY, but only when one is actually
# INVOKED: lib/companion-invoked.sh owns the command-position test and the
# reason a substring match is not good enough.
printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/lib/companion-invoked.sh" && exit 0

# ---- commit discipline ------------------------------------------------------
if echo "$CMD_M" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$)'; then
  if echo "$CMD_M" | grep -q -- '--no-verify'; then
    echo "BLOCKED: 'git commit --no-verify' is forbidden in agent sessions. A failing hook is a halt-on-error signal — fix the underlying failure (tsc/eslint/jest diagnostics are auto-fixable, max 2 attempts) or stop and report. Commit via ~/.cursor/skills/lint-commit.sh." >&2
    exit 2
  fi
  if echo "$CMD_M" | grep -q -- '--amend'; then
    exit 0
  fi
  echo "BLOCKED: raw 'git commit' is forbidden in agent sessions. Use ~/.cursor/skills/lint-commit.sh -m \"...\" [files...] (or --fixup <hash> --for human|auto -m \"<why>\") per ~/.cursor/skills/im/SKILL.md. The only raw-git exception is 'git commit --amend' inside the step-6 watch loop." >&2
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
  # Scope the approval file per run, falling back to a shared chat path: this
  # gate now runs outside orch too, where AGENT_TASK_GID is unset and `set -u`
  # would abort the hook.
  REWRITE_OK="/tmp/agent-history-rewrite-approved-${AGENT_TASK_GID:-chat}.md"
  NOTE_TOO_NARROW=""
  if [ "$MODE" = "preserve" ] && [ -s "$REWRITE_OK" ]; then
    if [ "$NEEDS_MODE" = "push" ]; then
      echo ">> git-history-gate: preserve-mode push allowed by operator rewrite approval ($REWRITE_OK)" >&2
      MODE="autosquash"
    elif "$HOME/.cursor/skills/git-branch-ops.sh" note-scope --note "$REWRITE_OK" 2>/dev/null | grep -qx 'all'; then
      echo ">> git-history-gate: preserve-mode whole-branch autosquash allowed by operator rewrite approval ($REWRITE_OK says Targets: all)" >&2
      MODE="autosquash"
    else
      # The note exists but does not approve rewriting the WHOLE branch.
      NOTE_TOO_NARROW="$REWRITE_OK"
    fi
  fi
  if [ "$MODE" = "preserve" ]; then
    if [ "$NEEDS_MODE" = "squash" ]; then
      if [ -n "$NOTE_TOO_NARROW" ]; then
        cat >&2 <<MSG
BLOCKED: whole-branch autosquash while review-mode is PRESERVE. The operator
rewrite approval at $NOTE_TOO_NARROW does not cover it: it names
specific targets (or no \`Targets:\` line at all), and \`rebase --autosquash\`
squashes EVERY pending fixup on the branch, including the ones this reviewer
has not read yet.
  - Fold ONE approved fixup into its target:
    ~/.cursor/skills/lint-commit.sh --fixup <target-sha> --for human|auto -m "<why>"
    (or ~/.cursor/skills/git-branch-ops.sh fold-one --fixup <fixup-sha> for a
    fixup that already exists). The target must be named on a \`Targets:\` line.
  - The whole branch is in scope only when the operator approved that and the
    note says so: \`Targets: all\`, citing the operator comment.
MSG
        exit 2
      fi
      cat >&2 <<'MSG'
BLOCKED: autosquash while review-mode is PRESERVE (a human reviewer is active
on this PR). Preserved fixup! commits are what let the reviewer see exactly
what changed since their review — squashing now destroys that.
  - A red wip-guard CI check (block-wip-pr) is EXPECTED in this state; watch-pr
    reports it as `green-wip-preserve`, not a failure. Never squash to clear it.
  - Squashing becomes legitimate when the review is APPROVED/DISMISSED; run
    ~/.cursor/skills/pr-finalize-fixups.sh then — it re-checks the mode itself
    and squashes only when allowed.
  - The OPERATOR can approve a rewrite under review (a task comment saying so):
    record it as /tmp/agent-history-rewrite-approved-<gid>.md citing that
    comment and naming what it covers on a scope line:
        Targets: <sha> [<sha> ...]   those commits may be rewritten
        Targets: all                 the whole branch may be rewritten
    A named target lets `lint-commit.sh --fixup <sha>` fold THAT fixup into it
    (git-branch-ops.sh fold-one, one fixup, the rest of the branch untouched).
    Only `Targets: all` unblocks this whole-branch autosquash. Either way the
    note allows the force-with-lease push.
MSG
    else
      cat >&2 <<'MSG'
BLOCKED: raw `git push` while review-mode is PRESERVE (a review is active on
this PR). Reviewer bots bill PER PUSH (bugbot credit gate, 2026-07-31): finish
the WHOLE address round locally (one fixup per target and kind per one-fixup-
per-target-per-turn), then push ONCE via ~/.cursor/skills/pr-finalize-fixups.sh — it owns
the push, the squash-vs-preserve decision, and the condense to one fixup per
target and kind (human / auto). Never push mid-round to "see CI";
that buys a bot review of a HEAD you already know is incomplete.
MSG
    fi
    exit 2
  fi
  if [ "$MODE" = "autosquash" ] && [ "$NEEDS_MODE" = "push" ]; then
    SR_ERR=$("$HOME/.cursor/skills/git-branch-ops.sh" self-rewrite --gate 2>&1 >/dev/null) && SR_RC=0 || SR_RC=$?
    if [ "$SR_RC" -eq 2 ]; then
      printf '%s\n' "$SR_ERR" >&2
      exit 2
    fi
  fi
fi

exit 0
