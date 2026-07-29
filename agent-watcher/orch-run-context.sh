#!/usr/bin/env bash
# orch-run-context.sh — is this process running inside an IN-FLIGHT orch run?
#
# Exit 0 = orch-run context: an autonomous run is driving this session and its
#          Asana prose is agent output (gets the 🥋/👊 authorship markers).
# Exit 1 = operator context: whatever this session writes to Asana, it writes on
#          the operator's behalf (operator instruction; must stay unmarked so a
#          later orch run reads it as scope).
#
# The test is BOTH of:
#   1. AGENT_TASK_GID is set (exported only by orch spawns/resumes).
#   2. The pane's CURRENT tmux session name is exactly claude-asana-$AGENT_TASK_GID.
#
# Why the env var alone is not enough: the watchdog's completion sweep renames
# claude-asana-<gid> -> done-asana-<gid> at completion but leaves claude alive
# for the operator to talk to, and that process keeps AGENT_TASK_GID forever.
# The rename is therefore the completion litmus: an exact-name match means the
# run is still in flight; a retired session, a chat fork (claude-asana-chat-*),
# an always-on console (claude-asana-main, -eval-run), and any non-tmux process
# all fail the match and are operator context.
#
# The pane id ($TMUX_PANE) is stable across renames and display-message reports
# the CURRENT session name, so the answer flips the moment the watchdog retires
# the session. Known boundary: between the run setting agent_status=Complete and
# the watchdog's rename (one tick, <=120s), operator interjections still count
# as orch context.
#
# Consumers: hooks/mark-agent-authored-asana.sh (MCP write path) and
# agent-authored-text.sh (script write path). Behavior gates that constrain
# agent TOOL conduct (block-*, require-*) intentionally do NOT use this — a
# retired session doing work is still an agent doing work; this predicate is
# about text AUTHORSHIP only.
set -uo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 1
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 1

NAME=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
[ "$NAME" = "claude-asana-$AGENT_TASK_GID" ] || exit 1
exit 0
