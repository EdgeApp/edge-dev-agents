#!/usr/bin/env bash
# land-arming.test.sh: arming the automatic merge, and watching it to merged.
#
#   pr-land-automerge.sh  arms only when no reviewer bot is still running and
#                         no reviewer-bot thread is open, never arms a PR with
#                         changes requested, reports a repo that disallows
#                         auto-merge, disarms, and gives one result line and
#                         the documented exit code per case.
#   pr-merge-watch.sh     reports ALL_MERGED only when GitHub says MERGED; an
#                         armed, still-open PR is never a success. A red check,
#                         a branch that needs a rebase and a missing review
#                         each end with their own verdict and exit code. A
#                         reviewer-bot thread that opens while the PR is armed
#                         disarms it and ends with BOT_THREADS.
#
# Runs the real scripts with a stand-in for the GitHub command on the PATH and
# a stand-in for the review-comment check in a private HOME, so nothing reaches
# the network. Each fake PR is a folder of canned GitHub answers.
set -uo pipefail

REAL="$HOME/.cursor/skills"
REAL_LIB="$HOME/.config/agent-watcher/lib/reviewer-bots.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/land-arming-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
TAG="armtest$$"
trap 'rm -rf "$TMP"; rm -f /tmp/pr-merge-watch-deadline-*"$TAG"* /tmp/pr-merge-watch-*"$TAG"*.result' EXIT
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
has() { # has <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1: '$3' not in '$2'"; fi
}

FH="$TMP/home"
SK="$FH/.cursor/skills/pr-land/scripts"
FAKE="$TMP/fake"
mkdir -p "$SK" "$FH/.config/agent-watcher/lib" "$TMP/bin" "$TMP/state" "$FAKE"
cp "$REAL/pr-land/scripts/pr-land-automerge.sh" "$REAL/pr-land/scripts/pr-merge-watch.sh" \
   "$REAL/pr-land/scripts/repo-land-lock.sh" "$REAL/pr-land/scripts/bot-thread-count.sh" "$SK/"
cp "$REAL_LIB" "$FH/.config/agent-watcher/lib/"

# Stand-in for the review-comment check: FAKE/<num>/threads holds the number of
# open reviewer-bot threads, or the word "fail" for a check that cannot run.
cat > "$SK/pr-land-comments.sh" <<'SH'
#!/usr/bin/env bash
NUM=$(jq -r '.[0].prNumber')
T=$(cat "$FAKE/$NUM/threads" 2>/dev/null || echo 0)
[[ "$T" == fail ]] && exit 1
jq -nc --argjson n "$T" '[{botThreads: [range(0; $n)]}]'
SH

# Stand-in for the GitHub command. Every call is logged. FAKE/<num>/ holds:
#   view.json     answer to "pr view" (absent = the call fails); view.json.2,
#                 view.json.3 ... answer the second and later calls
#   checks.json   answer to "pr checks" (absent = no checks)
#   merge.err     "pr merge --auto" fails with this message
#   disarm.err    "pr merge --disable-auto" fails with this message
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/gh.log"
[[ "$1" == pr ]] || exit 1
D="$FAKE/$3"
case "$2" in
  view)
    N=$(( $(cat "$D/view.count" 2>/dev/null || echo 0) + 1 )); echo "$N" > "$D/view.count" 2>/dev/null
    while [[ "$N" -gt 1 && ! -f "$D/view.json.$N" ]]; do N=$((N - 1)); done
    F="$D/view.json"; [[ "$N" -gt 1 ]] && F="$D/view.json.$N"
    [[ -f "$F" ]] || exit 1
    cat "$F" ;;
  checks) cat "$D/checks.json" 2>/dev/null || echo '[]' ;;
  merge)
    case "$*" in
      *--disable-auto*) E="$D/disarm.err" ;;
      *) E="$D/merge.err" ;;
    esac
    if [[ -f "$E" ]]; then cat "$E" >&2; exit 1; fi ;;
