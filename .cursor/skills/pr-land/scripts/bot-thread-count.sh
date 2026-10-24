#!/usr/bin/env bash
# bot-thread-count.sh: sourced, not run. The one count of unresolved
# reviewer-bot threads on a PR (pr-land `bot-thread-gate`), shared by
# pr-land-automerge.sh (the arming gate) and pr-merge-watch.sh (the re-check on
# every poll while auto-merge is armed, which catches a thread a bot posts
# after arming).
#
#   bot_thread_count <pr_json>
#     pr_json: {"repo": "<owner/repo or repo>", "prNumber": <n>, "branch": "<optional>"}
#     Prints the number of unresolved threads whose first comment is
#     bot-authored, per pr-land-comments.sh. Prints "?" when the comment check
#     cannot run or its output does not parse; each caller decides what "?"
#     means (the arming gate refuses to arm, the watch logs it and keeps polling).
#
# COMMENTS_SH overrides the comment checker (tests stub it).

COMMENTS_SH="${COMMENTS_SH:-$HOME/.cursor/skills/pr-land/scripts/pr-land-comments.sh}"

bot_thread_count() {
  local pr_json="$1" out
  out=$(jq -c '[{repo:.repo, prNumber:.prNumber, branch:(.branch // "")}]' <<<"$pr_json" \
        | "$COMMENTS_SH" 2>/dev/null) || { echo "?"; return; }
  jq -r '[ .[] | (.botThreads // []) | length ] | add // 0' <<<"${out:-[]}" 2>/dev/null || echo "?"
}
