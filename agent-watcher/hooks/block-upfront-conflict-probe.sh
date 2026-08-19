#!/usr/bin/env bash
# block-upfront-conflict-probe.sh — PreToolUse(Bash).
# Denies ad-hoc PR mergeability probes in agent sessions: any typed gh command
# fetching `mergeable` / `mergeStateStatus`. Operator policy (2026-07-29):
# conflicts are addressed at rebase/landing time by pr-land — they are NOT
# status to discover, narrate, or fix upfront. The swapter run probed
# mergeability after a fixup push, saw CONFLICTING, and rebased mid-review to
# "restore mergeability" nobody needed yet; the narration then leaked into
# comments and reports. Killing the probe kills the noise at its source.
#
# pr-land's own scripts (pr-merge-watch, pr-land-automerge, pr-land-merge) read
# these fields INSIDE the script, so their typed commands never match here —
# landing-time checks are untouched.
#
# Scope: no-op unless AGENT_TASK_GID is set. Exit 2 = block (stderr -> model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

case "$CMD_M" in
  *gh\ *) ;;
  *) exit 0 ;;
esac
printf '%s' "$CMD_M" | grep -qE 'mergeable|mergeStateStatus' || exit 0

cat >&2 <<'MSG'
BLOCKED: upfront PR-mergeability probe. Conflicts are a LANDING-TIME concern,
resolved at rebase/land by /pr-land (its scripts read merge state themselves).
Do not fetch, report, or fix conflict status before then — no CONFLICTING
narration in chat, comments, or reports, and no mid-review rebase to "restore
mergeability" nobody needs yet. If you are landing right now, use the pr-land
scripts (pr-land-automerge.sh / pr-merge-watch.sh); they own this check.
MSG
exit 2
