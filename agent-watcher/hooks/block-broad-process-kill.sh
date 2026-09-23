#!/usr/bin/env bash
# block-broad-process-kill.sh — PreToolUse(Bash).
# Pattern kills are box-wide on a shared machine. Every orch task claude runs with
# `--mcp-config ~/.config/agent-watcher/maestro-mcp.json`, so full-argv matching hits
# them: on 2026-09-22 (00:40:52Z) a finalizing session's cleanup ran
# `pkill -f 'maestro'` and killed every task claude on eddy (two active runs plus
# five retired panes); the watchdog does not revive, so the work stopped silently.
#
# Rule: kill by explicit PID only. Blocks, in EVERY session (not only AGENT_TASK_GID
# ones: an anchor's broad kill does the same box-wide damage):
#   - any pkill or killall invocation
#   - kill / xargs kill fed by pgrep (pipe, $(...), or backticks)
# pkill's scoping flags (-P/-g/-s/-t) are deliberately NOT an exemption: they narrow
# by an id the caller supplies, and nothing verifies the id is the caller's own.
# Escape hatch: the operator runs a deliberate pattern kill with the `!` prefix,
# which bypasses tool hooks.
set -euo pipefail

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view: heredoc bodies and quoted spans are blanked so a report
# that QUOTES `pkill -f` does not fire. Fail-open to raw.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

REASON=$(CMD_M="$CMD_M" node -e '
const cmd = process.env.CMD_M
const WRAP = new Set(["sudo","command","exec","nohup","time","env","xargs","nice","timeout","gtimeout"])
// Split on separators; $(...) and backtick bodies become their own segments.
const segs = cmd.replace(/\$\(|`|\)/g, ";").split(/\|\||&&|[;&|\n]/).map(s => s.trim()).filter(Boolean)
const prog = seg => {
  const w = seg.split(/\s+/)
  while (w.length && (WRAP.has(w[0]) || /^\d+[smh]?$/.test(w[0]) || /^[A-Za-z_]\w*=\S*$/.test(w[0]))) w.shift()
  return w.length ? w[0].split("/").pop() : ""
}
const progs = segs.map(prog)
for (let i = 0; i < progs.length; i++) {
  if (progs[i] === "pkill" || progs[i] === "killall") { console.log(progs[i] + " kills by name/pattern"); break }
  if (progs[i] === "pgrep" && progs.slice(Math.max(0, i - 1), i + 3).includes("kill")) {
    console.log("kill fed by pgrep kills by name/pattern"); break
  }
}
' 2>/dev/null || true)

# strip-cmd-mentions blanks backticked spans, which hides kill `pgrep x`.
# Check that one form on the raw command.
if [ -z "$REASON" ] && printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])kill[^`]*`[[:space:]]*pgrep[[:space:]]'; then
  REASON="kill fed by pgrep kills by name/pattern"
fi

[ -n "$REASON" ] || exit 0
cat >&2 <<MSG
BLOCKED (block-broad-process-kill): $REASON. Kill by explicit PID only.
This machine runs many sessions at once, and every orch task claude carries
maestro-mcp.json in its argv, so a pattern kill takes down other agents'
sessions, sims, Metro, and the orch daemons.
  1. List candidates:  pgrep -fl '<pattern>'
  2. Kill the specific PIDs you started (Metro on YOUR port, YOUR maestro child):
       kill <pid> [<pid> ...]
Slot resources (Metro, sim, Maestro MCP) are released by the watcher on Complete;
do not tear them down by hand.
MSG
exit 2
