#!/usr/bin/env bash
# PreToolUse hook (matchers: Bash, mcp__claude_ai_.*, mcp__plugin_.*, ScheduleWakeup, CronCreate). A Jev routing SHADOW run
# (~/.config/jev/routing/jev-shadow-run.sh) re-does a task's implementation phase on Sonnet
# next to the real run and must leave no trace outside its own tree: no push, no fetch or
# pull (the isolated repo holds only the base commit so the real fix stays unreachable),
# no PR, no GitHub write, no Asana write, no status change, no Slack or mail.
#
# Scope: no-op (exit 0) unless AGENT_SHADOW=1. Exit 2 = block (stderr to the model).
# Bash vectors are matched on the mention-stripped view (strip-cmd-mentions.sh), so a
# heredoc or echo that merely quotes a trigger passes.
set -uo pipefail

[ "${AGENT_SHADOW:-}" = "1" ] || exit 0

IN=$(cat)
TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null || true)

deny() {
  echo "BLOCKED (jev shadow run, block-shadow-writes): $1. This run is a shadow: delivery is out of scope. Keep the work in local commits under ${AGENT_SHADOW_ROOT:-the shadow tree}, record the skipped step in report.md, and continue with the plan." >&2
  exit 2
}

case "$TOOL" in
  ScheduleWakeup|CronCreate)
    # Ending the turn ends a `claude -p` run; a scheduled wake never fires. shadow-continue.sh
    # is the Stop-side half of this.
    deny "$TOOL (this run is one headless turn; wait in-turn with a bounded blocking poll instead)"
    ;;
  mcp__claude_ai_*|mcp__plugin_*)
    # Reads of Asana/Slack/Docs are not needed either; every connector call is out of scope.
    deny "connector tool $TOOL"
    ;;
  Bash)
    CMD=$(printf '%s' "$IN" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    C=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    B='(^|[;&|({`]|\$\(|[[:space:]])'
    E='([[:space:]]|$|[;&|)])'
    if printf '%s' "$C" | grep -qE "${B}git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+(push|fetch|pull|ls-remote)${E}"; then
      deny "git push/fetch/pull"
    fi
    if printf '%s' "$C" | grep -qE "${B}git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+remote[[:space:]]+(add|set-url|rename)${E}"; then
      deny "git remote rewrite"
    fi
    if printf '%s' "$C" | grep -qE "${B}gh[[:space:]]+(pr|issue|release|repo|gist|workflow|run|secret|label)[[:space:]]+(create|merge|comment|review|edit|close|reopen|ready|delete|fork|rerun|cancel|set|upload)${E}"; then
      deny "gh write"
    fi
    if printf '%s' "$C" | grep -qE "${B}gh[[:space:]]+api${E}" \
       && printf '%s' "$C" | grep -qE "(-X|--method)[[:space:]]*(POST|PATCH|PUT|DELETE)|[[:space:]](-f|-F|--field|--raw-field|--input)[[:space:]]|graphql"; then
      deny "gh api write"
    fi
    if printf '%s' "$C" | grep -qE "(pr-create|asana-task-update|asana-task-create|update-status|set-agent-field|set-tested|asana-on-complete-actions|pr-address|github-pr-review|slack-[a-z-]+|pr-land[a-z-]*)\.sh${E}"; then
      deny "delivery script"
    fi
    if printf '%s' "$C" | grep -qE "(api\.asana\.com|app\.asana\.com/api|slack\.com/api|hooks\.slack\.com|api\.github\.com)" \
       && printf '%s' "$C" | grep -qE "${B}(curl|wget|http|node|python3?)${E}"; then
      deny "direct API call to Asana, Slack or GitHub"
    fi
    if printf '%s' "$C" | grep -qE "${B}(npm|yarn)[[:space:]]+publish${E}"; then
      deny "package publish"
    fi
    # Isolation: the run must not find the real run's PR (live: opened while the shadow runs;
    # retro: already merged). Listing and search are how it would be found; PR numbers the
    # launcher hides (AGENT_SHADOW_HIDE_PRS, comma list) are blocked by number.
    if printf '%s' "$C" | grep -qE "${B}gh[[:space:]]+(pr[[:space:]]+(list|status)|search)${E}" \
       || { printf '%s' "$C" | grep -qE "${B}gh[[:space:]]+api${E}" \
            && printf '%s' "$CMD" | grep -qE "(/pulls|/commits|/branches|/compare)([?[:space:]\"']|$)|(^|[[:space:]'\"/])search/"; }; then
      deny "PR or branch discovery (the real run's work must stay unreachable)"
    fi
    for n in $(printf '%s' "${AGENT_SHADOW_HIDE_PRS:-}" | tr ',' ' '); do
      if printf '%s' "$C" | grep -qE "${B}gh${E}.*(^|[^0-9])${n}([^0-9]|$)"; then
        deny "the real run's PR #$n"
      fi
    done
    ;;
esac
exit 0
