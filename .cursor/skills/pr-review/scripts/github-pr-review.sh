#!/usr/bin/env bash
# github-pr-review.sh — Fetch PR review context and submit reviews via gh CLI.
#
# Subcommands:
#   context  [--pr <number>] [--owner <o>] [--repo <r>]   Fetch PR metadata + files + existing reviews
#   submit   --pr <n> --owner <o> --repo <r> --sha <sha>  Post review (JSON on stdin; exits 1
#            without calling GitHub if stdin is empty, not one JSON object, has an event
#            other than COMMENT/REQUEST_CHANGES/APPROVE, or has malformed comments)
#
# The `context` subcommand auto-detects the PR from the current branch if --pr is omitted.
# Total API calls: 2 (gh pr view + gh api for file patches).
#
# Exit codes: 0 = success, 1 = error, 2 = needs user input (e.g. gh not authenticated)
set -euo pipefail

CMD="${1:-}"
shift || true

OWNER="" REPO="" PR="" SHA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
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

case "$CMD" in
  context)
    require_gh

    # --- Call 1: PR metadata + reviews via gh pr view ---
    VIEW_ARGS=()
    [[ -n "$PR" ]] && VIEW_ARGS+=("$PR")
    [[ -n "$OWNER" && -n "$REPO" ]] && VIEW_ARGS+=("--repo" "$OWNER/$REPO")

    META=$(gh pr view ${VIEW_ARGS[@]+"${VIEW_ARGS[@]}"} \
      --json number,title,url,headRefName,headRefOid,baseRefName,reviews 2>&1) || {
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

    # Merge into single structured JSON output
    jq -n \
      --slurpfile metas "$WORK/meta.json" \
      --slurpfile filePages "$WORK/files.json" \
      --slurpfile inlinePages "$WORK/inline.json" \
      '$metas[0] as $meta | ($filePages | add // []) as $files | ($inlinePages | add // []) as $inline | {
        number: $meta.number,
        title: $meta.title,
        url: $meta.url,
        headRef: $meta.headRefName,
        baseRef: $meta.baseRefName,
        headSha: $meta.headRefOid,
        reviews: [($meta.reviews // [])[] | {user: .author.login, state: .state, body: .body}],
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

    # Read review JSON from stdin: { event, body, comments: [{path, line, body, start_line?, side?}] }
    # Inject commit_id from --sha and POST to reviews endpoint.
    REVIEW_JSON=$(cat)

    # Validate the payload before any GitHub call. GitHub accepts an empty or
    # event-less body and creates an empty PENDING review, which then blocks
    # the account's next review on that PR, so a missing draft file piped in
    # as `cat missing.json | ...` must exit 1 here instead of posting.
    #
    # APPROVE is allowed (pr-review's event-mapping rule): on a PR we do not
    # author, a review that found nothing blocking submits APPROVE, and one that
    # found a must-fix submits REQUEST_CHANGES. The skill decides which; this
    # script only refuses events GitHub has no verb for. An APPROVE or
    # REQUEST_CHANGES on OUR OWN PR is rejected by GitHub itself (a self-review
    # verdict is not permitted), so that case surfaces as an API error rather
    # than a silent COMMENT.
    VALIDATION=$(printf '%s' "$REVIEW_JSON" | jq -rs '
      if length == 0 then "stdin is empty (was the draft file missing?)"
      elif length > 1 then "stdin holds \(length) JSON values; expected exactly one review object"
      else .[0] |
        if type != "object" then "review must be a JSON object, got \(type)"
        elif (has("event") | not) then "review is missing \"event\""
        elif (.event != "COMMENT" and .event != "REQUEST_CHANGES" and .event != "APPROVE") then "event must be COMMENT, REQUEST_CHANGES or APPROVE, got \(.event | tojson)"
        elif has("comments") and (.comments | type) != "array" then "\"comments\" must be an array"
        elif any((.comments // [])[]; type != "object" or ((.path // "") == "") or ((.line | type) != "number") or ((.body // "") == "")) then "every comment needs a non-empty path, a numeric line, and a non-empty body"
        elif ((.body // "") == "") and ((.comments // []) | length) == 0 then "review has neither a body nor comments"
        else "OK" end
      end' 2>/dev/null) || VALIDATION="stdin is not valid JSON"
    if [[ "$VALIDATION" != "OK" ]]; then
      echo "Error: refusing to submit: $VALIDATION" >&2
      exit 1
    fi

    # Prose lint on the outbound review (top-level body + every inline comment
    # body), the shared no-slop lint WITH the --semantic haiku judge — a PR
    # review is where the 2026-08-19 courtesy-ender incident shipped, and this
    # is the one point where the final text is fully assembled. HARD findings
    # refuse the submit; lint infra failure fails OPEN.
    LINT="$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh"
    if [[ -x "$LINT" ]]; then
      # Trailing Xs required (macOS mktemp treats embedded-X templates as
      # literal names); `|| RC=$?` so set -e cannot die at the assignment.
      TMP=$(mktemp /tmp/pr-review-lint.XXXXXX) || TMP=""
      if [[ -n "$TMP" ]]; then
        printf '%s' "$REVIEW_JSON" | jq -r '[(.body // ""), ((.comments // [])[] | .body // "")] | join("\n\n")' > "$TMP" 2>/dev/null || true
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

    printf '%s' "$REVIEW_JSON" | jq --arg sha "$SHA" '. + {commit_id: $sha}' | \
      gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" -X POST --input - | \
      jq '{id: .id, state: .state, url: .html_url}'
    ;;

  *)
    echo "Usage: github-pr-review.sh {context|submit} [args]" >&2
    exit 1
    ;;
esac
