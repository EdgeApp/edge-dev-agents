#!/usr/bin/env bash
set -uo pipefail

# npm-auth-wait.sh: the foreground wait on npm-publish-web.sh logs. Returns
# within one poll (3s) of every new relay line, so a reminted link reaches the
# operator while it is still live.
#
# Why foreground and event-terminated (owned by pr-land `npm-publish-auth`):
#   - A Monitor's events are held until the running foreground tool returns,
#     so a Monitor paired with a long blocking poll relays one poll late.
#   - A poll that ends on its own clock instead of on the event relays up to
#     a whole poll late; the links live about 5 minutes and remint every 4.
#   - A background watch leaves nothing holding the turn open, and the orch
#     stop hook forbids ending a turn on a backgrounded wait.
#
# Usage: npm-auth-wait.sh [--cap <secs>] <log> [<log>...]
#
# State: <log>.relayed holds how many relay lines of that log were already
# returned plus a checksum of them, so each call prints only what is new, in
# log order. A log restarted with > (a new run, or a restarted login) no
# longer matches the checksum and is read from its first line again. require-npm-link-relay.sh
# reads the same file: it blocks the next call until the last AUTH_URL this
# script returned appears in the assistant's chat text.
#
# Output:
#   NEW <log> <line>        each new relay line, in log order
#   RELAY <log> <url> minted <time>
#                           the newest link of every log still waiting
#   DONE <log> <line>       a log that finished (LOGGED_IN, PUBLISHED, FAILED)
#   WAITING ...             cap reached with nothing new
#
# Exit: 0 = new lines, 3 = every log finished, 4 = cap reached with nothing
# new (re-run it), 1 = usage.

CAP=110
LOGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cap) CAP="${2:-}"; shift 2 ;;
    -h|--help) sed -n '4,32p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) LOGS+=("$1"); shift ;;
  esac
done
[ ${#LOGS[@]} -gt 0 ] || { echo "usage: npm-auth-wait.sh [--cap <secs>] <log> [<log>...]" >&2; exit 1; }
case "$CAP" in ''|*[!0-9]*) echo "--cap takes whole seconds" >&2; exit 1 ;; esac

MARK='^(AUTH_URL|AUTH_DONE|LOGGED_IN|PUBLISHED|FAILED) '
FINAL='^(LOGGED_IN|PUBLISHED|FAILED) '

marks() { grep -a -E "$MARK" "$1" 2>/dev/null; }
sum_of() { marks "$1" | head -n "$2" | cksum | awk '{print $1}'; }
relayed() {
  local n sum
  read -r n sum < "$1.relayed" 2>/dev/null || [ -n "$n" ] || { echo 0; return; }
  case "$n" in ''|*[!0-9]*) echo 0; return ;; esac
  [ "$(sum_of "$1" "$n")" = "$sum" ] && echo "$n" || echo 0
}
finished() { grep -a -q -E "$FINAL" "$1" 2>/dev/null; }

# The newest link of a log still waiting, with the mint time the publish
# script prints to stderr right after it (both land in the log via 2>&1).
relay_line() {
  local log="$1" url minted
  url=$(grep -a -E '^AUTH_URL ' "$log" 2>/dev/null | tail -1 | awk '{print $3}')
  [ -n "$url" ] || return 0
  # An AUTH_DONE after the newest link means it was already tapped.
  grep -a -E '^(AUTH_URL|AUTH_DONE) ' "$log" | tail -1 | grep -q '^AUTH_DONE ' && return 0
  minted=$(grep -a -o 'link minted [0-9:]*Z' "$log" | tail -1 | awk '{print $3}')
  echo "RELAY $log $url minted ${minted:-unknown}"
}

all_finished() {
  local log
  for log in "${LOGS[@]}"; do finished "$log" || return 1; done
  return 0
}

end=$((SECONDS + CAP))
while :; do
  new=0
  for log in "${LOGS[@]}"; do
    have=$(relayed "$log")
    total=$(marks "$log" | wc -l | tr -d ' ')
    if [ "$total" -gt "$have" ]; then
      marks "$log" | tail -n +"$((have + 1))" | sed "s|^|NEW $log |"
      echo "$total $(sum_of "$log" "$total")" > "$log.relayed"
      new=1
    fi
  done
  if [ "$new" = 1 ] || all_finished; then
    relays=""
    for log in "${LOGS[@]}"; do
      if finished "$log"; then
        echo "DONE $log $(grep -a -E "$FINAL" "$log" | tail -1)"
      else
        relays+="$(relay_line "$log")"$'\n'
      fi
    done
    relays=$(printf '%s' "$relays" | grep -v '^$')
    [ -n "$relays" ] && echo "$relays"
    all_finished && exit 3
    if [ -n "$relays" ]; then
      echo "Put every RELAY url as a bare link in your chat message AND in one PushNotification, then re-run this wait."
    else
      echo "No link is waiting. Relay each NEW AUTH_DONE as a status line in chat and a push, then re-run this wait."
    fi
    exit 0
  fi
  if [ "$SECONDS" -ge "$end" ]; then
    echo "WAITING ${CAP}s with nothing new; the links already relayed are still the newest. Re-run this wait."
    exit 4
  fi
  sleep 3
done
