#!/usr/bin/env bash
# Read-only query helper for Edge's self-hosted Sentry.
#
# Auth: reads a bearer token from a file (default ~/.config/sentry-edge-token,
# override with SENTRY_TOKEN_FILE). The token is passed to curl through a
# mode-600 temp config file, never through argv or the environment, so it does
# not appear in `ps`, shell history, or agent transcripts. The token file lives
# outside ~/.cursor on purpose: convention-sync only syncs ~/.cursor, so the
# secret can never reach the edge-dev-agents repo.
#
# Every subcommand is read-only. This script has no write path by design; the
# token it expects carries only event:read / org:read / project:read.
set -euo pipefail

SENTRY_HOST="${SENTRY_HOST:-https://sentry.edge.app}"
SENTRY_ORG="${SENTRY_ORG:-edge}"
SENTRY_PROJECT="${SENTRY_PROJECT:-edge-react-gui}"
TOKEN_FILE="${SENTRY_TOKEN_FILE:-$HOME/.config/sentry-edge-token}"

CURL_CONFIG=""
# Must not fail: a non-zero last command in an EXIT trap under `set -e`
# replaces the script's real exit code (masking the 2 that means "needs setup").
cleanup() {
  if [ -n "$CURL_CONFIG" ]; then rm -f "$CURL_CONFIG"; fi
  return 0
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

need_token() {
  if [ ! -s "$TOKEN_FILE" ]; then
    cat >&2 <<EOF
NEEDS_SETUP: no Sentry token at $TOKEN_FILE

Create one at $SENTRY_HOST/settings/account/api/auth-tokens/ with scopes
event:read, org:read, project:read, then:

  printf '%s' 'PASTE_TOKEN_HERE' > $TOKEN_FILE && chmod 600 $TOKEN_FILE

Never paste the token into chat, a script argument, or a committed file.
EOF
    exit 2
  fi
  CURL_CONFIG="$(mktemp)"
  chmod 600 "$CURL_CONFIG"
  printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' < "$TOKEN_FILE")" > "$CURL_CONFIG"
}

api() {
  local path="$1" out code
  out="$(mktemp)"
  code="$(curl -sS --max-time 60 -K "$CURL_CONFIG" -o "$out" -w '%{http_code}' "$SENTRY_HOST/api/0$path")"
  if [ "$code" != "200" ]; then
    rm -f "$out"
    case "$code" in
      401|403) die "Sentry returned $code for $path (token invalid, expired, or missing a scope)" ;;
      404) die "Sentry returned 404 for $path (wrong issue id, org, or project)" ;;
      *) die "Sentry returned $code for $path" ;;
    esac
  fi
  cat "$out"
  rm -f "$out"
}

# Accepts a bare id or any Sentry issue URL and echoes the numeric issue id.
issue_id() {
  local raw="$1" id
  id="$(printf '%s' "$raw" | sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p')"
  [ -z "$id" ] && id="$(printf '%s' "$raw" | grep -o '^[0-9][0-9]*$' || true)"
  [ -z "$id" ] && die "could not read an issue id from: $raw"
  printf '%s' "$id"
}

usage() {
  cat <<'EOF'
Usage: sentry-query.sh <subcommand> [args]

  issue  <id|url>                       one-screen issue summary
  tags   <id|url> [key ...]             tag value distributions
                                        (default: os device.family release environment)
  events <id|url> [--limit N] [--field PATH ...]
                                        distribution of a dotted field across an
                                        event sample, plus seconds-after-app-start
                                        percentiles (default field:
                                        contexts.app.in_foreground; default limit 100)
  event  <id|url> [--index N]           one full event: contexts, tags, frames, breadcrumbs
  search "<query>"                      list matching issues in the project

Env: SENTRY_HOST SENTRY_ORG SENTRY_PROJECT SENTRY_TOKEN_FILE
Exit: 0 ok | 1 error | 2 token setup needed
EOF
}

cmd_issue() {
  local id; id="$(issue_id "$1")"
  local body; body="$(api "/organizations/$SENTRY_ORG/issues/$id/")"
  printf '%s' "$body" | python3 -c '
import json,sys
d=json.load(sys.stdin)
def rel(k):
    v=d.get(k) or {}
    return v.get("version","-")
print("SHORT_ID:   ", d.get("shortId"))
print("TITLE:      ", d.get("title"))
print("CULPRIT:    ", d.get("culprit"))
print("STATUS:     ", d.get("status"), "| level:", d.get("level"), "| unhandled:", d.get("isUnhandled"))
print("EVENTS:     ", d.get("count"), "| users:", d.get("userCount"))
print("FIRST_SEEN: ", d.get("firstSeen"), "in", rel("firstRelease"))
print("LAST_SEEN:  ", d.get("lastSeen"), "in", rel("lastRelease"))
print("PROJECT:    ", (d.get("project") or {}).get("slug"))
print("PERMALINK:  ", d.get("permalink"))
'
}

