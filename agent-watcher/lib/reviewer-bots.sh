#!/usr/bin/env bash
# reviewer-bots.sh: the ONE definition of the automated PR reviewers and of
# "did this reviewer review this head". Sourced by watch-pr.sh (the watch and
# the outage waiver it writes), check-followup-scope.sh (the Complete gate's
# and the completion judge's bot count), and pr-land's arming and sweep
# scripts. Before this lib each kept its own name list and its own reading of
# a check-run, and they disagreed on the same head: a 4-second `neutral` from
# the security reviewer read as "skipped" to the watch and "incomplete" to the
# gate.
#
# Check-run names: REVIEWER_CHECK_PATTERN, `|`-separated name PREFIXES matched
# with startswith (env override for tests). Review login: REVIEWER_BOT_LOGIN.
# GraphQL strips the `[bot]` suffix, so both Cursor reviewers post reviews as
# plain `cursor`; a review on the head says "one of them reviewed", never which.
#
# Verdict per reviewer, from its latest check-run on the head:
#   pending      queued / in progress: wait for it
#   clean        concluded success
#   findings     concluded failure, OR neutral with a reviewer review on the
#                head (Bugbot concludes neutral when it posts findings; the
#                threads are gated separately)
#   unavailable  no check-run, or skipped / cancelled / neutral with nothing
#                posted: quota, credit, disabled, or down
# A review on the head clears EVERY non-concluded reviewer only when none of
# them has a usable check-run (the outage where check-runs never post but the
# review does). When one reviewer concluded, the shared login cannot vouch for
# the other, so the other's absence stands.
#
# Functions:
#   reviewer_pattern                    the `|`-joined prefixes
#   reviewer_checks_rest <o/r> <sha>    normalized [{name,state}] from REST
#   reviewer_reviewed_head <o/r> <pr>   exit 0 when a reviewer review sits on the PR's head
#   reviewer_bot_verdicts <o/r> <pr> <checks_json>
#       checks_json: [{name, state}] where state is a check-run conclusion or
#       status in any case (gh pr checks --json name,state gives this shape);
#       a row with only gh's `bucket` is read through it (skipping = skipped).
#       Prints [{bot, verdict, detail}], one row per reviewer prefix. detail
#       is "no check-run" or "check-run <conclusion>"; waiver lines are written
#       as "<bot>(<detail>)", which check-followup-scope.sh matches by "<bot>(".

REVIEWER_CHECK_PATTERN="${REVIEWER_CHECK_PATTERN:-Cursor Bugbot|Cursor Security}"
REVIEWER_BOT_LOGIN="${REVIEWER_BOT_LOGIN:-cursor}"

reviewer_pattern() { printf '%s\n' "$REVIEWER_CHECK_PATTERN"; }

reviewer_checks_rest() {
  gh api "repos/$1/commits/$2/check-runs" --paginate \
    --jq '[.check_runs[] | {name, started_at, state: (if .status == "completed" then (.conclusion // "") else .status end)}]' 2>/dev/null \
    | jq -s -c 'add // [] | sort_by(.started_at // "") | map({name, state})' 2>/dev/null || echo "[]"
}

reviewer_reviewed_head() {
  local count
  count=$(gh api graphql -f query="{repository(owner:\"${1%%/*}\",name:\"${1##*/}\"){pullRequest(number:$2){headRefOid reviews(last:50){nodes{author{login} commit{oid}}}}}}" \
    --jq ".data.repository.pullRequest | .headRefOid as \$h | [.reviews.nodes[] | select(.author.login == \"$REVIEWER_BOT_LOGIN\") | select(.commit.oid == \$h)] | length" \
    2>/dev/null || echo 0)
  [ "${count:-0}" -gt 0 ] 2>/dev/null
}

reviewer_bot_verdicts() {
  local slug="$1" pr="$2" checks="${3:-[]}" first reviewed=false
  # First pass without the review probe; it costs a GraphQL call, so it runs
  # only when some reviewer has no concluded check-run.
  first=$(jq -c --arg p "$REVIEWER_CHECK_PATTERN" '
    . as $c
    | [ ($p | split("|"))[] as $n
        | ([ $c[] | select(.name | startswith($n)) ] | last) as $run
        | (($run.state // "") | ascii_downcase
           | if . != "" then . else ({pass: "success", fail: "failure", skipping: "skipped", cancel: "cancelled"}[$run.bucket // ""] // "pending") end) as $s
        | { bot: $n,
            s: $s,
            seen: ($run != null),
            detail: (if $run == null then "no check-run" else "check-run \($s)" end),
            verdict: (if $run == null then "unusable"
                      elif $s == "success" then "clean"
                      elif ($s | test("^(failure|timed_out|action_required|error|startup_failure)$")) then "findings"
                      elif ($s | test("^(neutral|skipped|cancelled|stale)$")) then "unusable"
                      else "pending" end) } ]' <<<"$checks" 2>/dev/null || echo "[]")
  if jq -e 'any(.[]; .verdict == "unusable")' <<<"$first" >/dev/null 2>&1; then
    reviewer_reviewed_head "$slug" "$pr" && reviewed=true
  fi
  jq -c --argjson r "$reviewed" '
    (all(.[]; .verdict == "unusable" or .verdict == "pending")) as $none_concluded
    | map(if .verdict != "unusable" then .
          elif $r and .s == "neutral" then .verdict = "findings"
          elif $r and $none_concluded then .verdict = "findings"
          else .verdict = "unavailable" end
          | {bot, verdict, detail})' <<<"$first"
}
