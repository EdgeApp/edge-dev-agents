#!/usr/bin/env bash
# require-agents-md-skill.sh — PreToolUse(Write | Edit | Bash).
# Blocks any write to an AGENTS.md, in ANY repo, until the `agents-md` skill has
# been loaded THIS session, evidenced by the marker mark-agents-md-skill-read.sh
# (PostToolUse) writes.
#
# Covers every authoring vector, not just the obvious one: Write/Edit by
# file_path, and Bash by redirect/tee/heredoc into the file (a `cat > AGENTS.md`
# authors exactly what Write does). Bash READS of the file stay unblocked.
#
# The hook's ONLY job is to guarantee the skill; all guidance on what makes a
# good AGENTS.md lives in ~/.cursor/skills/agents-md/SKILL.md, cached there and
# never fetched at use time. Keep this script free of that content so the two
# cannot drift apart.
#
# Why gate at all: an AGENTS.md is loaded into EVERY session for its repo, so a
# careless one taxes every future task there and fails silently rather than
# loudly. The confident first draft — a directory listing, pasted code, and
# style rules a linter already enforces — measurably performs WORSE than having
# no file.
#
# Session-keyed, not task-keyed: this covers interactive edits in any checkout,
# not just orchestrated runs, so it must NOT require AGENT_TASK_GID.
#
# Not one-bounce: blocks until the marker exists. The remedy is one Skill call
# (or one Read), which then passes every later AGENTS.md write in the session,
# so a loop only occurs if the agent refuses to load the skill.
set -euo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
IS_WRITE=0
case "$TOOL" in
  Write | Edit)
    FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    # Any path, any repo — only the file name decides.
    case "$(basename "${FP:-}")" in
      AGENTS.md | agents.md | Agents.md) IS_WRITE=1 ;;
    esac
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    # Redirect (`> AGENTS.md`, `>> …`), tee, or heredoc target. Reads such as
    # `cat AGENTS.md` / `grep x AGENTS.md` carry no such operator and pass.
    if printf '%s' "$CMD_M" | grep -qiE '(>>?[[:space:]]*|tee([[:space:]]+-a)?[[:space:]]+)[^[:space:]|;&]*AGENTS\.md'; then
      IS_WRITE=1
    fi
    ;;
esac
[ "$IS_WRITE" = 1 ] || exit 0

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$SESSION" ] || SESSION="${AGENT_TASK_GID:-default}"
MARKER="/tmp/agent-agents-md-skill-$SESSION"
[ -f "$MARKER" ] && exit 0

cat >&2 <<'MSG'
BLOCKED: no AGENTS.md write before the `agents-md` skill is loaded this session.
Load it now (one call unblocks every later AGENTS.md write in this session):
  Skill tool -> skill: "agents-md"
It carries the size budget, the include/exclude lists, and the checklist this
file has to satisfy. An AGENTS.md enters EVERY session for its repo, so writing
one from instinct is how a repo acquires a permanent context tax.
MSG
exit 2
