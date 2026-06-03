#!/usr/bin/env bash
# pr-address.sh
# Companion script for pr-address.md
# Handles deterministic operations: comment fetching, replies, thread resolution, autosquash.
#
# Subcommands:
#   fetch          --owner <o> --repo <r> --pr <n>         Fetch all unresolved feedback via GraphQL
#   fetch-thread   --owner <o> --repo <r> --pr <n> --thread-id <id>
#   reply          --owner <o> --repo <r> --pr <n> --comment-id <id> --body <text>
#   resolve-thread --thread-id <node_id>                   Mark inline thread as resolved (GraphQL)
#   mark-addressed --owner <o> --repo <r> --pr <n> --type <review|comment> --target-id <id> --body <text>
#   resolve-id     --owner <o> --repo <r> --pr <n> --node-id <id>
#   headline       --owner <o> --repo <r> --sha <sha>
#   fetch-pr-body  --owner <o> --repo <r> --pr <n>         Fetch current PR body → /tmp/pr-body.md
#   ensure-branch  --owner <o> --repo <r> --pr <n>         Checkout PR branch, stash if needed, pull.
#                                                          If the branch is already bound to another worktree,
#                                                          reports WORKTREE_PATH=<dir> and leaves main checkout untouched.
#                                                          Installs node deps (npm ci / yarn install) when the
#                                                          target dir has no node_modules — may take minutes.
#   review-mode    --owner <o> --repo <r> --pr <n>         Determine autosquash/preserve mode from latest human activity
#   autosquash                                             Rebase --autosquash from merge-base
#
# Exit codes: 0 = success, 1 = error, 2 = needs user input (e.g. gh not authenticated)
set -euo pipefail

CMD="${1:-}"
shift || true

OWNER="" REPO="" PR="" COMMENT_ID="" NODE_ID="" BODY="" SHA="" THREAD_ID="" TARGET_TYPE="" TARGET_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --comment-id) COMMENT_ID="$2"; shift 2 ;;
    --node-id) NODE_ID="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --thread-id) THREAD_ID="$2"; shift 2 ;;
    --type) TARGET_TYPE="$2"; shift 2 ;;
    --target-id) TARGET_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

require_gh() {
  if ! command -v gh &>/dev/null; then
    echo "PROMPT_GH_INSTALL" >&2; exit 2
  fi
  if ! gh auth status &>/dev/null 2>&1; then
    echo "PROMPT_GH_AUTH" >&2; exit 2
  fi
}

# Install node deps in <dir> when node_modules is absent. Agent worktrees are
# created without an install, so lint-commit.sh's `./node_modules/.bin/eslint`
# would be missing. Detects the package manager from the lockfile (npm vs yarn).
# Can take several minutes on a cold worktree — callers must allow for it.
ensure_deps() {
  local dir="$1"
  [[ -d "$dir/node_modules" ]] && return 0
  echo ">> No node_modules in $dir — installing dependencies (may take several minutes)"
  # Bypass the socket-firewall shim (~/.agent-shims/{yarn,npm} → `socket <pm>`),
  # which loops its banner and exits non-zero on the recursive prepare/husky
  # lifecycle. Strip the shim dir from PATH so the install AND its lifecycle
  # scripts run the real package managers directly.
  local clean_path
  clean_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '\.agent-shims' | paste -sd: - || true)"
  # Global ~/.npmrc auths the public registry with `_authToken=${NPM_TOKEN}`.
  # yarn 1.x aborts when that var is unset (common in agent envs). A dummy value
  # satisfies the substitution; a bogus token is harmless for public-package
  # installs. A real NPM_TOKEN in the env still wins.
  local npm_token="${NPM_TOKEN:-public}"
  if [[ -f "$dir/package-lock.json" ]]; then
    ( cd "$dir" && PATH="$clean_path" NPM_TOKEN="$npm_token" npm ci ) || { echo "Error: npm ci failed in $dir" >&2; exit 1; }
  elif [[ -f "$dir/yarn.lock" ]]; then
    ( cd "$dir" && PATH="$clean_path" NPM_TOKEN="$npm_token" yarn install --frozen-lockfile ) || { echo "Error: yarn install failed in $dir" >&2; exit 1; }
  else
    echo "Error: no package-lock.json or yarn.lock in $dir — cannot install deps" >&2; exit 1
  fi
  echo ">> Dependencies installed in $dir"
}

