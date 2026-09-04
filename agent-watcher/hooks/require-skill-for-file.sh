#!/usr/bin/env bash
# require-skill-for-file.sh -- PreToolUse(Write | Edit | Bash).
# Blocks a write to a file whose NAME has an owning skill until that skill's
# body has entered context, delivering the body in the denial (deny-with-body,
# lib/skill-read-gate.sh) so the retry passes with the contract in view.
#
# One table, every gated file name. Add a row rather than a new hook pair;
# the marker scheme, vectors, and delivery are shared with the script gate
# (require-skill-read-for-scripts.sh) and the prose gate (lint-md-on-write.sh).
#   basename       skill        scope
#   AGENTS.md      agents-md    all   (every session: an AGENTS.md taxes every
#                                      future session of its repo, so an
#                                      interactive careless draft costs as much
#                                      as an orch one)
#   CHANGELOG.md   changelog    orch  (the verbose entries come from agents; an
#                                      operator typing a line by hand should not
#                                      eat a skill body)
#
# Vectors: Write/Edit by file_path; Bash by redirect, tee, sed -i, perl -pi
# (lib/md-write-target.sh). Reads of the file are never blocked.
#
# Key: AGENT_TASK_GID in orch runs; sess-<session_id> for all-scope rows in
# interactive sessions (mark-skill-read.sh writes the same key there). A
# marker lasts the run segment (inject-run-context.sh expires gid markers at
# segment and compaction boundaries) or the interactive session.
#
# No escape hatch: the denial is the remedy, one round trip, so a loop only
# occurs if the agent refuses the body. Exit 0 allow, exit 2 block.
set -uo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in Write|Edit|Bash) ;; *) exit 0 ;; esac

LIB="$HOME/.config/agent-watcher/hooks/lib"
[ -f "$LIB/skill-read-gate.sh" ] && [ -f "$LIB/md-write-target.sh" ] || exit 0
. "$LIB/skill-read-gate.sh"
. "$LIB/md-write-target.sh"

# basename:skill:scope
TABLE="AGENTS.md:agents-md:all
CHANGELOG.md:changelog:orch"

TARGET=""
case "$TOOL" in
  Write|Edit)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    [ -n "$CMD" ] || exit 0
    # Mention-stripped view: a heredoc or echo that merely quotes the file name
    # is not a write to it. Fail-open to the raw command if the helper is gone.
    CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
    while IFS=: read -r base _ _; do
      [ -n "$base" ] || continue
      TARGET=$(bash_write_target "$CMD_M" "$CWD" "$base")
      [ -n "$TARGET" ] && break
    done <<< "$TABLE"
    ;;
esac
[ -n "$TARGET" ] || exit 0

BASE=$(basename "$TARGET")
SKILL="" SCOPE=""
while IFS=: read -r base skill scope; do
  # Case-insensitive on the name so agents.md / Agents.md gate the same.
  if [ "$(printf '%s' "$BASE" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" ]; then
    SKILL="$skill"; SCOPE="$scope"; break
  fi
done <<< "$TABLE"
[ -n "$SKILL" ] || exit 0

if [ -n "${AGENT_TASK_GID:-}" ]; then
  export SKILL_READ_KEY="$AGENT_TASK_GID"
elif [ "$SCOPE" = "all" ]; then
  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  [ -n "$SID" ] || exit 0
  export SKILL_READ_KEY="sess-$SID"
else
  exit 0
fi

[ -n "$(skill_read_missing "$SKILL")" ] || exit 0
{
  echo "BLOCKED: $TARGET is owned by the \`$SKILL\` skill and its contract has not entered this session's context yet. The full skill is below; it now counts as read. Apply it, then retry the write (the retry passes this gate)."
  skill_read_deliver "$SKILL"
} >&2
exit 2
