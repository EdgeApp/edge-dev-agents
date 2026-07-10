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
  # REWRITE, don't block: the block costs a full bounce and this was the single most
  # recurrent finding of the 2026-07-09 combined eval (11 fires in one run). Strip the
  # `| tail/head …` segment (watcher script stdout is small; the truncation was
  # pointless) and let the corrected command run, telling the model what changed.
  #
  # SAFETY CARVE-OUT: never rewrite a command carrying a gated concession shape
  # (--blocked / Complete / pr-create). Rewriting implies permissionDecision:allow,
  # which could short-circuit require-concession-validation on the same command —
  # those keep the old hard block so the retry is evaluated by every gate.
  if printf '%s' "$CMD" | grep -qE -- '--blocked|Complete|pr-create'; then
    echo "BLOCKED: do not pipe an agent-watcher helper script through '| tail' or '| head'. The pipe runs it in a subshell that fails setgid ('failed to change group ID: operation not permitted') and exit-1s, so the write does not happen. Call the script BARE and read its stdout/exit code directly (one-shot rule agent-status-on-pending-task)." >&2
    exit 2
  fi
  REWRITTEN=$(printf '%s' "$CMD" | sed -E 's/\|[[:space:]]*(tail|head)([[:space:]]+-[A-Za-z0-9]+)*([[:space:]]+[0-9]+)?[[:space:]]*($|\&\&|;)/\4/')
  if [ -n "$REWRITTEN" ] && [ "$REWRITTEN" != "$CMD" ] \
     && ! printf '%s' "$REWRITTEN" | grep -qE '\.config/agent-watcher/(hooks/)?[A-Za-z0-9_.-]+\.sh[^|]*\|'; then
    jq -nc --arg cmd "$REWRITTEN" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: "auto-rewrote piped agent-watcher call to bare (pipe breaks setgid on this host)",
        updatedInput: { command: $cmd }
      },
      systemMessage: "Rewrote piped agent-watcher call to bare: piping these scripts through tail/head breaks their setgid and the write silently fails. The full stdout is returned instead of the truncated tail."
    }'
    exit 0
  fi
  # Rewrite did not cleanly apply (complex pipeline) — fall back to the block.
  echo "BLOCKED: do not pipe an agent-watcher helper script through '| tail' or '| head'. The pipe runs it in a subshell that fails setgid ('failed to change group ID: operation not permitted') and exit-1s, so the write does not happen. Call the script BARE and read its stdout/exit code directly (one-shot rule agent-status-on-pending-task)." >&2
  exit 2
fi
exit 0