esac
exit 0
SH
chmod +x "$SK"/*.sh "$TMP/bin/gh"
unset AGENT_SESSION_UUID

# pr <num> <view json> [checks json] [threads]
pr() {
  mkdir -p "$FAKE/$1"
  printf '%s\n' "$2" > "$FAKE/$1/view.json"
  [[ -n "${3:-}" ]] && printf '%s\n' "$3" > "$FAKE/$1/checks.json"
  [[ -n "${4:-}" ]] && printf '%s\n' "$4" > "$FAKE/$1/threads"
  return 0
}
# arm <json> [flags...]: sets OUT and RC.
arm() {
  local IN="$1"; shift
  : > "$FAKE/gh.log"
  OUT=$(printf '%s' "$IN" | HOME="$FH" XDG_STATE_HOME="$TMP/state" FAKE="$FAKE" PATH="$TMP/bin:$PATH" \
    "$SK/pr-land-automerge.sh" "$@" 2>"$TMP/arm.err")
  RC=$?
}
one() { echo "[{\"repo\":\"${2:-$TAG}\",\"prNumber\":$1}]"; }
armed_calls() { /usr/bin/grep -c -- '--auto --merge' "$FAKE/gh.log"; }
OPEN='{"state":"OPEN","reviewDecision":"APPROVED","mergeStateStatus":"BLOCKED"}'

# --- pr-land-automerge.sh ---
pr 1 "$OPEN"
arm "$(one 1)"
check "a clean PR is armed: exit code" "$RC" 0
has "a clean PR is armed: result line" "$OUT" "armed   EdgeApp/$TAG#1"
has "arming uses the merge-commit method" "$(cat "$FAKE/gh.log")" "pr merge 1 --repo EdgeApp/$TAG --auto --merge"
check "the land lock is released after arming" "$(ls "$TMP/state/agent-watcher/land-locks" 2>/dev/null | wc -l | tr -d ' ')" 0

pr 2 '{"state":"MERGED","reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN"}'
arm "$(one 2)"
check "an already merged PR: exit code" "$RC" 0
has "an already merged PR: result line" "$OUT" "merged  EdgeApp/$TAG#2"
check "an already merged PR is not armed" "$(armed_calls)" 0

pr 3 '{"state":"OPEN","reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"BLOCKED"}'
arm "$(one 3)"
check "changes requested: exit code" "$RC" 1
has "changes requested: result line" "$OUT" "blocked EdgeApp/$TAG#3"
check "changes requested is not armed" "$(armed_calls)" 0

pr 4 "$OPEN" '[{"name":"Cursor Bugbot","bucket":"pending"},{"name":"build","bucket":"pending"}]'
arm "$(one 4)"
check "a running reviewer bot: exit code" "$RC" 76
has "a running reviewer bot: result line" "$OUT" "waiting EdgeApp/$TAG#4"
has "the waiting line names the bot" "$OUT" "Cursor Bugbot"
check "a running reviewer bot is not armed" "$(armed_calls)" 0
arm "$(one 4)" --no-bugbot-wait
check "the no-wait flag arms past a running bot: exit code" "$RC" 0
has "the no-wait flag arms past a running bot: result line" "$OUT" "armed   EdgeApp/$TAG#4"

pr 5 "$OPEN" '[{"name":"build","bucket":"pending"},{"name":"Cursor Bugbot","bucket":"skipping"}]'
arm "$(one 5)"
check "pending CI and a skipped bot do not hold arming" "$RC" 0
has "pending CI and a skipped bot: result line" "$OUT" "armed   EdgeApp/$TAG#5"

pr 6 "$OPEN" '' 2
arm "$(one 6)"
check "open reviewer-bot threads: exit code" "$RC" 1
has "open reviewer-bot threads: result line" "$OUT" "blocked EdgeApp/$TAG#6"
has "the blocked line gives the thread count" "$OUT" "2 unresolved"
check "open reviewer-bot threads are not armed" "$(armed_calls)" 0
arm "$(one 6)" --no-bugbot-wait
check "the no-wait flag does not arm past open bot threads" "$RC" 1
check "open bot threads with the no-wait flag are not armed" "$(armed_calls)" 0

pr 7 "$OPEN" '' fail
arm "$(one 7)"
check "an unreadable comment check: exit code" "$RC" 1
has "an unreadable comment check: result line" "$OUT" "error   EdgeApp/$TAG#7"
check "an unreadable comment check is not armed" "$(armed_calls)" 0

pr 8 "$OPEN"; echo "GraphQL: Auto merge is not allowed for this repository" > "$FAKE/8/merge.err"
arm "$(one 8)"
check "a repo without auto-merge: exit code" "$RC" 1
has "a repo without auto-merge: result line" "$OUT" "unsupported EdgeApp/$TAG#8"

pr 9 "$OPEN"; echo "Pull request is already merged" > "$FAKE/9/merge.err"
arm "$(one 9)"
check "merged between the read and the arm: exit code" "$RC" 0
has "merged between the read and the arm: result line" "$OUT" "merged  EdgeApp/$TAG#9"

pr 10 "$OPEN"; echo "HTTP 502: bad gateway" > "$FAKE/10/merge.err"
arm "$(one 10)"
check "an unknown arm failure: exit code" "$RC" 1
has "an unknown arm failure: result line" "$OUT" "error   EdgeApp/$TAG#10"

mkdir -p "$FAKE/11"
arm "$(one 11)"
check "an unreadable PR: exit code" "$RC" 1
has "an unreadable PR: result line" "$OUT" "error   EdgeApp/$TAG#11"

arm "$(one 1 "other-org/$TAG")"
has "an owner in the repo field is kept" "$OUT" "armed   other-org/$TAG#1"

# several PRs in one call: the worst result decides the exit code
arm "[{\"repo\":\"$TAG\",\"prNumber\":1},{\"repo\":\"$TAG\",\"prNumber\":4}]"
check "armed plus waiting exits 76" "$RC" 76
check "the clean PR in a mixed call is still armed" "$(armed_calls)" 1
arm "[{\"repo\":\"$TAG\",\"prNumber\":4},{\"repo\":\"$TAG\",\"prNumber\":3},{\"repo\":\"$TAG\",\"prNumber\":1}]"
check "waiting plus blocked exits 1" "$RC" 1
check "every PR in a mixed call gets a result line" \
  "$(printf '%s\n' "$OUT" | /usr/bin/grep -cE '^(armed|waiting|blocked) ')" 3

# disarm
arm "$(one 1)" --disarm
check "disarm: exit code" "$RC" 0
has "disarm: result line" "$OUT" "disarmed EdgeApp/$TAG#1"
has "disarm turns auto-merge off" "$(cat "$FAKE/gh.log")" "--disable-auto"
check "disarm never arms" "$(armed_calls)" 0
pr 12 "$OPEN"; echo "Auto merge is not enabled for this pull request" > "$FAKE/12/disarm.err"
arm "$(one 12)" --disarm
check "disarming a PR that was never armed succeeds" "$RC" 0
pr 13 "$OPEN"; echo "HTTP 502: bad gateway" > "$FAKE/13/disarm.err"
arm "$(one 13)" --disarm
check "a failed disarm: exit code" "$RC" 1
has "a failed disarm: result line" "$OUT" "error   EdgeApp/$TAG#13"
arm "$(one 2)" --disarm
has "disarm of a merged PR reports merged" "$OUT" "merged  EdgeApp/$TAG#2"

# the land lock and the usage exits
XDG_STATE_HOME="$TMP/state" "$SK/repo-land-lock.sh" acquire --repo "$TAG" --owner someone-else >/dev/null 2>&1
arm "$(one 1)"
check "a busy land lock: exit code" "$RC" 75
check "a busy land lock arms nothing" "$(armed_calls)" 0
check "a busy land lock keeps the other owner's lease" \
  "$(jq -r .owner "$TMP/state/agent-watcher/land-locks/$TAG.json" 2>/dev/null)" someone-else
XDG_STATE_HOME="$TMP/state" "$SK/repo-land-lock.sh" release --repo "$TAG" --owner someone-else >/dev/null 2>&1
arm "" ; check "empty input is a usage error" "$RC" 2
arm "$(one 1)" --bogus; check "an unknown flag is a usage error" "$RC" 2

# --- pr-merge-watch.sh ---
# watch <pr number> [flags...]: sets OUT (the last line) and RESULT.
watch() {
  local NUM="$1"; shift
  rm -f "$FAKE/$NUM/view.count" "$TMP/watch.result"
  OUT=$(HOME="$FH" XDG_STATE_HOME="$TMP/state" FAKE="$FAKE" PATH="$TMP/bin:$PATH" MAX_CALL="${MAX_CALL:-30}" \
    "$SK/pr-merge-watch.sh" "$TAG#$NUM" --interval 0 --result-file "$TMP/watch.result" "$@" 2>"$TMP/watch.err" | tail -1)
  RESULT=$(cat "$TMP/watch.result" 2>/dev/null)
  rm -f /tmp/pr-merge-watch-deadline-*"$TAG"*
}
# watch_rc: the pipeline in watch hides the script's exit code, so read it from
# a direct run.
watch_rc() {
  local NUM="$1"; shift
  rm -f "$FAKE/$NUM/view.count"
  HOME="$FH" XDG_STATE_HOME="$TMP/state" FAKE="$FAKE" PATH="$TMP/bin:$PATH" MAX_CALL="${MAX_CALL:-30}" \
    "$SK/pr-merge-watch.sh" "$TAG#$NUM" --interval 0 --result-file "$TMP/watch.result" "$@" >/dev/null 2>&1
  RC=$?
  rm -f /tmp/pr-merge-watch-deadline-*"$TAG"*
}
view() { # view <state> <mergeState> <review> <checks json>
  echo "{\"state\":\"$1\",\"mergeStateStatus\":\"$2\",\"reviewDecision\":\"$3\",\"statusCheckRollup\":$4,\"mergeCommit\":${5:-null}}"
}
GREEN='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'
RUNNING='[{"name":"build","status":"IN_PROGRESS","conclusion":null}]'
RED='[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'

pr 20 "$(view MERGED UNKNOWN APPROVED "$GREEN" '{"oid":"abc123"}')"
watch 20; watch_rc 20
check "a merged PR: exit code" "$RC" 0
check "a merged PR: verdict with the merge commit" "$OUT" "ALL_MERGED $TAG#20=abc123"
check "the verdict is written to the result file" "$RESULT" "$OUT"

# armed and open with checks still running is never a success
pr 21 "$(view OPEN BLOCKED APPROVED "$RUNNING")"
watch 21 --timeout 0; watch_rc 21 --timeout 0
check "an armed, open PR at the deadline: exit code" "$RC" 5
check "an armed, open PR at the deadline: verdict" "$OUT" "TIMEOUT"
MAX_CALL=0 watch 21 --interval 1; MAX_CALL=0 watch_rc 21 --interval 1
check "an armed, open PR at the per-call cap: exit code" "$RC" 7
has "an armed, open PR at the per-call cap: verdict" "$OUT" "CONTINUE"
[[ "$OUT" == ALL_MERGED* ]] && fail "an open PR is never reported merged" || ok "an open PR is never reported merged"

# open, then merged on the second poll
pr 22 "$(view OPEN BLOCKED APPROVED "$RUNNING")"
view MERGED UNKNOWN APPROVED "$GREEN" '{"oid":"def456"}' > "$FAKE/22/view.json.2"
watch 22; watch_rc 22
check "merged on the second poll: exit code" "$RC" 0
check "merged on the second poll: verdict" "$OUT" "ALL_MERGED $TAG#22=def456"

pr 23 "$(view OPEN BLOCKED APPROVED "$RED")"
watch 23; watch_rc 23
check "a red check: exit code" "$RC" 4
check "a red check: verdict" "$OUT" "CHECK_FAILED $TAG#23"

pr 24 "$(view OPEN BEHIND APPROVED "$GREEN")"
watch 24; watch_rc 24
check "behind the base with green checks: exit code" "$RC" 3
check "behind the base with green checks: verdict" "$OUT" "NEEDS_REBASE $TAG#24"
check "needing a rebase takes two polls" "$(cat "$FAKE/24/view.count")" 2

pr 25 "$(view OPEN DIRTY APPROVED "$GREEN")"
watch 25; watch_rc 25
check "a conflicting branch: exit code" "$RC" 3
check "a conflicting branch: verdict" "$OUT" "NEEDS_REBASE $TAG#25"

# behind on one poll only is a flicker, not a verdict
pr 26 "$(view OPEN BEHIND APPROVED "$GREEN")"
view MERGED UNKNOWN APPROVED "$GREEN" '{"oid":"aaa111"}' > "$FAKE/26/view.json.2"
watch 26; watch_rc 26
check "behind on one poll only is not a rebase verdict" "$OUT" "ALL_MERGED $TAG#26=aaa111"

pr 27 "$(view OPEN BLOCKED REVIEW_REQUIRED "$GREEN")"
watch 27; watch_rc 27
check "green checks and no review: exit code" "$RC" 6
check "green checks and no review: verdict" "$OUT" "BLOCKED_ON_REVIEW $TAG#27"

pr 28 "$(view OPEN BLOCKED REVIEW_REQUIRED "$RUNNING")"
watch 28 --timeout 0; watch_rc 28 --timeout 0
check "no review with checks still running is not a review verdict" "$OUT" "TIMEOUT"

mkdir -p "$FAKE/29"
watch 29 --timeout 0; watch_rc 29 --timeout 0
check "an unreadable PR is not reported merged: exit code" "$RC" 5
check "an unreadable PR is not reported merged: verdict" "$OUT" "TIMEOUT"

# two PRs: one merged, one open
OUT=$(HOME="$FH" XDG_STATE_HOME="$TMP/state" FAKE="$FAKE" PATH="$TMP/bin:$PATH" MAX_CALL=30 \
  "$SK/pr-merge-watch.sh" "$TAG#20" "$TAG#21" --interval 0 --timeout 0 --result-file "$TMP/watch.result" 2>/dev/null | tail -1)
rm -f /tmp/pr-merge-watch-deadline-*"$TAG"*
check "one merged and one open is not ALL_MERGED" "$OUT" "TIMEOUT"

# a reviewer bot posts a thread after arming: disarm, BOT_THREADS
pr 30 "$(view OPEN BLOCKED APPROVED "$RUNNING")" '' 1
: > "$FAKE/gh.log"
watch 30; watch_rc 30
check "a bot thread on an armed PR: exit code" "$RC" 8
check "a bot thread on an armed PR: verdict" "$OUT" "BOT_THREADS $TAG#30"
has "a bot thread on an armed PR disarms it" "$(cat "$FAKE/gh.log")" "pr merge 30 --repo EdgeApp/$TAG --disable-auto"

# the thread arrives on the second poll, before GitHub merges
pr 31 "$(view OPEN BLOCKED APPROVED "$RUNNING")"
view MERGED UNKNOWN APPROVED "$GREEN" '{"oid":"bbb222"}' > "$FAKE/31/view.json.3"
cat > "$SK/pr-land-comments.sh" <<'SH'
#!/usr/bin/env bash
NUM=$(jq -r '.[0].prNumber')
C="$FAKE/$NUM/comments.count"; N=$(( $(cat "$C" 2>/dev/null || echo 0) + 1 )); echo "$N" > "$C"
T=0; [[ "$NUM" == 31 && "$N" -ge 2 ]] && T=1
T=$(cat "$FAKE/$NUM/threads" 2>/dev/null || echo "$T")
[[ "$T" == fail ]] && exit 1
jq -nc --argjson n "$T" '[{botThreads: [range(0; $n)]}]'
SH
chmod +x "$SK/pr-land-comments.sh"
watch 31
check "a thread on the second poll stops the watch before the merge" "$OUT" "BOT_THREADS $TAG#31"

# an unreadable thread check never blocks or disarms
pr 32 "$(view OPEN BLOCKED APPROVED "$RUNNING")" '' fail
view MERGED UNKNOWN APPROVED "$GREEN" '{"oid":"ccc333"}' > "$FAKE/32/view.json.2"
: > "$FAKE/gh.log"
watch 32
check "an unreadable thread check keeps polling to the merge" "$OUT" "ALL_MERGED $TAG#32=ccc333"
has "an unreadable thread check is logged" "$(cat "$TMP/watch.err")" "bot-thread check failed"
[[ "$(cat "$FAKE/gh.log")" == *--disable-auto* ]] && fail "an unreadable thread check does not disarm" || ok "an unreadable thread check does not disarm"

# a merged PR with an open thread is the post-merge sweep's (step 9b), not a watch verdict
pr 33 "$(view MERGED UNKNOWN APPROVED "$GREEN" '{"oid":"ddd444"}')" '' 2
watch 33
check "a merged PR with open threads is still ALL_MERGED" "$OUT" "ALL_MERGED $TAG#33=ddd444"

HOME="$FH" PATH="$TMP/bin:$PATH" "$SK/pr-merge-watch.sh" >/dev/null 2>&1
check "no PR argument is a usage error" "$?" 1

if [[ "$FAILS" -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
