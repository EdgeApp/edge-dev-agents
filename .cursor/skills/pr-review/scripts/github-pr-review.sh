#!/usr/bin/env bash
# github-pr-review.sh — Fetch PR review context and submit reviews via gh CLI.
#
# Subcommands:
#   context  [--pr <number>] [--owner <o>] [--repo <r>]   Fetch PR metadata + files + existing reviews,
#            review threads (resolved/outdated state), your standing verdict, and your pending draft
#   submit   --pr <n> --owner <o> --repo <r> --sha <sha>  Post review (JSON on stdin; exits 1
#            without calling GitHub if stdin is empty, not one JSON object, has an event
#            other than COMMENT/REQUEST_CHANGES/APPROVE, has malformed comments or replies,
#            anchors an inline comment outside the PR diff, sends a verdict on your own PR, or
#            APPROVEs over your own open REQUEST_CHANGES threads). --check-only runs every
#            check, prose lint included, prints what would happen to a pending draft, and exits
#            0 without posting.
#
# Review JSON: { event, body, comments: [{path, line, body, start_line?, side?, start_side?}],
#                replies: [{thread_id, body, resolve?}] }
# `replies` answer existing review threads (thread node ids from context `threads[]`) inside
# the same review; `resolve: true` resolves the thread after the review posts.
#
# Pending drafts: GitHub allows one PENDING review per user per PR and answers a second review
# with a bare HTTP 422. Submit never deletes a draft that holds content. A draft pinned to the
# PR head is ADOPTED (the payload's comments and replies are added to it and it is submitted
# with the payload's event, the draft's own body first). A draft pinned to an older commit is
# published as its own COMMENT review first, since threads added to it would anchor against
# that commit's diff. An empty draft (no comments, no body) is deleted.
#
# Verdict guard: GitHub treats your latest APPROVED/CHANGES_REQUESTED/DISMISSED review as your
# standing verdict, so an APPROVE silently clears an earlier REQUEST_CHANGES. While your
# standing verdict is CHANGES_REQUESTED, APPROVE is refused until every unresolved thread rooted
# in those reviews is resolved or carried in `replies` with `resolve: true`.
#
# The `context` subcommand auto-detects the PR from the current branch if --pr is omitted.
#
# Exit codes: 0 = success, 1 = error, 2 = needs user input (e.g. gh not authenticated)
set -euo pipefail

CMD="${1:-}"
shift || true

OWNER="" REPO="" PR="" SHA="" CHECK_ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

require_gh() {
  if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI not installed." >&2
    exit 1
  fi
  if ! gh auth status &>/dev/null 2>&1; then
    echo "PROMPT_GH_AUTH" >&2
    exit 2
  fi
}

