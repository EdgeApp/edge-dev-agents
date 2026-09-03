#!/usr/bin/env bash
# ensure-tdd-pr-link.sh — PreToolUse(Bash).
# On a TDD-flagged task, make sure each PR body links the TDD doc at the BRANCH
# HEAD before the run reports Complete.
#
# Why a rewrite and not a gate: the doc is written AFTER at least one dev turn
# (tdd write-after-building), so it almost never exists when /pr-create builds
# the body. Something has to add the link later, and "the agent remembers to
# re-edit the body" is exactly the class of obligation that dies in compaction.
# Appending one link to the run's own PR is fully determined, so it is done here
# instead of asked for.
#
# ONE DOC, EVERY PR: the task has a single TDD (tdd lives-in-the-pr puts it in
# the primary repo), but a multi-repo task's OTHER PRs are covered by the same
# doc and their reviewers need the pointer too. So the URL is resolved ONCE
# from whichever worktree holds the doc, then added to EVERY worktree's PR
# body that lacks it (the doc-hosting repo's PR and each companion PR alike).
#
# PLACEMENT (operator ruling 2026-08-07): the link is the PR body's FIRST
# section, so a reviewer sees the design before the description:
#
#   ### Technical Design Document
#
#   [<doc filename>](<branch url>)
#
# The label is the doc FILENAME (deterministic; no H1 parsing).
#
# BRANCH url, never a commit permalink: the PR must follow the branch so a
# reviewer always sees the doc as it stands with the code. The run report carries
# the pinned form (require-clean-run-report.sh) — operator ruling 2026-07-28.
#
# IDEMPOTENCY IS BY NORMALIZATION, not by a substring test. The body is rebuilt
# with the section stripped and re-prepended, and skipped only when that rebuild
# equals what is already there. A "does the body contain the url" test passes for
# a body that merely mentions the doc in a sentence, which leaves the required
# first section absent for as long as the prose survives.
#
# Never blocks. Any failure (no PR, no doc, gh error, PR owned by someone else)
# leaves the body untouched and the run continues.
set -euo pipefail
exec 3>&2   # keep a handle for notes; all paths exit 0

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

FIELD=$("$HOME/.cursor/skills/asana-field-value.sh" "$AGENT_TASK_GID" "TDD?" 2>/dev/null || echo "none")
[ "$FIELD" = "tdd" ] || exit 0

# Resolve the doc URL once, from whichever worktree hosts the doc.
URL=""
for REPO_DIR in "$HOME/git/.agent-worktrees/$AGENT_TASK_GID"/*/; do
  [ -d "$REPO_DIR" ] || continue
  U=$("$HOME/.cursor/skills/tdd/scripts/tdd-doc-links.sh" "$REPO_DIR" 2>/dev/null | sed -n 's/^TDD_BRANCH_URL=//p') || true
  if [ -n "${U:-}" ]; then URL="$U"; break; fi
done
[ -n "$URL" ] || exit 0

# Append the link to every worktree PR that lacks it.
for REPO_DIR in "$HOME/git/.agent-worktrees/$AGENT_TASK_GID"/*/; do
  [ -d "$REPO_DIR" ] || continue

  PR=$(cd "$REPO_DIR" && gh pr view --json number,body 2>/dev/null) || continue
  NUM=$(printf '%s' "$PR" | jq -r '.number // empty')
  BODY=$(printf '%s' "$PR" | jq -r '.body // ""')
  [ -n "$NUM" ] || continue

  # Normalize rather than test-and-skip: strip any existing TDD section, then
  # prepend a fresh one. Idempotent by construction, and it fixes the two states
  # a substring test passes wrongly — a body that only MENTIONS the url in prose,
  # and a section sitting below the description instead of first.
  NEW=$(BODY="$BODY" FNAME="${URL##*/}" DOCURL="$URL" node -e '
const body = process.env.BODY || ""
const heading = "### Technical Design Document"
const section = new RegExp("^" + heading + "[ \\t]*\\n+\\[[^\\]]*\\]\\([^)]*\\)[ \\t]*\\n*", "m")
const stripped = body.replace(section, "").replace(/^\n+/, "")
process.stdout.write(heading + "\n\n[" + process.env.FNAME + "](" + process.env.DOCURL + ")\n\n" + stripped)
') || continue

  # Already correct: no API call, so a Complete on an unchanged PR is free.
  [ "$NEW" = "$BODY" ] && continue

  TMP="/tmp/pr-body-tdd-$AGENT_TASK_GID-$NUM.md"
  printf '%s\n' "$NEW" > "$TMP"

  if (cd "$REPO_DIR" && gh pr edit "$NUM" --body-file "$TMP" >/dev/null 2>&1); then
    echo ">> ensure-tdd-pr-link: added TDD link to PR #$NUM ($URL)" >&3
  fi
  rm -f "$TMP"
done

exit 0
