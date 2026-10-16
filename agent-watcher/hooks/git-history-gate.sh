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
#   pre-review pushes (the amend+watch loop) resolve to
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
#   PLUMBING TYPED DIRECTLY: git-branch-ops.sh `push` and `autosquash` (and
#   pr-address.sh `autosquash`, a wrapper around the latter) live
#   under the skills directory but carry no review-mode policy, so a typed
#   `git-branch-ops.sh push` puts a mid-round HEAD on a PR under review. Both
#   face the same preserve checks as raw git. The push block
#   applies only while the branch carries fixup! or amend! commits (an address
#   round in flight); a landing push after pr-land's prepare has none and passes, as
#   do all pushes in autosquash mode. Calls made INSIDE a companion script
#   (pr-finalize-fixups.sh, cheese-build.sh) never reach this hook.
#
# Scope: EVERY session, orchestrated or chat. A history rewrite loses the same
# work either way. Every other companion script is simply not a git command:
# a line is judged by the git commands it runs, wherever it runs them.
# Was: no-ops unless AGENT_TASK_GID is set (exported by spawn-test-session.sh),
# so interactive human sessions are never affected.
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
set -euo pipefail


HOOK_INPUT=$(cat 2>/dev/null || true)
CMD=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
HOOK_CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

# Site-orch tenants are exempt from COMMIT discipline. A tenant repo carries orch.config.json at
# its root (a worktree included), commits with plain `git commit` by its own CLAUDE.md, and has
# none of the Edge commit tooling this gate routes to; the 2026-09-25 task-45 verify agent had to
# reach for lint-commit.sh against its repo's instructions. Matched by directory shape, never by
# repo name: the command's leading `cd` names the target when present, the hook's cwd otherwise.
# `--no-verify` stays blocked everywhere.
in_orch_tenant() {
  local dir="$1" root
  root=$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -f "$root/orch.config.json" ]
}
HOOKS="$HOME/.config/agent-watcher/hooks"
# What the line runs comes from cmd-parse.sh (lib/shell-commands.js): one
# event per command that matters here, in order, each with the directory it
# acts on (`git -C <dir>`, else the `cd` in force, else the hook's cwd; empty
# when the line hides it). A `git commit` inside `bash -c '...'`, behind
# `git -C <dir>`, or after a sanctioned script on the same line is an event
# like any other; text in quotes, heredocs and comments is none. Companion
# scripts need no exemption: their internal git calls never reach this hook,
# and a script name is not a git command.
EVENTS=""
PARSED_OK=0
if PARSED=$(printf '%s' "$CMD" | "$HOOKS/cmd-parse.sh" --cwd "${HOOK_CWD:-$PWD}" 2>/dev/null) &&
   EVENTS=$(printf '%s' "$PARSED" | jq -r '
     def d: (if .git then .git.dir else .cwd end) // "";
     if .name == "git-branch-ops.sh" and (.argv[1] == "push" or .argv[1] == "autosquash") then "gbo-\(.argv[1])\t\(d)"
     elif .name == "pr-address.sh" and .argv[1] == "autosquash" then "gbo-autosquash\t\(d)"
     elif .git and .git.sub == "commit" then
       (if .git.noVerify then "commit-noverify" elif .git.amend then "commit-amend" else "commit" end) + "\t" + d
     elif .git and .git.autosquash then "squash\t\(d)"
     elif .git and .git.sub == "push" then "push\t\(d)"
     else empty end' 2>/dev/null); then
  PARSED_OK=1
fi

GBO_OP=""
NEEDS_MODE=""
TARGET_DIR=""
if [ "$PARSED_OK" = 1 ]; then
  # ---- commit discipline ----------------------------------------------------
  if printf '%s\n' "$EVENTS" | grep -q '^commit-noverify	'; then
    echo "BLOCKED: 'git commit --no-verify' is forbidden in agent sessions. A failing hook is a halt-on-error signal — fix the underlying failure (tsc/eslint/jest diagnostics are auto-fixable, max 2 attempts) or stop and report. Commit via ~/.cursor/skills/lint-commit.sh." >&2
    exit 2
  fi
  while IFS=$'\t' read -r KIND DIR; do
    [ "$KIND" = "commit" ] || continue
    # A directory the line hides cannot be shown to be a tenant.
    [ -n "$DIR" ] && in_orch_tenant "$DIR" && continue
    echo "BLOCKED: raw 'git commit' is forbidden in agent sessions. Use ~/.cursor/skills/lint-commit.sh -m \"...\" [files...] (or --fixup <hash> --for human|auto -m \"<why>\") per ~/.cursor/skills/im/SKILL.md. The only raw-git exception is 'git commit --amend' inside the step-6 watch loop." >&2
    exit 2
  done <<< "$EVENTS"

  # ---- squash + push discipline: which event decides ------------------------
  # A sanctioned git-branch-ops.sh call first, then any autosquash, then a push.
  for WANT in gbo squash push; do
    LINE=$(printf '%s\n' "$EVENTS" | grep -m1 "^$WANT" || true)
    [ -n "$LINE" ] || continue
    KIND=${LINE%%	*}
    TARGET_DIR=${LINE#*	}
    case "$KIND" in
      gbo-autosquash) GBO_OP=autosquash; NEEDS_MODE=squash ;;
      gbo-push)       GBO_OP=push; NEEDS_MODE=push ;;
      squash)         NEEDS_MODE=squash ;;
      push)           NEEDS_MODE=push ;;
    esac
    break
  done