# Your standing verdict from the REST reviews list (input: array of reviews).
# blockingReviewIds are your CHANGES_REQUESTED reviews since your last
# APPROVED or DISMISSED one; empty unless the standing state is CHANGES_REQUESTED.
STANDING_JQ='
  def standing($me):
    [ .[] | select(.user.login == $me and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")) ]
    | sort_by(.submitted_at) as $v
    | ($v | last | .state // "NONE") as $state
    | ($v | map(.state != "CHANGES_REQUESTED") | indices(true) | last) as $cut
    | { state: $state,
        blockingReviewIds: (if $state == "CHANGES_REQUESTED" then ($v[(if $cut == null then 0 else $cut + 1 end):] | map(.id)) else [] end) };'

# Review threads trimmed to what dedupe, replies, and the verdict guard need.
THREADS_JQ='
  def shape_threads:
    map({ id, isResolved, isOutdated, path, line: (.line // .originalLine),
          comments: .comments.totalCount,
          rootAuthor: .comments.nodes[0].author.login,
          rootReviewId: .comments.nodes[0].pullRequestReview.databaseId,
          rootBody: ((.comments.nodes[0].body // "") | .[0:200]) });'

fetch_threads() { # owner repo number -> JSON array of raw thread nodes on stdout
  gh api graphql --paginate -F owner="$1" -F name="$2" -F number="$3" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id isResolved isOutdated path line originalLine
            comments(first: 1) { totalCount nodes { author { login } body pullRequestReview { databaseId } } } }
        } } } }' --jq '.data.repository.pullRequest.reviewThreads.nodes[]' | jq -s '.'
}

graphql_input() { # request JSON {query, variables} on stdin -> response on stdout, exit 1 on errors
  local out
  out=$(gh api graphql --input - 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  if [[ "$(printf '%s' "$out" | jq '(.errors // []) | length')" -gt 0 ]]; then
    printf '%s' "$out" | jq -r '.errors[].message' >&2
    return 1
  fi
  printf '%s' "$out"
}

case "$CMD" in
  context)
    require_gh

    # --- Call 1: PR metadata + reviews via gh pr view ---
    VIEW_ARGS=()
    [[ -n "$PR" ]] && VIEW_ARGS+=("$PR")
    [[ -n "$OWNER" && -n "$REPO" ]] && VIEW_ARGS+=("--repo" "$OWNER/$REPO")

    META=$(gh pr view ${VIEW_ARGS[@]+"${VIEW_ARGS[@]}"} \
      --json number,title,url,author,headRefName,headRefOid,baseRefName 2>&1) || {
      echo "Error: Failed to fetch PR. Output: $META" >&2
      exit 1
    }

    # Parse owner/repo/number from the PR URL
    NUMBER=$(echo "$META" | jq -r '.number')
    URL=$(echo "$META" | jq -r '.url')
    _OWNER=$(echo "$URL" | cut -d/ -f4)
    _REPO=$(echo "$URL" | cut -d/ -f5)

    # --- Call 2: Changed files with patches (REST — GraphQL doesn't expose patches) ---
    # Payloads go through temp files, not argv: a large PR's patches exceed
    # ARG_MAX as a --argjson value, and --paginate emits one array per page.
    WORK=$(mktemp -d /tmp/pr-review-ctx.XXXXXX)
    trap 'rm -rf "$WORK"' EXIT
    printf '%s' "$META" > "$WORK/meta.json"
    gh api "repos/$_OWNER/$_REPO/pulls/$NUMBER/files" --paginate > "$WORK/files.json" 2>"$WORK/files.err" || {
      echo "Error: Failed to fetch PR files. Output: $(cat "$WORK/files.err")" >&2
      exit 1
    }

    # --- Call 3: Inline review comments (REST) — resolved threads included, so
    # no-duplicate-feedback can be checked against EVERYTHING already raised,
    # not just unresolved threads. Trimmed to the fields duplicate-checking
    # needs; body capped to keep context cost bounded.
    gh api "repos/$_OWNER/$_REPO/pulls/$NUMBER/comments" --paginate > "$WORK/inline.json" 2>"$WORK/inline.err" || {
      echo "Error: Failed to fetch PR inline comments. Output: $(cat "$WORK/inline.err")" >&2
      exit 1
    }

    # --- Calls 4-6: every review (REST carries commit_id and the viewer's own
    # PENDING draft), review threads with resolved/outdated state (GraphQL
    # only), and the viewer login for standing-verdict and draft lookup.
    ME=$(gh api user --jq .login)
    gh api "repos/$_OWNER/$_REPO/pulls/$NUMBER/reviews" --paginate | jq -s 'add // []' > "$WORK/reviews.json"
    fetch_threads "$_OWNER" "$_REPO" "$NUMBER" > "$WORK/threads.json"
    PENDING_ID=$(jq -r --arg me "$ME" '[.[] | select(.state == "PENDING" and .user.login == $me)][0].id // empty' "$WORK/reviews.json")
    if [[ -n "$PENDING_ID" ]]; then
      gh api "repos/$_OWNER/$_REPO/pulls/$NUMBER/reviews/$PENDING_ID/comments" --paginate | jq -s 'add // []' > "$WORK/pending.json"
    else
      echo '[]' > "$WORK/pending.json"
    fi

    # Merge into single structured JSON output
    jq -n \
      --arg me "$ME" \
      --slurpfile metas "$WORK/meta.json" \
      --slurpfile filePages "$WORK/files.json" \
      --slurpfile inlinePages "$WORK/inline.json" \
      --slurpfile reviewsAll "$WORK/reviews.json" \
      --slurpfile threadsAll "$WORK/threads.json" \
      --slurpfile pendingComments "$WORK/pending.json" \
      "$STANDING_JQ $THREADS_JQ"'
      $metas[0] as $meta | ($filePages | add // []) as $files | ($inlinePages | add // []) as $inline
      | $reviewsAll[0] as $reviews | ($threadsAll[0] | shape_threads) as $threads
      | ($reviews | standing($me)) as $standing
      | ([$reviews[] | select(.state == "PENDING" and .user.login == $me)][0]) as $pending
      | {
        number: $meta.number,
        title: $meta.title,
        url: $meta.url,
        author: $meta.author.login,
        me: $me,
        headRef: $meta.headRefName,
        baseRef: $meta.baseRefName,
        headSha: $meta.headRefOid,
        reviews: [$reviews[] | select(.state != "PENDING") | {id, user: .user.login, state, commit: .commit_id, submittedAt: .submitted_at, body}],
        myStanding: ($standing + {blockingThreads: [$threads[] | select((.isResolved | not) and (.rootReviewId as $r | $standing.blockingReviewIds | index($r)))]}),
        myPendingReview: (if $pending == null then null else
          {id: $pending.id, commit: $pending.commit_id, atHead: ($pending.commit_id == $meta.headRefOid), body: $pending.body,
           comments: [$pendingComments[0][] | {path, line: (.line // .original_line), position, body}]} end),
        threads: $threads,
        inlineComments: [$inline[] | {user: .user.login, path: .path, line: (.line // .original_line), body: (.body | .[0:400])}],
        files: [$files[] | {path: .filename, status: .status, additions: .additions, deletions: .deletions, patch: .patch}]
      }'
    ;;

  submit)
    require_gh

    if [[ -z "$PR" || -z "$OWNER" || -z "$REPO" || -z "$SHA" ]]; then
      echo "Error: --pr, --owner, --repo, --sha required for submit" >&2
      exit 1
    fi

    # Read review JSON from stdin (shape in the header).
    REVIEW_JSON=$(cat)

    # Validate the payload before any GitHub call. GitHub accepts an empty or
    # event-less body and creates an empty PENDING review, which then blocks
    # the account's next review on that PR, so a missing draft file piped in
    # as `cat missing.json | ...` must exit 1 here instead of posting.
    #
    # APPROVE is allowed (pr-review's event-mapping rule): on a PR we do not
    # author, a review that found nothing blocking submits APPROVE, and one that
    # found a must-fix submits REQUEST_CHANGES. The skill decides which; this
    # script only refuses events GitHub has no verb for.
    VALIDATION=$(printf '%s' "$REVIEW_JSON" | jq -rs '
      if length == 0 then "stdin is empty (was the draft file missing?)"
      elif length > 1 then "stdin holds \(length) JSON values; expected exactly one review object"
      else .[0] |
        if type != "object" then "review must be a JSON object, got \(type)"
        elif (has("event") | not) then "review is missing \"event\""
        elif (.event != "COMMENT" and .event != "REQUEST_CHANGES" and .event != "APPROVE") then "event must be COMMENT, REQUEST_CHANGES or APPROVE, got \(.event | tojson)"
        elif has("comments") and (.comments | type) != "array" then "\"comments\" must be an array"
        elif any((.comments // [])[]; type != "object" or ((.path // "") == "") or ((.line | type) != "number") or ((.body // "") == "")) then "every comment needs a non-empty path, a numeric line, and a non-empty body"
        elif has("replies") and (.replies | type) != "array" then "\"replies\" must be an array"
        elif any((.replies // [])[]; type != "object" or ((.thread_id // "") == "") or ((.body // "") == "") or (has("resolve") and (.resolve | type) != "boolean")) then "every reply needs a non-empty thread_id and body; resolve must be a boolean"
        elif ((.body // "") == "") and ((.comments // []) | length) == 0 and ((.replies // []) | length) == 0 then "review has no body, comments, or replies"
        else "OK" end
      end' 2>/dev/null) || VALIDATION="stdin is not valid JSON"
    if [[ "$VALIDATION" != "OK" ]]; then
      echo "Error: refusing to submit: $VALIDATION" >&2
      exit 1
    fi
    EVENT=$(printf '%s' "$REVIEW_JSON" | jq -r '.event')

    PR_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR" --jq '{head: .head.sha, author: .user.login}') || {
      echo "Error: failed to read PR $OWNER/$REPO#$PR" >&2; exit 1
    }
    HEAD_SHA=$(printf '%s' "$PR_JSON" | jq -r '.head')
    ME=$(gh api user --jq .login)

    # A verdict on our own PR is rejected by GitHub. Refuse it here, before a
    # draft adoption could add comments to a review that then cannot submit.
    if [[ "$(printf '%s' "$PR_JSON" | jq -r '.author')" == "$ME" && "$EVENT" != "COMMENT" ]]; then
      echo "Error: refusing to submit: $EVENT on your own PR; GitHub only accepts COMMENT from the author" >&2
      exit 1
    fi

    # Anchor check: GitHub rejects the WHOLE review with a bare HTTP 422 when
    # any inline comment sits on a line outside the PR diff (an unchanged line
    # between hunks, or a path the PR does not touch), so check every anchor
    # against the file patches first and name each bad one. A RIGHT anchor is
    # valid on an added or context line of a hunk; a LEFT anchor on a removed
    # or context line. Files GitHub returns without a patch (binary, or too
    # large) are not checked. The patches describe the PR head, so the check is
    # skipped with a warning when --sha is not the head.
    if [[ "$(printf '%s' "$REVIEW_JSON" | jq '(.comments // []) | length')" -gt 0 ]]; then
      if [[ "$HEAD_SHA" != "$SHA" ]]; then
        echo "WARN: --sha $SHA is not the PR head $HEAD_SHA; anchor check skipped" >&2
      else
        AWORK=$(mktemp -d /tmp/pr-review-anchor.XXXXXX)
        printf '%s' "$REVIEW_JSON" > "$AWORK/review.json"
        gh api "repos/$OWNER/$REPO/pulls/$PR/files" --paginate | jq -s 'add // []' > "$AWORK/files.json" || {
          rm -rf "$AWORK"; echo "Error: failed to fetch PR files for the anchor check" >&2; exit 1
        }
        ARC=0
        node -e '
          const fs = require("fs")
          const review = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
          const files = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
          const sets = new Map()
          for (const f of files) {
            if (f.patch == null) { sets.set(f.filename, null); continue }
            const right = new Set(), left = new Set()
            let o = 0, n = 0
            for (const l of f.patch.split("\n")) {
              const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(l)
              if (m) { o = +m[1]; n = +m[2]; continue }
              if (l.startsWith("+")) right.add(n++)
              else if (l.startsWith("-")) left.add(o++)
              else if (l.startsWith("\\")) continue
              else { right.add(n++); left.add(o++) }
            }
            sets.set(f.filename, { RIGHT: right, LEFT: left })
          }
          const bad = []
          for (const c of review.comments || []) {
            const side = c.side || "RIGHT"
            if (!sets.has(c.path)) { bad.push(`${c.path}:${c.line}: path is not in the PR diff`); continue }
            const s = sets.get(c.path)
            if (s == null) continue
            const lines = s[side] || s.RIGHT
            for (const ln of [c.start_line, c.line]) {
              if (ln == null || lines.has(ln)) continue
              let near = null
              for (const x of lines) if (near == null || Math.abs(x - ln) < Math.abs(near - ln)) near = x
              bad.push(`${c.path}:${ln} (${side}): outside the diff; nearest diff line ${near}`)
            }
          }
          if (bad.length > 0) { console.log(bad.join("\n")); process.exit(1) }
        ' "$AWORK/review.json" "$AWORK/files.json" > "$AWORK/out.txt" || ARC=$?
        BAD=$(cat "$AWORK/out.txt"); rm -rf "$AWORK"
        if [[ "$ARC" -ne 0 ]]; then
          echo "Error: refusing to submit: inline comment anchors outside the PR diff (GitHub would reject the whole review with HTTP 422). Move each onto a line inside a diff hunk:" >&2
          printf '%s\n' "${BAD:-anchor check failed to run}" >&2
          exit 1
        fi
      fi
    fi


    # Prose lint on the outbound review (top-level body, every inline comment
    # body, every reply body), the shared no-slop lint WITH the --semantic
    # haiku judge — a PR review is where the 2026-08-19 courtesy-ender incident
    # shipped, and this is the one point where the final text is fully
    # assembled. HARD findings refuse the submit; lint infra failure fails OPEN.
    # An adopted draft's own text is the operator's and is not linted.
    LINT="$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh"
    if [[ -x "$LINT" ]]; then
      # Trailing Xs required (macOS mktemp treats embedded-X templates as
      # literal names); `|| RC=$?` so set -e cannot die at the assignment.
      TMP=$(mktemp /tmp/pr-review-lint.XXXXXX) || TMP=""
      if [[ -n "$TMP" ]]; then
        printf '%s' "$REVIEW_JSON" | jq -r '[(.body // ""), ((.comments // [])[] | .body // ""), ((.replies // [])[] | .body // "")] | join("\n\n")' > "$TMP" 2>/dev/null || true
        RC=0
        OUT=$("$LINT" "$TMP" --semantic 2>/dev/null) || RC=$?
        rm -f "$TMP"
        if [[ "$RC" -eq 1 ]]; then
          echo "BLOCKED: review text fails the shared prose lint (writing-style/no-slop, judge tier included). Fix these and retry:" >&2
          printf '%s\n' "$OUT" | grep '^HARD' | head -8 >&2
          exit 1
        fi
      fi
    fi

    SWORK=$(mktemp -d /tmp/pr-review-submit.XXXXXX)
    trap 'rm -rf "$SWORK"' EXIT
    gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate | jq -s 'add // []' > "$SWORK/reviews.json"

    # Verdict guard (header): APPROVE over your own open REQUEST_CHANGES threads.
    if [[ "$EVENT" == "APPROVE" ]]; then
      STANDING=$(jq -c --arg me "$ME" "$STANDING_JQ"' standing($me)' "$SWORK/reviews.json")
      if [[ "$(printf '%s' "$STANDING" | jq -r '.state')" == "CHANGES_REQUESTED" ]]; then
        fetch_threads "$OWNER" "$REPO" "$PR" > "$SWORK/threads.json"
        OPEN=$(jq -r --argjson st "$STANDING" --argjson review "$REVIEW_JSON" "$THREADS_JQ"'
          ([$review.replies // [] | .[] | select(.resolve == true) | .thread_id]) as $resolving
          | shape_threads | .[]
          | select((.isResolved | not) and (.rootReviewId as $r | $st.blockingReviewIds | index($r)) and (.id as $i | $resolving | index($i) | not))
          | "  \(.id) \(.path):\(.line // "?") \(.rootBody | gsub("\n"; " ") | .[0:80])"' "$SWORK/threads.json")
        if [[ -n "$OPEN" ]]; then
          echo "BLOCKED: your standing verdict on $OWNER/$REPO#$PR is CHANGES_REQUESTED, and APPROVE would clear it while these threads from it are unresolved. For each: if the fix is confirmed at $SHA, add {\"thread_id\": ..., \"body\": ..., \"resolve\": true} to replies; if not, keep REQUEST_CHANGES and reply that it is still present." >&2
          printf '%s\n' "$OPEN" >&2
          exit 1
        fi
      fi
    fi

    # Pending draft handling (header). Never deletes a draft that holds content.
    PENDING=$(jq -c --arg me "$ME" '[.[] | select(.state == "PENDING" and .user.login == $me)][0] // empty' "$SWORK/reviews.json")
    DRAFT_ACTION="none"
    if [[ -n "$PENDING" ]]; then
      PENDING_ID=$(printf '%s' "$PENDING" | jq -r '.id')
      PENDING_NODE=$(printf '%s' "$PENDING" | jq -r '.node_id')
      PENDING_BODY=$(printf '%s' "$PENDING" | jq -r '.body // ""')
      gh api "repos/$OWNER/$REPO/pulls/$PR/reviews/$PENDING_ID/comments" --paginate | jq -s 'add // []' > "$SWORK/pending.json"
      PENDING_COUNT=$(jq 'length' "$SWORK/pending.json")
      if [[ "$PENDING_COUNT" -eq 0 && -z "$PENDING_BODY" ]]; then
        DRAFT_ACTION="delete-empty"
      elif [[ "$(printf '%s' "$PENDING" | jq -r '.commit_id')" != "$SHA" ]]; then
        DRAFT_ACTION="publish-separately"
      else
        DRAFT_ACTION="adopt"
      fi
      echo ">> pending draft $PENDING_ID by $ME ($PENDING_COUNT comment(s)): $DRAFT_ACTION" >&2
      jq -r '.[] | "   \(.path):\(.line // .original_line // "pos \(.position)") \(.body | gsub("\n"; " ") | .[0:100])"' "$SWORK/pending.json" >&2
    fi

    REPLY_COUNT=$(printf '%s' "$REVIEW_JSON" | jq '(.replies // []) | length')
    BODY=$(printf '%s' "$REVIEW_JSON" | jq -r '.body // ""')
    if [[ "$DRAFT_ACTION" == "adopt" && -n "$PENDING_BODY" ]]; then
      BODY="$PENDING_BODY${BODY:+$'\n\n'$BODY}"
    fi

    if [[ "$CHECK_ONLY" == "1" ]]; then
      echo "check-only: payload, anchors, verdict guard and prose lint OK; draft action: $DRAFT_ACTION; nothing posted"
      exit 0
    fi

    case "$DRAFT_ACTION" in
      delete-empty)
        gh api "repos/$OWNER/$REPO/pulls/$PR/reviews/$PENDING_ID" -X DELETE >/dev/null
        echo ">> deleted empty pending draft $PENDING_ID" >&2
        ;;
      publish-separately)
        jq -n --arg body "$PENDING_BODY" '{event: "COMMENT", body: $body}' | \
          gh api "repos/$OWNER/$REPO/pulls/$PR/reviews/$PENDING_ID/events" -X POST --input - >/dev/null
        echo ">> published pending draft $PENDING_ID as its own COMMENT review (it was pinned to an older commit)" >&2
        ;;
    esac

    # Plain path: no draft to adopt and no thread replies, one REST call.
    if [[ "$DRAFT_ACTION" != "adopt" && "$REPLY_COUNT" -eq 0 ]]; then
      printf '%s' "$REVIEW_JSON" | jq --arg sha "$SHA" 'del(.replies) + {commit_id: $sha}' | \
        gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" -X POST --input - | \
        jq '{id: .id, state: .state, url: .html_url}'
      exit 0
    fi

    # Pending-review path: build (or adopt) a pending review, add comments and
    # replies to it, then submit it with the payload's event.
    if [[ "$DRAFT_ACTION" == "adopt" ]]; then
      RID="$PENDING_ID"; RNODE="$PENDING_NODE"
      ADDED=0
      while IFS= read -r C; do
        [[ -z "$C" ]] && continue
        jq -n --arg rid "$RNODE" --argjson c "$C" '{
          query: "mutation($input: AddPullRequestReviewThreadInput!) { addPullRequestReviewThread(input: $input) { thread { id } } }",
          variables: {input: ({pullRequestReviewId: $rid, path: $c.path, line: $c.line, side: ($c.side // "RIGHT"), body: $c.body}
            + (if $c.start_line then {startLine: $c.start_line, startSide: ($c.start_side // $c.side // "RIGHT")} else {} end))}}' | \
          graphql_input >/dev/null || {
          echo "Error: adding comment $((ADDED + 1)) ($(printf '%s' "$C" | jq -r '"\(.path):\(.line)"')) to pending draft $RID failed; the draft is still pending with $ADDED of this payload's comments added and nothing was submitted" >&2
          exit 1
        }
        ADDED=$((ADDED + 1))
      done < <(printf '%s' "$REVIEW_JSON" | jq -c '(.comments // [])[]')
    else
      CREATED=$(printf '%s' "$REVIEW_JSON" | jq --arg sha "$SHA" '{commit_id: $sha, comments: (.comments // [])}' | \
        gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" -X POST --input -)
      RID=$(printf '%s' "$CREATED" | jq -r '.id'); RNODE=$(printf '%s' "$CREATED" | jq -r '.node_id')
    fi

    while IFS= read -r R; do
      [[ -z "$R" ]] && continue
      jq -n --arg rid "$RNODE" --argjson r "$R" '{
        query: "mutation($input: AddPullRequestReviewThreadReplyInput!) { addPullRequestReviewThreadReply(input: $input) { comment { id } } }",
        variables: {input: {pullRequestReviewId: $rid, pullRequestReviewThreadId: $r.thread_id, body: $r.body}}}' | \
        graphql_input >/dev/null || {
        echo "Error: adding the reply to thread $(printf '%s' "$R" | jq -r '.thread_id') failed; pending review $RID holds what was added so far and nothing was submitted" >&2
        exit 1
      }
    done < <(printf '%s' "$REVIEW_JSON" | jq -c '(.replies // [])[]')

    jq -n --arg event "$EVENT" --arg body "$BODY" '{event: $event} + (if $body == "" then {} else {body: $body} end)' | \
      gh api "repos/$OWNER/$REPO/pulls/$PR/reviews/$RID/events" -X POST --input - | \
      jq '{id: .id, state: .state, url: .html_url}'

    while IFS= read -r TID; do
      [[ -z "$TID" ]] && continue
      jq -n --arg id "$TID" '{query: "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }", variables: {id: $id}}' | \
        graphql_input >/dev/null && echo ">> resolved thread $TID" >&2 || echo "WARN: review posted, but resolving thread $TID failed" >&2
    done < <(printf '%s' "$REVIEW_JSON" | jq -r '(.replies // [])[] | select(.resolve == true) | .thread_id')
    ;;

  *)
    echo "Usage: github-pr-review.sh {context|submit} [args]" >&2
    exit 1
    ;;
esac
