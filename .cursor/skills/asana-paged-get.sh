#!/usr/bin/env bash
# asana-paged-get.sh
# Read every page of an Asana collection and print it as one response.
#
# Usage:
#   asana-paged-get.sh <path-and-query>
#     e.g. asana-paged-get.sh "tasks/<gid>/stories?opt_fields=text&limit=100"
#
# The query must carry a limit: Asana only pages a request that sets one.
#
# Requires env var: ASANA_TOKEN
#
# Output: {"data":[...]} holding the rows of every page, in the order the API
#         returned them.
# Exit: 0 = ok, 1 = a request failed or the collection ran past
#       ASANA_MAX_PAGES pages (default 50), 2 = usage.
set -euo pipefail

[[ $# -eq 1 && -n "$1" ]] || { echo "usage: asana-paged-get.sh <path-and-query>" >&2; exit 2; }
[[ -n "${ASANA_TOKEN:-}" ]] || { echo "Error: ASANA_TOKEN not set" >&2; exit 1; }
API="https://app.asana.com/api/1.0"
URL="$API/${1#/}"
[[ "$URL" == *\?* ]] && SEP="&" || SEP="?"
MAX="${ASANA_MAX_PAGES:-50}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/asana-pages.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
OFFSET=""
I=0
while :; do
  I=$((I + 1))
  PAGE=$(printf '%s/p%04d.json' "$TMP" "$I")
  curl -sf --max-time 30 -H "Authorization: Bearer $ASANA_TOKEN" \
    "$URL${OFFSET:+${SEP}offset=$OFFSET}" > "$PAGE" \
    || { echo "Error: request failed on page $I of $1" >&2; exit 1; }
  OFFSET=$(jq -r '.next_page.offset // empty' "$PAGE")
  [[ -n "$OFFSET" ]] || break
  [[ "$I" -lt "$MAX" ]] || { echo "Error: more than $MAX pages for $1" >&2; exit 1; }
done
jq -cs '{data: [.[].data[]]}' "$TMP"/p*.json
