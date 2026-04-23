#!/usr/bin/env bash
# bugbot.sh
# Companion script for bugbot.md
# Handles Cursor Bugbot check-run status queries. All PR thread operations
# (fetch, reply, resolve) are delegated to pr-address.sh; this script exists
# only to encapsulate the bugbot-specific check-run interpretation.
#
# Subcommands:
#   check-run-status  --owner <o> --repo <r> --sha <sha>
#     Returns compact JSON: {"status":"...","conclusion":"...","sha":"<short>"}
#     status values:      queued | in_progress | completed | none
#     conclusion values:  success | neutral | failure | skipped | null
#     "none" status means no Cursor Bugbot check-run exists for the SHA
#     (e.g. scan not yet triggered).
#
# Exit codes: 0 = success, 1 = error, 2 = needs user input (e.g. gh not authenticated)
set -euo pipefail

CMD="${1:-}"
shift || true

OWNER="" REPO="" SHA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
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

case "$CMD" in
  check-run-status)
    require_gh
    if [[ -z "$OWNER" || -z "$REPO" || -z "$SHA" ]]; then
      echo "Error: --owner, --repo, --sha required" >&2; exit 1
    fi

    SHORT_SHA="${SHA:0:10}"

    # Pull ALL Cursor Bugbot check-runs for the SHA, then pick the most-recent
    # by started_at. The API can return multiple entries (e.g. retries, rerun);
    # we want the latest so we don't declare clean based on a stale success.
    gh api "repos/$OWNER/$REPO/commits/$SHA/check-runs" --paginate \
      --jq '[.check_runs[]? | select(.name == "Cursor Bugbot")]' \
    | SHORT="$SHORT_SHA" node -e "
      const fs = require('fs')
      const runs = JSON.parse(fs.readFileSync('/dev/stdin', 'utf8'))
      const short = process.env.SHORT
      let out
      if (!Array.isArray(runs) || runs.length === 0) {
        out = {status: 'none', conclusion: null, sha: short}
      } else {
        // Most recent first — started_at is ISO-8601 so lexicographic sort works.
        runs.sort((a, b) => (b.started_at || '').localeCompare(a.started_at || ''))
        const latest = runs[0]
        out = {
          status: latest.status || null,
          conclusion: latest.conclusion || null,
          sha: short
        }
      }
      process.stdout.write(JSON.stringify(out) + '\n')
    "
    ;;
  ""|help|--help|-h)
    cat >&2 <<USAGE
Usage: bugbot.sh <subcommand> [flags]

Subcommands:
  check-run-status  --owner <o> --repo <r> --sha <sha>
                    Returns compact JSON describing the Cursor Bugbot
                    check-run for the given commit SHA.
USAGE
    [[ -z "$CMD" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Unknown subcommand: $CMD" >&2
    echo "Run 'bugbot.sh help' for usage." >&2
    exit 1
    ;;
esac
