#!/usr/bin/env bash
# fetch-run-report.sh: download a task's newest agent-run-report attachment to a
# gid-unique path, so parallel evaluators never read each other's report.
#
# Usage: fetch-run-report.sh <task-gid> [--nth N]   # N=1 newest (default), 2 the one before
# Output (stdout, one line): <path>\t<attachment-gid>\t<created_at>\t<name>
#   path is /tmp/eval-<gid>/report-<attachment-gid>.md (written via temp file + rename)
# Exit: 0 = ok, 1 = error or identity mismatch (attachment parent != task), 2 = usage,
#       3 = the task has no report attachment.
#
# Identity: the attachment's parent.gid must equal <task-gid>, a frontmatter task_gid
# (when present) must too, and the download URL comes from that attachment record.
# Read-only. Reads the Asana token internally; never prints it.
set -euo pipefail
source "$HOME/.config/agent-watcher/lib/attach-names.sh" 2>/dev/null || REPORT_ATTACH_RE='^([0-9]+-)?agent-run-report.*\.md$'
CRED="$HOME/.config/agent-watcher/credentials.json"

GID="" NTH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --nth) NTH="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *) [ -z "$GID" ] && GID="$1" && shift || { echo "usage: fetch-run-report.sh <task-gid> [--nth N]" >&2; exit 2; } ;;
  esac
done
case "$GID" in (''|*[!0-9]*) echo "usage: fetch-run-report.sh <task-gid> [--nth N]" >&2; exit 2 ;; esac
case "$NTH" in (''|*[!0-9]*|0) echo "fetch-run-report: --nth must be a positive integer" >&2; exit 2 ;; esac

token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)}"
[ -n "$token" ] || { echo "fetch-run-report: no Asana token" >&2; exit 1; }
api() { curl -sf --max-time 30 -H "Authorization: Bearer $token" "https://app.asana.com/api/1.0/$1"; }

list=$(api "tasks/$GID/attachments?opt_fields=name,created_at") || { echo "fetch-run-report: attachment list failed for $GID" >&2; exit 1; }
att=$(echo "$list" | jq -r --arg re "$REPORT_ATTACH_RE" --argjson n "$NTH" '
  [.data[]? | select((.name // "") | test($re))] | sort_by(.created_at) | reverse | .[$n-1].gid // empty')
[ -n "$att" ] || { echo "fetch-run-report: task $GID has no report attachment #$NTH" >&2; exit 3; }

rec=$(api "attachments/$att?opt_fields=name,created_at,download_url,parent.gid") || { echo "fetch-run-report: attachment $att fetch failed" >&2; exit 1; }
parent=$(echo "$rec" | jq -r '.data.parent.gid // empty')
[ "$parent" = "$GID" ] || { echo "fetch-run-report: attachment $att belongs to '$parent', not $GID" >&2; exit 1; }
url=$(echo "$rec" | jq -r '.data.download_url // empty')
[ -n "$url" ] || { echo "fetch-run-report: attachment $att has no download_url" >&2; exit 1; }

dir="/tmp/eval-$GID"; mkdir -p "$dir"
tmp=$(mktemp "$dir/report.XXXXXX")
curl -sf --max-time 60 -o "$tmp" "$url" || { rm -f "$tmp"; echo "fetch-run-report: download failed for $att" >&2; exit 1; }
# A report that names its task in frontmatter must name this one.
fm=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} /^task_gid:/{gsub(/[" ]/,"",$2); print $2; exit}' FS=':' "$tmp")
[ -z "$fm" ] || [ "$fm" = "$GID" ] || { rm -f "$tmp"; echo "fetch-run-report: report $att frontmatter task_gid '$fm' != $GID" >&2; exit 1; }
out="$dir/report-$att.md"; mv -f "$tmp" "$out"
printf '%s\t%s\t%s\t%s\n' "$out" "$att" "$(echo "$rec" | jq -r '.data.created_at')" "$(echo "$rec" | jq -r '.data.name')"
