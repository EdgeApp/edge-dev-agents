#!/usr/bin/env bash
# block-piped-watcher-scripts.sh — PreToolUse(Bash).
# The agent-watcher helper scripts (update-status.sh, set-tested.sh, log-attempt.sh,
# release-pool-entry.sh, ...) MUST be called BARE. Wrapping one in a `| tail`/`| head`
# pipeline runs it in a subshell that fails its setgid with
# "failed to change group ID: operation not permitted" (exit 1) on this host, so the
# status write silently does not happen and the agent burns retries. The one-shot rule
# `agent-status-on-pending-task` forbids this in prose; this hook enforces it.
# Enforcement-over-prose: 6 of 9 runs in the 2026-06-20 eval cohort still wrapped the
# call despite the rule.
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# Match: an agent-watcher *.sh helper invocation followed (after any redirections) by a
# pipe into head/tail. `[^|]*` consumes args up to the FIRST pipe so
# `update-status.sh X 2>&1 | tail -2` is caught. Second grep is an exception: when a
# READER (cat/less/sed/awk/grep/rg/bat/view, or a `<` redirect) precedes the watcher
# path, the script is being READ, not executed — leave it alone.
if printf '%s' "$CMD" | grep -qE '\.config/agent-watcher/(hooks/)?[A-Za-z0-9_.-]+\.sh[^|]*\|[[:space:]]*(tail|head)([[:space:]]|$|-)' \
   && ! printf '%s' "$CMD" | grep -qE '(cat|less|head|tail|bat|view|grep|rg|sed|awk)[[:space:]]+[^|]*\.config/agent-watcher/|<[[:space:]]*[^|]*\.config/agent-watcher/'; then
  echo "BLOCKED: do not pipe an agent-watcher helper script through '| tail' or '| head'. The pipe runs it in a subshell that fails setgid ('failed to change group ID: operation not permitted') and exit-1s, so the write does not happen. Call the script BARE and read its stdout/exit code directly (one-shot rule agent-status-on-pending-task)." >&2
  exit 2
fi
exit 0
