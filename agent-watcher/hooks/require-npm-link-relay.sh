#!/usr/bin/env bash
# require-npm-link-relay.sh: PreToolUse(Bash). Enforces the two-channel relay
# of pr-land `npm-publish-auth`: before the next npm-auth-wait.sh call, the
# last AUTH_URL that call's logs already returned must appear
#   (a) in an assistant chat text block, outside a code span, in every
#       session (/pr-land also runs by hand, where chat is the only channel);
#   (b) in a PushNotification message as well, in orch runs (AGENT_TASK_GID),
#       where the operator is usually away from the terminal.
# A push alone leaves a terminal operator looking at the last link that was
# written in chat, long expired; chat alone never reaches a phone.
#
# The returned lines come from npm-auth-wait.sh's <log>.relayed counter and
# checksum, so a link minted but not yet returned (including every line of a
# log restarted since the last wait) is never demanded early. A link already
# tapped (AUTH_DONE after it) or a finished log needs nothing.
#
# Escape hatch (orch only, waives (b) alone): /tmp/agent-npm-relay-<gid>.md
# naming why no push channel exists. Audited by /eval-run; an unjustified
# note is a finding.
#
# Fails open: no transcript, no jq, or no relayed state means no block.
# Exit 2 = block (stderr -> model).
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
# Trigger on the mention-stripped view so a command that only quotes the
# script name (a heredoc, an echo) does not fire.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
printf '%s' "$CMD_M" | grep -qE 'npm-auth-wait\.sh([[:space:]]|$)' || exit 0

TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TP="${TP/#\~/$HOME}"
[ -n "$TP" ] && [ -f "$TP" ] || exit 0

# Log args: every *.log word after the script name, globs expanded.
ARGS=$(printf '%s' "$CMD" | sed -E 's/.*npm-auth-wait\.sh//' | tr -d '"'"'")
LOGS=()
for w in $ARGS; do
  w="${w/#\~/$HOME}"
  case "$w" in
    *.log) for f in $w; do [ -f "$f" ] && LOGS+=("$f"); done ;;
  esac
done
[ ${#LOGS[@]} -gt 0 ] || exit 0

MARK='^(AUTH_URL|AUTH_DONE|LOGGED_IN|PUBLISHED|FAILED) '
missing=()
for log in "${LOGS[@]}"; do
  n=""; sum=""; read -r n sum < "$log.relayed" 2>/dev/null || [ -n "$n" ] || continue
  case "$n" in ''|0|*[!0-9]*) continue ;; esac
  # A checksum mismatch means the log restarted after the last wait.
  [ "$(grep -a -E "$MARK" "$log" | head -n "$n" | cksum | awk '{print $1}')" = "$sum" ] || continue
  last=$(grep -a -E "$MARK" "$log" | head -n "$n" | tail -1)
  case "$last" in AUTH_URL\ *) ;; *) continue ;; esac
  url=$(printf '%s' "$last" | awk '{print $3}')
  [ -n "$url" ] || continue

  hits=$(grep -F -- "$url" "$TP" 2>/dev/null)
  in_text=$(printf '%s\n' "$hits" | jq -r --arg u "$url" '
    select(.type == "assistant") | .message.content[]?
    | select(.type == "text") | .text
    | split("`" + $u) | join("") | select(contains($u))' 2>/dev/null | head -c 1)
  [ -n "$in_text" ] || missing+=("chat text: $url")

  if [ -n "${AGENT_TASK_GID:-}" ] && [ ! -s "/tmp/agent-npm-relay-${AGENT_TASK_GID}.md" ]; then
    in_push=$(printf '%s\n' "$hits" | jq -r --arg u "$url" '
      select(.type == "assistant") | .message.content[]?
      | select(.type == "tool_use" and .name == "PushNotification")
      | (.input.message // "") | select(contains($u))' 2>/dev/null | head -c 1)
    [ -n "$in_push" ] || missing+=("PushNotification: $url")
  fi
done
[ ${#missing[@]} -gt 0 ] || exit 0

{
  echo "BLOCKED (pr-land npm-publish-auth): the last npm auth link the wait returned was not relayed yet."
  for m in "${missing[@]}"; do echo "  missing in $m"; done
  echo "Write each url as a bare link in a chat message (not in backticks) and send it in a"
  echo "PushNotification, then re-run the same npm-auth-wait.sh call."
} >&2
exit 2
