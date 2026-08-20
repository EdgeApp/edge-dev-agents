#!/usr/bin/env bash
# slack-prose-gate.sh — PreToolUse(mcp Slack send/draft/schedule/canvas tools).
# LINT-ONLY (operator ruling 2026-08-19): Slack is external comms, so outbound
# text must pass the same shared no-slop-lint every other artifact boundary
# runs (em dashes, banned vocabulary, claude session links, decorative
# loudness). HARD findings deny with the findings so the session fixes and
# re-sends; clean text passes untouched. No send-policy layer: any session may
# still message, only clean text leaves.
#
# BREVITY NUDGE: messages over BRIEF_CHARS get non-blocking additionalContext
# carrying the operator preference — Slack messages are brief by default,
# lengthy only when genuine technical depth requires it.
#
# Not gid-gated: protects interactive sessions too (same reasoning as
# nudge-asana-mcp.sh). Fail-open on any infra error — a lint outage must
# never block team communication.
set -uo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "${TOOL##*__}" in
  slack_send_message|slack_send_message_draft|slack_schedule_message|slack_create_canvas|slack_update_canvas) ;;
  *) exit 0 ;;
esac

# All string values in the tool input, newline-joined. Channel/user ids and
# titles ride along; they are short and lint-clean, so no per-tool schema
# knowledge is needed here.
TEXT=$(printf '%s' "$INPUT" | jq -r '[.tool_input // {} | .. | strings] | join("\n")' 2>/dev/null || true)
[ -n "$TEXT" ] || exit 0

# Trailing Xs required: macOS mktemp treats an embedded-X template
# (name.XXXXXX.md) as a LITERAL filename — concurrent sessions collide.
TMP=$(mktemp /tmp/slack-prose.XXXXXX) || exit 0
printf '%s\n' "$TEXT" > "$TMP"
# --semantic: the haiku judge tier for courtesy enders / forward references
# (calibrated + enabled 2026-08-19). Slack sends are infrequent enough that
# the judge's seconds of latency are acceptable at this boundary.
LINT=$("$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh" "$TMP" --semantic 2>/dev/null); RC=$?
rm -f "$TMP"

if [ "$RC" -eq 1 ]; then
  HARD=$(printf '%s' "$LINT" | grep '^HARD' | head -6)
  jq -nc --arg findings "$HARD" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Slack text fails the shared prose lint (writing-style/no-slop — Slack is external comms). Fix these and re-send:\n" + $findings)
    }
  }'
  exit 0
fi

# NO markdown conversion here (verified 2026-08-19 by live render test): the
# claude.ai Slack connector converts standard markdown server-side (bold,
# links, tables, language-tagged code blocks with highlighting). A pre-pass to
# mrkdwn DOUBLE-converts: *bold* reads as standard-markdown italic and fence
# tags lose highlighting. Sessions write plain GitHub-flavored markdown.
BRIEF_CHARS=900
if [ "${#TEXT}" -gt "$BRIEF_CHARS" ]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: "Operator preference: Slack messages are brief by default; length is earned only by genuine technical depth. If this message can carry its point shorter, trim before sending."
    }
  }'
fi
exit 0