cmd_tags() {
  local id; id="$(issue_id "$1")"; shift
  local keys=("$@")
  [ ${#keys[@]} -eq 0 ] && keys=(os device.family release environment)
  local k
  for k in "${keys[@]}"; do
    echo "=== $k ==="
    local body; body="$(api "/organizations/$SENTRY_ORG/issues/$id/tags/$k/")"
    printf '%s' "$body" | python3 -c '
import json,sys
d=json.load(sys.stdin)
t=d.get("totalValues") or 0
print("  total:",t,"| unique:",d.get("uniqueValues"))
for v in (d.get("topValues") or [])[:15]:
    c=v.get("count",0); pct=100.0*c/t if t else 0.0
    print("  %-44s %7d  %5.1f%%" % (str(v.get("value"))[:44], c, pct))
'
  done
}

cmd_events() {
  local id; id="$(issue_id "$1")"; shift
  local limit=100 fields=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --field) fields+=("$2"); shift 2 ;;
      *) die "unknown flag for events: $1" ;;
    esac
  done
  [ ${#fields[@]} -eq 0 ] && fields=(contexts.app.in_foreground)
  local body; body="$(api "/organizations/$SENTRY_ORG/issues/$id/events/?full=true&per_page=$limit")"
  printf '%s' "$body" \
    | FIELDS="$(printf '%s\n' "${fields[@]}")" python3 -c '
import json,os,sys,datetime
evts=json.load(sys.stdin)
fields=[f for f in os.environ["FIELDS"].split("\n") if f]
print("SAMPLE:", len(evts), "events (most recent first)")
def dig(e,path):
    cur=e
    for part in path.split("."):
        if isinstance(cur,list):
            cur={t.get("key"):t.get("value") for t in cur if isinstance(t,dict)}
        if not isinstance(cur,dict): return "<missing>"
        if part not in cur: return "<missing>"
        cur=cur[part]
    return cur
for f in fields:
    counts={}
    for e in evts:
        counts[repr(dig(e,f))]=counts.get(repr(dig(e,f)),0)+1
    n=sum(counts.values()) or 1
    print("=== %s ===" % f)
    for val,c in sorted(counts.items(), key=lambda kv:-kv[1])[:15]:
        print("  %-44s %7d  %5.1f%%" % (val[:44], c, 100.0*c/n))
ds=[]
for e in evts:
    app=((e.get("contexts") or {}).get("app") or {})
    st, dc = app.get("app_start_time"), e.get("dateCreated")
    if st and dc:
        try:
            ds.append((datetime.datetime.fromisoformat(dc.replace("Z","+00:00"))
                     - datetime.datetime.fromisoformat(st.replace("Z","+00:00"))).total_seconds())
        except Exception: pass
if ds:
    ds.sort(); n=len(ds)
    print("=== seconds after app_start_time ===")
    print("  n=%d min=%.2f p50=%.2f p90=%.2f max=%.2f"
          % (n, ds[0], ds[n//2], ds[min(int(n*0.9), n-1)], ds[-1]))
'
}

cmd_event() {
  local id; id="$(issue_id "$1")"; shift
  local index=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --index) index="$2"; shift 2 ;;
      *) die "unknown flag for event: $1" ;;
    esac
  done
  local body; body="$(api "/organizations/$SENTRY_ORG/issues/$id/events/?full=true&per_page=$((index + 1))")"
  printf '%s' "$body" \
    | INDEX="$index" python3 -c '
import json,os,sys
evts=json.load(sys.stdin); i=int(os.environ["INDEX"])
if i >= len(evts):
    print("ERROR: only %d events available" % len(evts), file=sys.stderr); sys.exit(1)
e=evts[i]
print("EVENT:", e.get("eventID"), "|", e.get("dateCreated"))
print("TITLE:", e.get("title"))
ctx=e.get("contexts") or {}
for name in ("app","device","os","react_native_context"):
    c=ctx.get(name)
    if isinstance(c,dict):
        keep={k:v for k,v in c.items() if k!="type" and v not in (None,"")}
        print("=== context.%s ===" % name)
        for k,v in list(keep.items())[:16]: print("  %-24s %s" % (k, str(v)[:80]))
print("=== tags ===")
for t in e.get("tags") or []:
    print("  %-24s %s" % (t.get("key"), str(t.get("value"))[:80]))
for entry in e.get("entries") or []:
    et=entry.get("type")
    if et=="exception":
        print("=== exception ===")
        for v in (entry["data"].get("values") or [])[:3]:
            print("  %s: %s" % (v.get("type"), str(v.get("value"))[:200]))
            frames=((v.get("stacktrace") or {}).get("frames") or [])[-8:]
            for f in frames:
                print("    %s %s:%s" % (f.get("function"), f.get("filename"), f.get("lineNo")))
    if et=="breadcrumbs":
        vs=entry["data"].get("values") or []
        print("=== breadcrumbs (last 10 of %d) ===" % len(vs))
        for b in vs[-10:]:
            print("  %s %s/%s %s" % (b.get("timestamp"), b.get("category"),
                                     b.get("type"), str(b.get("message"))[:90]))
'
}

cmd_search() {
  [ $# -eq 0 ] && die "search needs a query, e.g. \"is:unresolved ExpoQuickActions\""
  local q; q="$(printf '%s' "$1" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
  local body; body="$(api "/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=$q&per_page=25")"
  printf '%s' "$body" | python3 -c '
import json,sys
for d in json.load(sys.stdin):
    print("%-22s %7s ev %6s users  %s" % (d.get("shortId"), d.get("count"),
          d.get("userCount"), str(d.get("title"))[:70]))
    print("  id=%s  lastSeen=%s" % (d.get("id"), d.get("lastSeen")))
'
}

[ $# -eq 0 ] && { usage; exit 1; }
SUB="$1"; shift
case "$SUB" in
  issue|tags|events|event|search) need_token; "cmd_$SUB" "$@" ;;
  -h|--help|help) usage ;;
  *) usage; die "unknown subcommand: $SUB" ;;
esac
