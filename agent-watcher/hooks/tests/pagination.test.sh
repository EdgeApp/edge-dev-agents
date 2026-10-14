#!/usr/bin/env bash
# pagination.test.sh: The reads that must follow pagination to the last page:
# asana-paged-get.sh (the shared Asana page loop), its two callers
# (asana-get-context.sh and one-shot's asana-on-complete-actions.sh), and the
# review-thread read in pr-land-comments.sh.
#
# Nothing reaches the network: curl and gh are shims on PATH that answer from
# files and log their arguments.
set -uo pipefail

SKILLS="$HOME/.cursor/skills"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pagination-test.XXXXXX")
GID=990000000017
trap 'rm -rf "$TMP" "/tmp/asana-task-$GID"' EXIT
mkdir -p "$TMP/bin" "$TMP/api"
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}

# Fake curl: the URL is the argument that starts with https. A stories URL is
# answered from stories-<offset>.json (stories-first.json with no offset); the
# other endpoints get a fixed minimal answer.
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
URL=""
for A in "$@"; do [[ "$A" == https://* ]] && URL="$A"; done
echo "$URL" >> "$FAKE_API/log"
case "$URL" in
  */stories\?*)
    OFF=first
    [[ "$URL" == *"offset="* ]] && OFF="${URL##*offset=}"
    [[ -f "$FAKE_API/stories-$OFF.json" ]] || exit 22
    cat "$FAKE_API/stories-$OFF.json" ;;
  */users/me*) echo '{"data":{"gid":"1"}}' ;;
  */subtasks*|*/attachments*) echo '{"data":[]}' ;;
  */tasks/*) cat "$FAKE_API/task.json" ;;
  *) exit 22 ;;
esac
SH
chmod +x "$TMP/bin/curl"
export FAKE_API="$TMP/api" ASANA_TOKEN=test-token
PATH="$TMP/bin:$PATH"

story() { # story <text> -> one comment story
  jq -cn --arg t "$1" '{resource_subtype:"comment_added",text:$t,created_at:"2026-01-01T00:00:00.000Z",created_by:{gid:"2",name:"Someone"}}'
}
pages() { # three pages: two full of filler, the newest comment on the last
  jq -cn --argjson s "$(story "$1")" '{data:[$s],next_page:{offset:"p2"}}' > "$FAKE_API/stories-first.json"
  jq -cn --argjson s "$(story "$2")" '{data:[$s],next_page:{offset:"p3"}}' > "$FAKE_API/stories-p2.json"
  jq -cn --argjson s "$(story "$3")" '{data:[$s],next_page:null}' > "$FAKE_API/stories-p3.json"
  : > "$FAKE_API/log"
}

# ── asana-paged-get.sh ────────────────────────────────────────────────────────
pages one two three
OUT=$("$SKILLS/asana-paged-get.sh" "tasks/$GID/stories?opt_fields=text&limit=100")
check "paged get: exit 0 over three pages" "$?" 0
check "paged get: every page's rows, in order" "$(jq -r '[.data[].text] | join(",")' <<<"$OUT")" "one,two,three"
check "paged get: one request per page" "$(wc -l < "$FAKE_API/log" | tr -d ' ')" 3
check "paged get: the offset rides the second request" "$(sed -n 2p "$FAKE_API/log" | grep -c 'limit=100&offset=p2$')" 1

rm "$FAKE_API/stories-p3.json"
"$SKILLS/asana-paged-get.sh" "tasks/$GID/stories?limit=100" > "$TMP/out" 2> "$TMP/err"
check "paged get: a failed page is exit 1" "$?" 1
check "paged get: a failed page prints nothing" "$(wc -c < "$TMP/out" | tr -d ' ')" 0

pages one two three
ASANA_MAX_PAGES=2 "$SKILLS/asana-paged-get.sh" "tasks/$GID/stories?limit=100" > "$TMP/out" 2> "$TMP/err"
check "paged get: past the page cap is exit 1" "$?" 1
check "paged get: the cap is named" "$(grep -c 'more than 2 pages' "$TMP/err")" 1

"$SKILLS/asana-paged-get.sh" > /dev/null 2>&1
check "paged get: no argument is exit 2" "$?" 2

# ── asana-on-complete-actions.sh: a marker on the last page counts ───────────
ID=$(node -e 'console.log(require("crypto").createHash("sha1").update("post the build link").digest("hex").slice(0, 8))')
jq -cn '{data:{custom_fields:[{name:"agent_on_complete",resource_subtype:"text",text_value:"- Post the build link"}]}}' > "$FAKE_API/task.json"
pages "filler" "filler" "ON COMPLETE $ID=done"
OUT=$("$SKILLS/one-shot/scripts/asana-on-complete-actions.sh" --task "$GID")
check "on-complete: exit 0" "$?" 0
check "on-complete: the marker on page three sets the state" "$(jq -r '.actions[0].state' <<<"$OUT")" done
pages "ON COMPLETE $ID=done" "filler" "filler"
rm "$FAKE_API/stories-p2.json" "$FAKE_API/stories-p3.json"
jq -c '.next_page = null' "$FAKE_API/stories-first.json" > "$TMP/one" && mv "$TMP/one" "$FAKE_API/stories-first.json"
OUT=$("$SKILLS/one-shot/scripts/asana-on-complete-actions.sh" --task "$GID")
check "on-complete: a one-page thread still reads" "$(jq -r '.actions[0].state' <<<"$OUT")" done

# ── asana-get-context.sh: a comment on the last page is in the thread ────────
jq -cn '{data:{name:"A task",notes:"Body.",num_subtasks:0,created_at:"2026-01-01T00:00:00.000Z",created_by:{gid:"2",name:"Someone"},custom_fields:[]}}' > "$FAKE_API/task.json"
pages "first comment" "second comment" "newest comment zq41"
OUT=$("$SKILLS/asana-get-context.sh" "$GID" 2> "$TMP/err")
check "get-context: exit 0" "$?" 0
check "get-context: three comments counted" "$(grep -c '^COMMENTS: 3' <<<"$OUT")" 1
check "get-context: the last page's comment is inline" "$(grep -c 'newest comment zq41' <<<"$OUT")" 1

# ── pr-land-comments.sh: review threads past the first page ───────────────────
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_API/gh-log"
[[ "$1 $2" == "auth status" ]] && exit 0
[[ "$1 $2" == "api user" ]] && { echo me; exit 0; }
if [[ "$1 $2" == "api graphql" ]]; then
  for A in "$@"; do [[ "$A" == threadsAfter=* ]] && { cat "$FAKE_API/threads-${A#threadsAfter=}.json"; exit 0; }; done
  cat "$FAKE_API/threads-first.json"; exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/gh"
thread() { # thread <id> <typename> <login>
  jq -cn --arg id "$1" --arg ty "$2" --arg lg "$3" '{id:$id,isResolved:false,comments:{nodes:[{databaseId:1,createdAt:"2026-01-01T00:00:00Z",author:{__typename:$ty,login:$lg},path:"a.ts",body:"text"}]}}'
}
prpage() { # prpage <threads json> <hasNextPage> <cursor>
  jq -cn --argjson th "$1" --argjson more "$2" --arg cur "$3" '{data:{repository:{pullRequest:{
    author:{__typename:"User",login:"me"},
    commits:{nodes:[{commit:{committedDate:"2026-02-01T00:00:00Z"}}]},
    reviewThreads:{pageInfo:{hasNextPage:$more,endCursor:$cur},nodes:$th},
    reviews:{nodes:[]},comments:{nodes:[]}}}}}'
}
prpage "[]" true c1 > "$FAKE_API/threads-first.json"
prpage "[$(thread T-human User a-reviewer)]" true c2 > "$FAKE_API/threads-c1.json"
prpage "[$(thread T-bot Bot a-bot)]" false "" > "$FAKE_API/threads-c2.json"
: > "$FAKE_API/gh-log"
OUT=$(echo '[{"repo":"widget","prNumber":7,"branch":"b"}]' | node "$SKILLS/pr-land/scripts/pr-land-comments.sh" 2> "$TMP/err")
check "land comments: exit 0" "$?" 0
check "land comments: the bot thread on page three blocks" "$(jq -r '.[0].botThreads[0].threadId' <<<"$OUT")" T-bot
check "land comments: three thread pages asked for" "$(grep -c '^api graphql' "$FAKE_API/gh-log")" 3
prpage "[]" false "" > "$FAKE_API/threads-first.json"
: > "$FAKE_API/gh-log"
OUT=$(echo '[{"repo":"widget","prNumber":7,"branch":"b"}]' | node "$SKILLS/pr-land/scripts/pr-land-comments.sh" 2> "$TMP/err")
check "land comments: one page is one call and no finding" "$(grep -c '^api graphql' "$FAKE_API/gh-log") $(jq -r 'length' <<<"$OUT")" "1 0"

echo "$FAILS failed"
[[ $FAILS -eq 0 ]]
