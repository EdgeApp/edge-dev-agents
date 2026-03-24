#!/usr/bin/env bash
# github-pr-hudl.sh — Fetch comprehensive GitHub PR activity for a given day.
# Detects multiple action categories for HUDL standup generation.
#
# Categories:
#   - created: PRs created by user on target date
#   - committed: PRs where user pushed commits on target date
#   - addressed: PRs with commits after receiving review comments
#   - reviewed: PRs by others that user reviewed on target date
#   - commented: PRs where user posted comments on target date
#   - approved: PRs that have approval (for Goals Today)
#   - blocked: PRs blocked by CI or changes requested (for Handoffs)
#   - open_prs: All open PRs for debug section
#
# Usage:
#   github-pr-hudl.sh [--date YYYY-MM-DD]
#
# Requires: gh CLI authenticated, ASANA_TOKEN for cross-referencing
#
# Output: JSON with date, username, day_label, and category arrays
set -euo pipefail

TARGET_DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date) TARGET_DATE="$2"; shift 2 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI not installed" >&2; exit 1
fi
if ! gh auth status &>/dev/null 2>&1; then
  echo "PROMPT_GH_AUTH" >&2; exit 2
fi

USERNAME=$(gh api user --jq '.login')
ASANA_TOKEN="${ASANA_TOKEN:-}"

export TARGET_DATE USERNAME ASANA_TOKEN

python3 - << 'PYEOF'
import json, os, re, subprocess, sys, urllib.request, urllib.error
from datetime import date, timedelta

USERNAME = os.environ["USERNAME"]
TARGET_DATE_STR = os.environ.get("TARGET_DATE", "")
ASANA_TOKEN = os.environ.get("ASANA_TOKEN", "")

today = date.today()

if TARGET_DATE_STR:
    # Explicit date: use single day
    target_start = date.fromisoformat(TARGET_DATE_STR)
    target_end = target_start
    day_label = target_start.strftime("%A")
else:
    # Default: from last workday until now
    if today.weekday() == 0:  # Monday
        target_start = today - timedelta(days=3)  # Friday
        target_end = today
        day_label = "since Friday"
    else:
        target_start = today - timedelta(days=1)  # Yesterday
        target_end = today
        day_label = "since yesterday"

TARGET_START_STR = target_start.isoformat()
TARGET_END_STR = target_end.isoformat()


def gh_graphql(query, variables):
    args = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in variables.items():
        args.extend(["-f", f"{k}={v}"])
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"GH_ERROR: {result.stderr[:300]}", file=sys.stderr)
        return {"data": {"search": {"nodes": []}}}
    parsed = json.loads(result.stdout)
    if "errors" in parsed:
        print(f"GQL_ERROR: {json.dumps(parsed['errors'][:2])}", file=sys.stderr)
    return parsed


def extract_asana_gid(body):
    if not body:
        return None
    m = re.search(r'asana\.com/\S*/(\d{10,})', body)
    return m.group(1) if m else None