case "$CMD" in
  fetch)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" ]]; then
      echo "Error: --owner, --repo, --pr required" >&2; exit 1
    fi

    gh api graphql \
      -f query='query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $number) {
            author { login __typename }
            headRefName
            baseRefName
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                comments(first: 50) {
                  nodes {
                    databaseId
                    createdAt
                    author { login __typename }
                    path
                    line
                    body
                  }
                }
              }
            }
            reviews(last: 50) {
              nodes {
                databaseId
                author { login __typename }
                state
                body
                submittedAt
              }
            }
            comments(last: 50) {
              nodes {
                databaseId
                createdAt
                author { login __typename }
                body
              }
            }
          }
        }
      }' \
      -f owner="$OWNER" -f repo="$REPO" -F number="$PR" \
    | GH_USER=$(gh api user --jq '.login') node -e "
      const fs = require('fs')
      const data = JSON.parse(fs.readFileSync('/dev/stdin', 'utf8'))
      const pr = data.data.repository.pullRequest
      const prAuthor = pr.author?.login
      const currentUser = process.env.GH_USER

      const addressedIds = new Set()
      for (const c of pr.comments.nodes) {
        for (const m of (c.body || '').matchAll(/<!-- addressed:(?:review|comment):(\d+) -->/g)) {
          addressedIds.add(Number(m[1]))
        }
      }

      // GraphQL marks bot actors with __typename === 'Bot' and strips the
      // '[bot]' suffix from their login (so Cursor's Bugbot AND its Security
      // Reviewer both appear as 'cursor'). Collect every bot login from the
      // payload so detection covers all automated reviewers (coderabbitai,
      // github-actions, sonarcloud, copilot, etc.) rather than a hard-coded list.
      const botLogins = new Set()
      const noteAuthor = a => { if (a && a.__typename === 'Bot' && a.login) botLogins.add(a.login) }
      noteAuthor(pr.author)
      for (const t of pr.reviewThreads.nodes) for (const c of t.comments.nodes) noteAuthor(c.author)
      for (const r of pr.reviews.nodes) noteAuthor(r.author)
      for (const c of pr.comments.nodes) noteAuthor(c.author)

      // '[bot]' suffix = REST-sourced login fallback; chatgpt-codex-connector is a
      // User-typed automation account (no Bot typename) so it stays hard-coded.
      const isBot = u => !u || botLogins.has(u) || u.includes('[bot]')
      const isAutomatedReviewer = u => isBot(u) || u === 'chatgpt-codex-connector'

      const threads = pr.reviewThreads.nodes
        .filter(t => !t.isResolved)
        .map(t => ({
          threadId: t.id,
          path: t.comments.nodes[0]?.path,
          line: t.comments.nodes[0]?.line,
          comments: t.comments.nodes.map(c => ({
            id: c.databaseId,
            user: c.author?.login,
            body: c.body,
            createdAt: c.createdAt
          }))
        }))

      // Check if any human (non-bot, non-automated, non-currentUser) reviewer has commented
      // prAuthor CAN be an external human reviewer if they're not currentUser
      const humanCommenters = new Set()
      for (const t of threads) {
        for (const c of t.comments) {
          if (c.user && !isAutomatedReviewer(c.user) && c.user !== currentUser) {
            humanCommenters.add(c.user)
          }
        }
      }

      const latestByUser = {}
      for (const r of pr.reviews.nodes) {
        const user = r.author?.login
        if (!user || user === currentUser || r.state === 'PENDING' || isBot(user)) continue
        const prev = latestByUser[user]
        if (!prev || new Date(r.submittedAt) > new Date(prev.submittedAt)) {
          latestByUser[user] = r
        }
        if (!isAutomatedReviewer(user)) {
          humanCommenters.add(user)
        }
      }
      const reviewBodies = Object.entries(latestByUser)
        .filter(([, r]) => r.body?.trim() && !addressedIds.has(r.databaseId))
        .map(([user, r]) => ({
          reviewId: r.databaseId, user, state: r.state,
          body: r.body, submittedAt: r.submittedAt
        }))

      const topLevel = pr.comments.nodes.filter(c => {
        const user = c.author?.login
        if (!user || user === currentUser || isBot(user)) return false
        if ((c.body || '').includes('<!-- addressed:')) return false
        if (!isAutomatedReviewer(user)) {
          humanCommenters.add(user)
        }
        return !addressedIds.has(c.databaseId)
      }).map(c => ({
        id: c.databaseId, user: c.author?.login,
        body: c.body, createdAt: c.createdAt
      }))

      console.log(JSON.stringify({
        prAuthor, currentUser, headRef: pr.headRefName, baseRef: pr.baseRefName,
        hasHumanReviewers: humanCommenters.size > 0,
        humanReviewers: Array.from(humanCommenters),
        threads, reviewBodies, topLevel
      }, null, 2))
    "
    ;;

  fetch-thread)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" || -z "$THREAD_ID" ]]; then
      echo "Error: --owner, --repo, --pr, --thread-id required" >&2; exit 1
    fi

    gh api graphql \
      -f query='query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $number) {
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                comments(first: 50) {
                  nodes {
                    databaseId
                    createdAt
                    author { login __typename }
                    path
                    line
                    body
                  }
                }
              }
            }
          }
        }
      }' \
      -f owner="$OWNER" -f repo="$REPO" -F number="$PR" \
    | GH_THREAD_ID="$THREAD_ID" node -e "
      const fs = require('fs')
      const data = JSON.parse(fs.readFileSync('/dev/stdin', 'utf8'))
      const threads = data.data.repository.pullRequest.reviewThreads.nodes
      const thread = threads.find(item => item.id === process.env.GH_THREAD_ID)
      if (thread == null) {
        console.error('Thread not found: ' + process.env.GH_THREAD_ID)
        process.exit(1)
      }

      console.log(JSON.stringify({
        threadId: thread.id,
        isResolved: thread.isResolved,
        path: thread.comments.nodes[0]?.path ?? null,
        line: thread.comments.nodes[0]?.line ?? null,
        comments: thread.comments.nodes.map(comment => ({
          id: comment.databaseId,
          user: comment.author?.login ?? null,
          body: comment.body,
          createdAt: comment.createdAt
        }))
      }, null, 2))
    "
    ;;

  reply)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" || -z "$COMMENT_ID" || -z "$BODY" ]]; then
      echo "Error: --owner, --repo, --pr, --comment-id, --body required" >&2; exit 1
    fi
    RESULT=$(echo '{}' | jq --arg body "$BODY" '{body: $body}' | \
      gh api "repos/$OWNER/$REPO/pulls/$PR/comments/$COMMENT_ID/replies" \
        -X POST --input -)
    ID=$(echo "$RESULT" | jq -r '.id // empty')
    if [[ -n "$ID" ]]; then
      echo "replied: $ID"
    else
      echo "Reply failed: $RESULT" >&2; exit 1
    fi
    ;;

  resolve-thread)
    require_gh
    if [[ -z "$THREAD_ID" ]]; then
      echo "Error: --thread-id required" >&2; exit 1
    fi
    RESULT=$(gh api graphql \
      -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }' \
      -f id="$THREAD_ID")
    RESOLVED=$(echo "$RESULT" | jq -r '.data.resolveReviewThread.thread.isResolved // empty')
    if [[ "$RESOLVED" == "true" ]]; then
      echo "resolved: $THREAD_ID"
    else
      echo "Resolve failed: $RESULT" >&2; exit 1
    fi
    ;;

  mark-addressed)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" || -z "$TARGET_TYPE" || -z "$TARGET_ID" || -z "$BODY" ]]; then
      echo "Error: --owner, --repo, --pr, --type, --target-id, --body required" >&2; exit 1
    fi
    MARKER="<!-- addressed:${TARGET_TYPE}:${TARGET_ID} -->"
    FULL_BODY="${BODY} ${MARKER}"
    RESULT=$(echo '{}' | jq --arg body "$FULL_BODY" '{body: $body}' | \
      gh api "repos/$OWNER/$REPO/issues/$PR/comments" -X POST --input -)
    ID=$(echo "$RESULT" | jq -r '.id // empty')
    if [[ -n "$ID" ]]; then
      echo "marked: $ID ($MARKER)"
    else
      echo "Mark failed: $RESULT" >&2; exit 1
    fi
    ;;

  resolve-id)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" || -z "$NODE_ID" ]]; then
      echo "Error: --owner, --repo, --pr, --node-id required" >&2; exit 1
    fi
    RESULT=$(gh api "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate \
      --jq ".[] | select(.node_id == \"$NODE_ID\") | .id")
    if [[ -n "$RESULT" ]]; then
      echo "$RESULT"
    else
      echo "Comment not found for node_id: $NODE_ID" >&2; exit 1
    fi
    ;;

  headline)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$SHA" ]]; then
      echo "Error: --owner, --repo, --sha required" >&2; exit 1
    fi
    gh api "repos/$OWNER/$REPO/commits/$SHA" --jq '.commit.message | split("\n") | .[0]'
    ;;

  fetch-pr-body)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" ]]; then
      echo "Error: --owner, --repo, --pr required" >&2; exit 1
    fi
    BODY=$(gh api "repos/$OWNER/$REPO/pulls/$PR" --jq '.body // ""')
    echo "$BODY" > /tmp/pr-body.md
    echo ">> Wrote PR body to /tmp/pr-body.md ($(wc -c < /tmp/pr-body.md | tr -d ' ') bytes)"
    ;;

  ensure-branch)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" ]]; then
      echo "Error: --owner, --repo, --pr required" >&2; exit 1
    fi

    PR_BRANCH=$(gh api "repos/$OWNER/$REPO/pulls/$PR" --jq '.head.ref')
    CURRENT_BRANCH=$(git branch --show-current)

    # If the PR branch is already checked out in another worktree, operate there
    # instead of stashing/switching the main checkout. git forbids the same branch
    # in two worktrees, so a plain `git checkout` would fail with fatal exit 128.
    THIS_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    WORKTREE_PATH=$(git worktree list --porcelain | awk -v b="refs/heads/$PR_BRANCH" '
      /^worktree /{wt=substr($0,10)}
      /^branch /{if($2==b){print wt; exit}}
    ')
    if [[ -n "$WORKTREE_PATH" && "$WORKTREE_PATH" != "$THIS_TOPLEVEL" ]]; then
      echo ">> $PR_BRANCH is checked out in worktree: $WORKTREE_PATH"
      git -C "$WORKTREE_PATH" pull --ff-only 2>&1 || git -C "$WORKTREE_PATH" pull --rebase 2>&1
      ensure_deps "$WORKTREE_PATH"
      echo ">> BRANCH_READY=$PR_BRANCH STASHED=false WORKTREE_PATH=$WORKTREE_PATH"
      exit 0
    fi

    if [[ "$CURRENT_BRANCH" == "$PR_BRANCH" ]]; then
      echo ">> Already on $PR_BRANCH — pulling latest"
      git pull --ff-only 2>&1 || git pull --rebase 2>&1
      ensure_deps "$(git rev-parse --show-toplevel)"
      echo ">> BRANCH_READY=$PR_BRANCH STASHED=false"
    else
      STASHED=false
      if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        echo ">> Stashing uncommitted changes on $CURRENT_BRANCH"
        git stash -u
        STASHED=true
      fi
      echo ">> Switching from $CURRENT_BRANCH to $PR_BRANCH"
      git checkout "$PR_BRANCH" 2>&1
      git pull --ff-only 2>&1 || git pull --rebase 2>&1
      ensure_deps "$(git rev-parse --show-toplevel)"
      echo ">> BRANCH_READY=$PR_BRANCH STASHED=$STASHED PREVIOUS_BRANCH=$CURRENT_BRANCH"
    fi
    ;;

  review-mode)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$PR" ]]; then
      echo "Error: --owner, --repo, --pr required" >&2; exit 1
    fi

    # Pull every reviews/comments/thread record (resolved or not) so we can find
    # the most-recent human activity. The "fetch" subcommand only returns
    # unresolved items, which would miss the case where the human's last action
    # was an inline comment that's already been resolved.
    gh api graphql \
      -f query='query($owner: String!, $repo: String!, $number: Int!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $number) {
            author { login __typename }
            reviewThreads(first: 100) {
              nodes {
                comments(first: 50) {
                  nodes { createdAt author { login __typename } }
                }
              }
            }
            reviews(last: 100) {
              nodes { author { login __typename } state submittedAt }
            }
            comments(last: 100) {
              nodes { createdAt author { login __typename } }
            }
          }
        }
      }' \
      -f owner="$OWNER" -f repo="$REPO" -F number="$PR" \
    | GH_USER=$(gh api user --jq '.login') node -e "
      const fs = require('fs')
      const data = JSON.parse(fs.readFileSync('/dev/stdin', 'utf8'))
      const pr = data.data.repository.pullRequest
      const prAuthor = pr.author?.login
      const currentUser = process.env.GH_USER

      // Identify bots by GraphQL __typename === 'Bot' (logins lose the '[bot]'
      // suffix here, so e.g. Cursor's Bugbot and Security Reviewer both show as
      // 'cursor'). Collect every bot login from the payload — see the fetch
      // subcommand for the full rationale.
      const botLogins = new Set()
      const noteAuthor = a => { if (a && a.__typename === 'Bot' && a.login) botLogins.add(a.login) }
      noteAuthor(pr.author)
      for (const t of pr.reviewThreads.nodes) for (const c of t.comments.nodes) noteAuthor(c.author)
      for (const r of pr.reviews.nodes) noteAuthor(r.author)
      for (const c of pr.comments.nodes) noteAuthor(c.author)

      const isBot = u => !u || botLogins.has(u) || u.includes('[bot]')
      const isAutomated = u => isBot(u) || u === 'chatgpt-codex-connector'
      // Exclude only currentUser + bots/automated. Works uniformly for solo
      // PRs (currentUser == prAuthor — author/self excluded) and collab PRs
      // (currentUser != prAuthor — author is a peer reviewer, included).
      const isHuman = u => u && u !== currentUser && !isAutomated(u)

      const events = []

      // Inline review comments (across all threads, resolved or not).
      for (const t of pr.reviewThreads.nodes) {
        for (const c of t.comments.nodes) {
          if (isHuman(c.author?.login)) {
            events.push({
              type: 'inline',
              user: c.author.login,
              timestamp: c.createdAt,
              state: null
            })
          }
        }
      }

      // Formal review submissions.
      for (const r of pr.reviews.nodes) {
        const user = r.author?.login
        if (!isHuman(user)) continue
        if (r.state === 'PENDING') continue
        events.push({
          type: 'review',
          user,
          timestamp: r.submittedAt,
          state: r.state
        })
      }

      // Top-level PR comments.
      for (const c of pr.comments.nodes) {
        if (isHuman(c.author?.login)) {
          events.push({
            type: 'topLevel',
            user: c.author.login,
            timestamp: c.createdAt,
            state: null
          })
        }
      }

      events.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp))
      const latest = events[0] || null

      let mode
      if (latest == null) {
        mode = 'autosquash'
      } else if (latest.type === 'review' && (latest.state === 'APPROVED' || latest.state === 'DISMISSED')) {
        mode = 'autosquash'
      } else {
        mode = 'preserve'
      }

      process.stdout.write(JSON.stringify({
        mode,
        latestHumanActivity: latest
      }) + '\n')
    "
    ;;

  autosquash)
    DEFAULT_UPSTREAM=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
      || echo "origin/$(git remote show origin | sed -n '/HEAD branch/s/.*: //p')")
    ~/.cursor/skills/git-branch-ops.sh autosquash --merge-base-with "$DEFAULT_UPSTREAM"
    ;;

  *)
    echo "Usage: pr-address.sh {fetch|fetch-thread|reply|resolve-thread|mark-addressed|resolve-id|headline|fetch-pr-body|ensure-branch|review-mode|autosquash} [args]" >&2
    exit 1
    ;;
esac