else
  # cmd-parse.sh could not read the line: the text match this gate had before.
  CMD_DIR=$(printf '%s' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^"&;|[:space:]]+)"?.*/\1/p' | head -1)
  CMD_DIR="${CMD_DIR/#\~/$HOME}"
  IN_TENANT=0
  in_orch_tenant "${CMD_DIR:-${HOOK_CWD:-$PWD}}" && IN_TENANT=1
  CMD_M=$(printf '%s' "$CMD" | "$HOOKS/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
  if printf '%s' "$CMD" | "$HOOKS/cmd-executes.sh" git-branch-ops.sh pr-address.sh; then
    GBO_OP=$(printf '%s' "$CMD" | grep -oE '(git-branch-ops\.sh"?[[:space:]]+(push|autosquash)|pr-address\.sh"?[[:space:]]+autosquash)([[:space:]]|$)' \
      | head -1 | sed -E 's/.*[[:space:]](push|autosquash).*/\1/' || true)
  fi
  if echo "$CMD_M" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$)'; then
    if echo "$CMD_M" | grep -q -- '--no-verify'; then
      echo "BLOCKED: 'git commit --no-verify' is forbidden in agent sessions. Commit via ~/.cursor/skills/lint-commit.sh." >&2
      exit 2
    fi
    echo "$CMD_M" | grep -q -- '--amend' && exit 0
    [ "$IN_TENANT" = 1 ] && exit 0
    echo "BLOCKED: raw 'git commit' is forbidden in agent sessions. Use ~/.cursor/skills/lint-commit.sh -m \"...\" [files...] per ~/.cursor/skills/im/SKILL.md." >&2
    exit 2
  fi
  if [ "$GBO_OP" = "autosquash" ]; then
    NEEDS_MODE="squash"
  elif [ "$GBO_OP" = "push" ]; then
    NEEDS_MODE="push"
  elif echo "$CMD_M" | grep -qE -- '--autosquash|git-branch-ops\.sh[[:space:]]+autosquash'; then
    NEEDS_MODE="squash"
  elif echo "$CMD_M" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]|$)'; then
    NEEDS_MODE="push"
  fi
  TARGET_DIR="$CMD_DIR"
fi
if [ -n "$NEEDS_MODE" ]; then
  # Resolve the PR for the branch the command targets: the directory of the
  # deciding command. Fail open when indeterminate.
  MODE=""
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
  if [ "$MODE" = "preserve" ] && [ "$GBO_OP" = "push" ]; then
    UPSTREAM=$("$HOME/.cursor/skills/git-branch-base.sh" 2>/dev/null || echo origin/master)
    MB=$(git merge-base "$UPSTREAM" HEAD 2>/dev/null || true)
    # Capture first: `git log | grep -q` dies of SIGPIPE under pipefail.
    SUBJECTS=$([ -n "$MB" ] && git log "$MB..HEAD" --format=%s 2>/dev/null || true)
    if ! printf '%s\n' "$SUBJECTS" | grep -qE '^(fixup|amend)! '; then
      exit 0
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
BLOCKED: `git push` (raw, or git-branch-ops.sh push with fixup!/amend! commits on
the branch) while review-mode is PRESERVE (a review is active on this PR). Reviewer bots bill PER PUSH (bugbot credit gate, 2026-07-31): finish
the WHOLE address round locally (one fixup per target and kind per one-fixup-
per-target-per-turn), then push ONCE via ~/.cursor/skills/pr-finalize-fixups.sh — it owns
the push, the squash-vs-preserve decision, and the condense to one fixup per
target and kind (human / auto). Never push mid-round to "see CI";
that buys a bot review of a HEAD you already know is incomplete.
MSG
    fi
    exit 2
  fi
  # Plumbing pushes keep their pre-gate behavior outside preserve: the
  # self-rewrite check is for raw pushes and pr-finalize-fixups.sh.
  [ -n "$GBO_OP" ] && exit 0
  if [ "$MODE" = "autosquash" ] && [ "$NEEDS_MODE" = "push" ]; then
    SR_ERR=$("$HOME/.cursor/skills/git-branch-ops.sh" self-rewrite --gate 2>&1 >/dev/null) && SR_RC=0 || SR_RC=$?
    if [ "$SR_RC" -eq 2 ]; then
      printf '%s\n' "$SR_ERR" >&2
      exit 2
    fi
  fi
fi

exit 0
