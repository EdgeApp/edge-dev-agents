#!/usr/bin/env bash
# require-skill-read-for-scripts.sh — PreToolUse hook (matcher: Bash). Blocks
# executing a skill's companion script before the owning SKILL.md entered this
# run's context. A companion script is one STEP of its skill's contract; bare
# invocation ships the step without the contract around it (asana-get-context
# run bare fetches attachments nobody then opens — the 08-24/08-26 planning
# misses). Complements the substitution blocks (block-raw-asana-api,
# block-raw-gh-writes): those catch improvised REPLACEMENTS for a script,
# this catches the script itself used contract-blind.
#
# Ownership: any execution-position path skills/<name>/scripts/*.sh requires
# <name>'s marker. Shared top-level scripts with one governing skill are
# mapped explicitly below; unmapped shared scripts are exempt (no single
# owner). An invocation whose only arguments are --help or -h is exempt (usage
# text, no step executed). Markers come from mark-skill-read.sh and
# inject-run-context.sh; on the would-block path the transcript is scanned for
# proof the current body is already in context (slash-command delivery,
# post-compaction re-injection, paged Reads), which writes the marker and
# allows (lib/skill-read-gate.sh, skill_read_credit_from_transcript).
#
# A deny (exit 2) cancels the WHOLE Bash command, so the message says so: an
# agent that assumes the rest of a compound command ran loses that work.
#
# Scope: no-ops unless AGENT_TASK_GID is set. Exit 0 allow, exit 2 block.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat 2>/dev/null || true)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Mention-stripped view: a heredoc/echo that merely quotes a script path must
# not fire. Fail-open to raw if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

EXEC_POS='(^|[;&|(]|\$\(|\b(bash|sh|source)[[:space:]]+)[[:space:]]*[^[:space:]]*'
# Arguments up to the next command separator; help-only when nothing but
# --help/-h (plus stderr/stdout redirections) follows the script path.
ARGS_TAIL='[^;&|)]*'
HELP_ONLY='^[[:space:]]*(--help|-h)([[:space:]]+[0-9]*>.*)?[[:space:]]*$'

# invocations <script-regex> : prints each execution-position invocation of
# the script with its argument tail, one per line, skipping help-only ones.
invocations() {
  printf '%s' "$CMD_M" | grep -oE "${EXEC_POS}$1${ARGS_TAIL}" | while IFS= read -r inv; do
    tail=$(printf '%s' "$inv" | sed -E "s#^.*$1##")
    printf '%s' "$tail" | grep -qE "$HELP_ONLY" || printf '%s\n' "$inv"
  done
}

NEEDED=""
# Skill-directory scripts: owner is the directory name.
for sk in $(invocations 'skills/[a-z0-9-]+/scripts/[^[:space:]]+\.sh' | grep -oE 'skills/[a-z0-9-]+/scripts' | sed -E 's|skills/([a-z0-9-]+)/scripts|\1|' | sort -u); do
  NEEDED="$NEEDED $sk"
done
# Shared top-level scripts with one governing skill.
if [ -n "$(invocations 'asana-get-context\.sh([[:space:]]|$)')" ]; then
  NEEDED="$NEEDED task-review"
fi
if [ -n "$(invocations 'lint-commit\.sh([[:space:]]|$)')" ]; then
  NEEDED="$NEEDED im"
fi

[ -n "${NEEDED// /}" ] || exit 0

# Deny-with-body: the mechanism and its rationale live in lib/skill-read-gate.sh,
# shared with the outward-prose gates (lint-md-on-write.sh, slack-prose-gate.sh).
. "$HOME/.config/agent-watcher/hooks/lib/skill-read-gate.sh"
MISSING=$(skill_read_missing $NEEDED)
[ -n "$MISSING" ] || exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
skill_read_credit_from_transcript "$TRANSCRIPT" $MISSING
MISSING=$(skill_read_missing $MISSING)
[ -n "$MISSING" ] || exit 0

{
  echo "BLOCKED: this command was DENIED AS A WHOLE and NOTHING in it ran (every other part of a compound command, heredoc writes included, was cancelled too). It calls a script that is a step of a skill contract not yet in this session's context. Act on the contract below, then re-run the ENTIRE command."
  skill_read_deliver $MISSING
} >&2
exit 2