def fetch_asana_status(gid):
    """Fetch Asana task status via API."""
    if not ASANA_TOKEN or not gid:
        return None
    try:
        req = urllib.request.Request(
            f"https://app.asana.com/api/1.0/tasks/{gid}?opt_fields=custom_fields.gid,custom_fields.display_value",
            headers={"Authorization": f"Bearer {ASANA_TOKEN}"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            for f in data.get("data", {}).get("custom_fields", []):
                if f.get("gid") == "1190660107346181":  # Status field
                    return f.get("display_value")
    except Exception as e:
        print(f"ASANA_ERROR: {e}", file=sys.stderr)
    return None


# --- Main GraphQL query for user's activity ---
QUERY_USER_PRS = """
query($search: String!) {
  search(query: $search, type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        body
        state
        createdAt
        repository { nameWithOwner }
        reviews(last: 50) {
          nodes {
            author { login }
            state
            submittedAt
          }
        }
        commits(last: 50) {
          nodes {
            commit {
              committedDate
              author { user { login } }
            }
          }
        }
        comments(last: 50) {
          nodes {
            author { login }
            createdAt
          }
        }
        reviewThreads(first: 50) {
          nodes {
            comments(first: 10) {
              nodes {
                author { login }
                createdAt
              }
            }
          }
        }
        reviewDecision
        statusCheckRollup {
          state
        }
      }
    }
  }
}
"""

# Search 1: User's own PRs (open or recently updated)
search_authored = f"is:pr author:{USERNAME} updated:>={TARGET_START_STR} sort:updated"
authored_raw = gh_graphql(QUERY_USER_PRS, {"search": search_authored})

# Search 2: PRs reviewed by user
search_reviewed = f"is:pr reviewed-by:{USERNAME} -author:{USERNAME} updated:>={TARGET_START_STR} sort:updated"
reviewed_raw = gh_graphql(QUERY_USER_PRS, {"search": search_reviewed})

# Search 3: PRs where user commented
search_commented = f"is:pr commenter:{USERNAME} -author:{USERNAME} updated:>={TARGET_START_STR} sort:updated"
commented_raw = gh_graphql(QUERY_USER_PRS, {"search": search_commented})

search_count = 0
for raw in [authored_raw, reviewed_raw, commented_raw]:
    search_count += len(raw.get("data", {}).get("search", {}).get("nodes", []))

print(f"Searched {search_count} PR candidates", file=sys.stderr)

# --- Process authored PRs ---
created = []
committed = []
addressed = []
approved = []
blocked = []
open_prs = []

seen_prs = set()

for node in authored_raw.get("data", {}).get("search", {}).get("nodes", []):
    if not node or "number" not in node:
        continue
    
    pr_key = f"{node['repository']['nameWithOwner']}#{node['number']}"
    if pr_key in seen_prs:
        continue
    seen_prs.add(pr_key)
    
    asana_gid = extract_asana_gid(node.get("body"))
    asana_status = fetch_asana_status(asana_gid) if asana_gid else None
    
    pr_entry = {
        "pr_number": node["number"],
        "pr_title": node["title"],
        "pr_url": node["url"],
        "repo": node["repository"]["nameWithOwner"],
        "asana_gid": asana_gid,
        "asana_status": asana_status,
    }
    
    # Check if created within target window
    created_at = (node.get("createdAt") or "")[:10]
    if TARGET_START_STR <= created_at <= TARGET_END_STR:
        created.append(pr_entry)
    
    # Check for human reviews before target window
    has_prior_review = False
    for r in (node.get("reviews") or {}).get("nodes", []):
        if not r or not r.get("author"):
            continue
        reviewer = r["author"].get("login", "")
        if reviewer == USERNAME or "[bot]" in reviewer:
            continue
        submitted = (r.get("submittedAt") or "")[:10]
        if submitted < TARGET_START_STR and r.get("state") in ("CHANGES_REQUESTED", "COMMENTED"):
            has_prior_review = True
            break
    
    # Check for commits within target window
    commits_in_window = []
    for c in (node.get("commits") or {}).get("nodes", []):
        commit = (c or {}).get("commit", {})
        committed_date = (commit.get("committedDate") or "")[:10]
        commit_user = ((commit.get("author") or {}).get("user") or {}).get("login", "")
        if TARGET_START_STR <= committed_date <= TARGET_END_STR and commit_user == USERNAME:
            commits_in_window.append(commit)
    
    if commits_in_window:
        entry_with_count = {**pr_entry, "commit_count": len(commits_in_window)}
        # Only count as addressed/committed if PR wasn't created in window
        if not (TARGET_START_STR <= created_at <= TARGET_END_STR):
            if has_prior_review:
                addressed.append(entry_with_count)
            else:
                committed.append(entry_with_count)
    
    # Track open PRs for debug and blocked/approved analysis
    if node.get("state") == "OPEN":
        review_decision = node.get("reviewDecision")
        ci_state = (node.get("statusCheckRollup") or {}).get("state")
        
        # Determine status summary
        status_parts = []
        if review_decision:
            status_parts.append(review_decision.lower().replace("_", " "))
        if ci_state:
            status_parts.append(f"CI: {ci_state.lower()}")
        if asana_status:
            status_parts.append(f"Asana: {asana_status}")
        
        open_prs.append({
            **pr_entry,
            "review_decision": review_decision,
            "ci_state": ci_state,
            "status_summary": ", ".join(status_parts) if status_parts else "open"
        })
        
        # Check if approved (GitHub approved OR Asana Publish Needed)
        if review_decision == "APPROVED" or asana_status == "Publish Needed":
            approved.append(pr_entry)
        
        # Check if blocked
        if ci_state == "FAILURE":
            blocked.append({**pr_entry, "block_reason": "ci_failure", "detail": "CI failing"})
        elif review_decision == "CHANGES_REQUESTED":
            # Find who requested changes
            changers = []
            for r in (node.get("reviews") or {}).get("nodes", []):
                if r and r.get("state") == "CHANGES_REQUESTED":
                    author = (r.get("author") or {}).get("login", "")
                    if author and author not in changers:
                        changers.append(author)
            blocked.append({
                **pr_entry,
                "block_reason": "changes_requested",
                "detail": ", ".join(changers) if changers else "reviewer"
            })

# --- Process reviewed PRs ---
reviewed = []
for node in reviewed_raw.get("data", {}).get("search", {}).get("nodes", []):
    if not node or "number" not in node:
        continue
    
    pr_key = f"{node['repository']['nameWithOwner']}#{node['number']}"
    if pr_key in seen_prs:
        continue
    seen_prs.add(pr_key)
    
    # Find user's review within target window
    review_state = None
    for r in (node.get("reviews") or {}).get("nodes", []):
        if not r or not r.get("author"):
            continue
        if r["author"].get("login") != USERNAME:
            continue
        submitted = (r.get("submittedAt") or "")[:10]
        if TARGET_START_STR <= submitted <= TARGET_END_STR:
            review_state = r.get("state", "COMMENTED")
            break
    
    if review_state:
        reviewed.append({
            "pr_number": node["number"],
            "pr_title": node["title"],
            "pr_url": node["url"],
            "repo": node["repository"]["nameWithOwner"],
            "asana_gid": extract_asana_gid(node.get("body")),
            "review_state": review_state,
        })

# --- Process commented PRs ---
commented_list = []
for node in commented_raw.get("data", {}).get("search", {}).get("nodes", []):
    if not node or "number" not in node:
        continue
    
    pr_key = f"{node['repository']['nameWithOwner']}#{node['number']}"
    if pr_key in seen_prs:
        continue
    seen_prs.add(pr_key)
    
    # Check for comments by user on target date
    has_comment = False
    
    # Issue comments
    for c in (node.get("comments") or {}).get("nodes", []):
        if not c:
            continue
        author = (c.get("author") or {}).get("login", "")
        created = (c.get("createdAt") or "")[:10]
        if author == USERNAME and TARGET_START_STR <= created <= TARGET_END_STR:
            has_comment = True
            break
    
    # Review thread comments
    if not has_comment:
        for thread in (node.get("reviewThreads") or {}).get("nodes", []):
            for c in (thread.get("comments") or {}).get("nodes", []):
                if not c:
                    continue
                author = (c.get("author") or {}).get("login", "")
                created = (c.get("createdAt") or "")[:10]
                if author == USERNAME and TARGET_START_STR <= created <= TARGET_END_STR:
                    has_comment = True
                    break
            if has_comment:
                break
    
    if has_comment:
        commented_list.append({
            "pr_number": node["number"],
            "pr_title": node["title"],
            "pr_url": node["url"],
            "repo": node["repository"]["nameWithOwner"],
            "asana_gid": extract_asana_gid(node.get("body")),
        })

print(json.dumps({
    "date_start": TARGET_START_STR,
    "date_end": TARGET_END_STR,
    "day_label": day_label,
    "username": USERNAME,
    "search_count": search_count,
    "created": created,
    "committed": committed,
    "addressed": addressed,
    "reviewed": reviewed,
    "commented": commented_list,
    "approved": approved,
    "blocked": blocked,
    "open_prs": open_prs,
}, indent=2))
PYEOF
