#!/usr/bin/env bash
# require-npm-link-relay.sh: PreToolUse(Bash) and Stop. Enforces pr-land
# `npm-publish-auth`: every npm auth link reaches the operator, the reminted
# ones included.
#
# PreToolUse(Bash). Before the next npm-auth-wait.sh call, the last AUTH_URL
# that call's logs already returned must appear
#   (a) in an assistant chat text block, outside a code span, in every
#       session (/pr-land also runs by hand, where chat is the only channel);
#   (b) in a PushNotification message as well, in orch runs (AGENT_TASK_GID),
#       where the operator is usually away from the terminal.
# A push alone leaves a terminal operator looking at the last link that was
# written in chat, long expired; chat alone never reaches a phone. The
# transcript is read as it stands, so text written earlier in the same turn
# counts. A link found only in a thinking block is called out as such: the
# operator cannot see thinking, and a model that wrote it there believes it
# already relayed.
#
# The returned lines come from npm-auth-wait.sh's <log>.relayed counter and
# checksum, so a link minted but not yet returned (including every line of a
# log restarted since the last wait) is never demanded early. A link already
# tapped (AUTH_DONE after it) or a finished log needs nothing.
#
# Stop. npm-publish-web.sh mints a fresh link about every 4 minutes until the
# operator taps one. With no wait running, a reminted link reaches nobody, so a
# turn may not end while a publish this session is waiting on is still going:
# the stop is blocked (decision:block) when a log this session's waits returned
# lines for has no LOGGED_IN / PUBLISHED / FAILED line and a process still
# holds it open. Bounded at STOP_BLOCK_MAX blocks per session, then the stop is
# allowed, so a session that cannot comply is never trapped. Stands down under
# an operator hold or a usage pause, like require-continuation-or-block.sh.
#
# Which logs: the command's *.log arguments when they resolve to files;
# otherwise (and always at Stop) the absolute paths npm-auth-wait.sh printed in
# this session's own tool results, so a call that passes its logs through a
# shell variable is still covered.
#
# Escape hatch (orch only, waives (b) alone): /tmp/agent-npm-relay-<gid>.md
# naming why no push channel exists. Audited by /eval-run; an unjustified
# note is a finding.
#
# Fails open: no transcript, no jq, or no relayed state means no block.
# PreToolUse: exit 2 = block (stderr -> model). Stop: JSON on stdout.
set -uo pipefail

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null) || exit 0
TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TP="${TP/#\~/$HOME}"

MARK='^(AUTH_URL|AUTH_DONE|LOGGED_IN|PUBLISHED|FAILED) '
FINAL='^(LOGGED_IN|PUBLISHED|FAILED) '
WAIT_SCRIPT='~/.cursor/skills/pr-land/scripts/npm-auth-wait.sh'

# The logs this session's npm-auth-wait.sh calls returned lines for, read from
# the tool results of those calls (the wait prints absolute paths).
session_logs() {
  grep -a -E 'npm-auth-wait\.sh|(NEW|RELAY|DONE) /' "$TP" 2>/dev/null | jq -r -s '
    ([.[] | select(.type == "assistant") | .message.content | arrays | .[]
      | select(.type == "tool_use" and .name == "Bash")
      | select((.input.command // "") | test("npm-auth-wait\\.sh(\\s|$)"))
      | .id]) as $ids
    | .[] | select(.type == "user") | .message.content | arrays | .[]
    | select(.type == "tool_result") | select(.tool_use_id as $i | any($ids[]; . == $i))
    | (.content | if type == "array" then map(.text? // "") | join("\n") else tostring end)
    | split("\n")[] | (capture("^(NEW|RELAY|DONE) (?<log>/\\S+\\.log) ")? | .log)' 2>/dev/null | sort -u
}

# ----------------------------------------------------------------- Stop ----
if [ "$EVENT" = "Stop" ]; then
  [ -n "$TP" ] && [ -f "$TP" ] || exit 0
  GID="${AGENT_TASK_GID:-}"
  if [ -n "$GID" ] && "$HOME/.config/agent-watcher/operator-hold.sh" status "$GID" >/dev/null 2>&1; then
    exit 0
  fi
  [ -f "${AGENT_USAGE_PAUSE_STAMP:-/tmp/agent-usage-pause.json}" ] && exit 0
  # Nearly every stop ends here: the session never ran the wait.
  grep -a -q 'npm-auth-wait\.sh' "$TP" 2>/dev/null || exit 0

  SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  COUNT_FILE="/tmp/agent-npm-wait-stop-${SID:-nosid}"
  STOP_BLOCK_MAX=3

  pending=""
  while IFS= read -r log; do
    [ -n "$log" ] && [ -f "$log" ] || continue
    grep -a -q -E "$FINAL" "$log" 2>/dev/null && continue
    # Still being written: the publish script and its children hold the log
    # open as stdout. Nothing holding it means the script is gone and the log
    # will never finish, so there is nothing left to wait for.
    [ -n "$(lsof -t -- "$log" 2>/dev/null | head -1)" ] || continue
    pending="$pending $log"
  done < <(session_logs)
  if [ -z "$pending" ]; then rm -f "$COUNT_FILE" 2>/dev/null; exit 0; fi

  N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  case "$N" in ''|*[!0-9]*) N=0 ;; esac
  N=$((N + 1))
  if [ "$N" -gt "$STOP_BLOCK_MAX" ]; then rm -f "$COUNT_FILE" 2>/dev/null; exit 0; fi
  printf '%s' "$N" > "$COUNT_FILE" 2>/dev/null || true

  REASON="An npm login or publish you started is still running and has not finished:${pending}. Its link is reminted about every 4 minutes, and a reminted link reaches the operator only while the wait is running, so do not end the turn here. Run this now and repeat it after every relay until it exits 3: ${WAIT_SCRIPT}${pending} . Nothing about the relay needs the turn to end: the relay hook reads chat text as soon as it is written, in the same turn. If the publish is being abandoned on purpose, kill its npm-publish-web.sh process first. (stop ${N}/${STOP_BLOCK_MAX})"
  jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
  exit 0
fi

# ----------------------------------------------------------- PreToolUse ----
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
# Trigger on the mention-stripped view so a command that only quotes the
# script name (a heredoc, an echo) does not fire.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
printf '%s' "$CMD_M" | grep -qE 'npm-auth-wait\.sh([[:space:]]|$)' || exit 0

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
if [ ${#LOGS[@]} -eq 0 ]; then
  while IFS= read -r f; do [ -n "$f" ] && [ -f "$f" ] && LOGS+=("$f"); done < <(session_logs)
fi
[ ${#LOGS[@]} -gt 0 ] || exit 0

missing=()
in_thinking=""
for log in "${LOGS[@]}"; do
  [ -f "$log.relayed" ] || continue
  n=""; sum=""; read -r n sum < "$log.relayed" || [ -n "$n" ] || continue
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
  if [ -z "$in_text" ]; then
    missing+=("chat text: $url")
    [ -n "$(printf '%s\n' "$hits" | jq -r --arg u "$url" '
      select(.type == "assistant") | .message.content[]?
      | select(.type == "thinking") | (.thinking // "") | select(contains($u))' 2>/dev/null | head -c 1)" ] && in_thinking=1
  fi

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
  if [ -n "$in_thinking" ]; then
    echo "You wrote a link inside a thinking block. The operator cannot see thinking: write it in"
    echo "your visible reply text."
  fi
  echo "Write each url as a bare link in a chat message (not in backticks) and send it in a"
  echo "PushNotification, then re-run the same npm-auth-wait.sh call in this turn. Chat text counts"
  echo "as soon as it is written, so do not end the turn to make it land: ending the turn stops"
  echo "the wait, and reminted links then reach nobody."
} >&2
exit 2
