#!/usr/bin/env bash
# check-followup-scope.sh — LIVE-fetch a task's followup scope against the run-report
# watermark, per one-shot's `followup-scope-is-the-deliverable`.
#
# Why a script: every watcher resume auto-compacts the session from a summary built
# BEFORE the followup comment existed (spawn-test-session answers the resume menu with
# "Resume from summary", which runs /compact — trigger "manual" in the transcript).
# So a resumed agent's memory is by construction pre-followup, and runs kept
# re-Completing without seeing new operator comments (the 1209296431612665 UTXO miss,
# 2026-07-02). The enumeration must therefore be a REAL fetch, never recalled context.
# The require-followup-scope-on-complete.sh hook enforces that this ran.
#
# What it does:
#   1. Fetch the task's attachments; watermark = newest agent-run-report*.md created_at
#      (no report ever attached -> watermark is empty -> ALL comments are scope).
#   2. Fetch the task's stories; enumerate comment_added stories NEWER than the watermark.
#   3. Fetch the task's LIVE fields and diff them against the previous segment's
#      snapshot (stamp-orch-version.sh records fields at every spawn/resume). A re-arm
#      with ZERO new comments but changed fields (e.g. Build or Force Land set after
#      Complete — the Nym case) is operator intent, not a spurious re-fire; the delta
#      says WHY the task came back. Best-effort: no baseline (pre-feature segments) or
#      a failed fetch degrades to "unavailable", never fails the comment check. The
#      snapshot is a delta baseline only — decisions keep reading fields live.
#   4. Fetch GITHUB-side scope for every PR attached to the task (view_url on
#      external attachments): unresolved review threads from ANY author, and the
#      reviewDecision. A re-arm is often triggered by a human PR review with ZERO
#      Asana activity — the Maya miss (2026-07-29): peachbits requested changes on
#      PR #459, the re-fired run saw "0 new comments", filtered threads to
#      __typename==Bot per the old gate wording, and re-set Complete past an OPEN
#      human thread. Scope lives where the reviewer wrote it, not where the
#      watermark lives. Ownership-aware: unresolved threads BLOCK on a PR the gh
#      user authors (reply+resolve owed); on a non-owned PR they are surfaced but
#      non-blocking (reply-only, per pr-address non-owner-reply-only). Draft PRs
#      are skipped (finalize-gate excludes draft dep PRs). Best-effort: gh/network
#      failure degrades to "unavailable", never fails the Asana enumeration.
#   5. Print them, and write the marker /tmp/agent-followup-scope-<gid>.json recording
#      what was fetched and when (the hook checks marker freshness against live
#      comments, and blocks Complete while owned-PR unresolved threads are recorded).
#
# Usage: check-followup-scope.sh --task-gid <gid>
# Exit: 0 = check completed (marker written; newer scope MAY exist — read the output),
#       1 = usage/API error (no marker written).

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
TASK_GID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid) TASK_GID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$TASK_GID" ]] || { echo "Usage: check-followup-scope.sh --task-gid <gid>" >&2; exit 1; }

TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$DIR/credentials.json" 2>/dev/null)}"
[[ -n "$TOKEN" ]] || { echo "check-followup-scope: no Asana token" >&2; exit 1; }

API="https://app.asana.com/api/1.0"
ATT="$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
  "$API/tasks/$TASK_GID/attachments?opt_fields=name,created_at,gid")" || { echo "check-followup-scope: attachments fetch failed" >&2; exit 1; }
STORIES="$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
  "$API/tasks/$TASK_GID/stories?opt_fields=created_at,resource_subtype,text,created_by.name")" || { echo "check-followup-scope: stories fetch failed" >&2; exit 1; }
echo "$ATT" | jq -e '.data' >/dev/null 2>&1 || { echo "check-followup-scope: attachments response invalid: $(echo "$ATT" | head -c 200)" >&2; exit 1; }
echo "$STORIES" | jq -e '.data' >/dev/null 2>&1 || { echo "check-followup-scope: stories response invalid: $(echo "$STORIES" | head -c 200)" >&2; exit 1; }

# Watermark: newest agent-run-report*.md attachment. ISO-8601 sorts lexically.
WATERMARK="$(echo "$ATT" | jq -r '[.data[] | select(.name | test("^agent-run-report.*\\.md$")) | .created_at] | sort | last // empty')"
WATERMARK_GID="$(echo "$ATT" | jq -r --arg w "$WATERMARK" 'first(.data[] | select(.name | test("^agent-run-report.*\\.md$")) | select(.created_at == $w) | .gid) // empty')"

# Comments newer than the watermark (all comments when no report was ever attached).
NEWER="$(echo "$STORIES" | jq --arg w "$WATERMARK" \
  '[.data[] | select(.resource_subtype == "comment_added") | select(($w == "") or (.created_at > $w))]')"
NEWER_COUNT="$(echo "$NEWER" | jq 'length')"
NEWEST_COMMENT_AT="$(echo "$STORIES" | jq -r '[.data[] | select(.resource_subtype == "comment_added") | .created_at] | sort | last // empty')"

# Field deltas: live fields vs the previous segment's snapshot in versions/<gid>.jsonl.
# Inside the task's own session the NEWEST fields-bearing stamp was just written by
# THIS segment's spawn/resume — skip it so the baseline is the segment before.
VERSIONS_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions/$TASK_GID.jsonl"
FIELD_DELTAS="[]"
BASELINE_TS=""
DELTA_STATUS="unavailable: no prior field snapshot"
LIVE_FIELDS="null"
RESP=$(curl -sf --max-time 20 -H "Authorization: Bearer $TOKEN" \
  "$API/tasks/$TASK_GID?opt_fields=name,completed,custom_fields.name,custom_fields.display_value" 2>/dev/null) \
  && LIVE_FIELDS=$(echo "$RESP" | jq -c '{name: .data.name, completed: .data.completed}
       + ([.data.custom_fields[]? | {(.name // "?"): (.display_value // null)}] | add // {})' 2>/dev/null) \
  || LIVE_FIELDS="null"
[[ -n "$LIVE_FIELDS" ]] || LIVE_FIELDS="null"

if [[ "$LIVE_FIELDS" == "null" ]]; then
  DELTA_STATUS="unavailable: live field fetch failed"
elif [[ -f "$VERSIONS_FILE" ]]; then
  SNAPS=$(jq -cs '[.[] | select(.fields != null)]' "$VERSIONS_FILE" 2>/dev/null || echo "[]")
  if [[ "${AGENT_TASK_GID:-}" == "$TASK_GID" ]]; then
    SNAPS=$(echo "$SNAPS" | jq -c '.[0:-1]')
  fi
  BASELINE=$(echo "$SNAPS" | jq -c 'last // empty')
  if [[ -n "$BASELINE" ]]; then
    BASELINE_TS=$(echo "$BASELINE" | jq -r '.ts')
    FIELD_DELTAS=$(jq -nc \
      --argjson old "$(echo "$BASELINE" | jq -c '.fields')" \
      --argjson new "$LIVE_FIELDS" \
      '[ (($old | keys) + ($new | keys) | unique)[]
         | select($old[.] != $new[.])
         | {field: ., was: $old[.], now: $new[.]} ]' 2>/dev/null || echo "[]")
    DELTA_STATUS="ok"
  fi
fi

# GitHub-side scope: unresolved threads + reviewDecision per attached PR.
GH_STATUS="unavailable: gh not on PATH"
GH_SCOPE="[]"
GH_BLOCKING=0
if command -v gh >/dev/null 2>&1; then
  GH_STATUS="ok"
  GH_USER=$(gh api user -q .login 2>/dev/null || true)
  [[ -n "$GH_USER" ]] || GH_STATUS="unavailable: gh auth failed"
  PR_URLS=$(echo "$ATT" | jq -r '[.data[] | .view_url // "" | select(test("github\\.com/.+/pull/[0-9]+$"))] | unique | .[]' 2>/dev/null || true)
  # view_url needs its own fetch when the first attachments call lacked it.
  if [[ -z "$PR_URLS" ]]; then
    ATT2="$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
      "$API/tasks/$TASK_GID/attachments?opt_fields=view_url" 2>/dev/null || true)"
    PR_URLS=$(echo "$ATT2" | jq -r '[.data[]? | .view_url // "" | select(test("github\\.com/.+/pull/[0-9]+$"))] | unique | .[]' 2>/dev/null || true)
  fi
  if [[ "$GH_STATUS" == "ok" ]]; then
    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      OWNER=$(sed -E 's#https://github.com/([^/]+)/([^/]+)/pull/([0-9]+)#\1#' <<<"$url")
      RNAME=$(sed -E 's#https://github.com/([^/]+)/([^/]+)/pull/([0-9]+)#\2#' <<<"$url")
      NUM=$(sed -E 's#https://github.com/([^/]+)/([^/]+)/pull/([0-9]+)#\3#' <<<"$url")
      PRJ=$(gh api graphql -f query="query{repository(owner:\"$OWNER\",name:\"$RNAME\"){pullRequest(number:$NUM){state isDraft author{login} reviewDecision reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{author{login} createdAt body}}}}}}}" 2>/dev/null \
        | jq -c --arg me "$GH_USER" --arg url "$url" '.data.repository.pullRequest
          | select(.state == "OPEN" and (.isDraft | not))
          | {url: $url, owned: (.author.login == $me), review_decision: (.reviewDecision // "none"),
             unresolved: [.reviewThreads.nodes[] | select(.isResolved | not) | .comments.nodes[0]
                          | {by: (.author.login // "?"), at: .createdAt, text: (.body // "" | .[0:200])}]}' 2>/dev/null || true)
      [[ -n "$PRJ" ]] && GH_SCOPE=$(jq -c --argjson p "$PRJ" '. + [$p]' <<<"$GH_SCOPE")
    done <<<"$PR_URLS"
    GH_BLOCKING=$(jq '[.[] | select(.owned) | .unresolved | length] | add // 0' <<<"$GH_SCOPE")
  fi
fi

MARKER="/tmp/agent-followup-scope-$TASK_GID.json"
jq -n \
  --arg gid "$TASK_GID" \
  --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg watermark "$WATERMARK" \
  --arg newest_comment_at "$NEWEST_COMMENT_AT" \
  --argjson newer_count "$NEWER_COUNT" \
  --argjson comments "$(echo "$NEWER" | jq '[.[] | {created_at, by: (.created_by.name // "?"), text: (.text // "" | .[0:400])}]')" \
  --arg delta_status "$DELTA_STATUS" \
  --arg baseline_ts "$BASELINE_TS" \
  --argjson field_deltas "$FIELD_DELTAS" \
  --arg gh_status "$GH_STATUS" \
  --argjson gh_scope "$GH_SCOPE" \
  --argjson gh_blocking "$GH_BLOCKING" \
  '{task_gid: $gid, checked_at: $checked_at, watermark: $watermark, newest_comment_at: $newest_comment_at, newer_count: $newer_count, comments: $comments,
    field_delta_status: $delta_status, field_baseline_ts: $baseline_ts, field_deltas: $field_deltas,
    github_status: $gh_status, github_prs: $gh_scope, github_blocking_threads: $gh_blocking}' \
  > "$MARKER"

echo ">> check-followup-scope: task $TASK_GID"
if [[ -n "$WATERMARK" ]]; then
  echo ">>   watermark (latest agent-run-report*.md): $WATERMARK"
else
  echo ">>   watermark: NONE — no run-report ever attached; EVERY comment is undischarged scope"
fi
if [[ "$NEWER_COUNT" -eq 0 ]]; then
  echo ">>   0 comments newer than the watermark — no new comment scope"
else
  echo ">>   $NEWER_COUNT comment(s) NEWER than the watermark — this is THIS run's scope (followup-scope-is-the-deliverable):"
  echo "$NEWER" | jq -r '.[] | "     [\(.created_at)] \(.created_by.name // "?"): \(.text // "" | gsub("\\s+"; " ") | .[0:200])"'
fi
if [[ "$DELTA_STATUS" == "ok" ]]; then
  DELTA_COUNT=$(echo "$FIELD_DELTAS" | jq 'length')
  if [[ "$DELTA_COUNT" -eq 0 ]]; then
    echo ">>   0 field changes since previous segment snapshot ($BASELINE_TS)"
  else
    echo ">>   $DELTA_COUNT field change(s) since previous segment snapshot ($BASELINE_TS) — operator intent, NOT a spurious re-fire:"
    echo "$FIELD_DELTAS" | jq -r '.[] | "     \(.field): \(if .was == null then "(unset)" else (.was|tostring) end) -> \(if .now == null then "(unset)" else (.now|tostring) end)"'
    echo ">>   act on each: a field flip can mean ROUTING (Build/Force Land — re-confirm the finalize gate, whose live reads consume them) or WORK OWED (e.g. 'TDD?' -> TDD means the TDD is owed NOW, per one-shot tdd-when-flagged; a 'name' change is a RENAME — the new title's wording IS scope, diff it against the old title and deliver what it added). Resolve each changed field against its owning rule before finalizing."
  fi
else
  echo ">>   field deltas: $DELTA_STATUS"
fi
if [[ "$GH_STATUS" == "ok" ]]; then
  PR_COUNT=$(jq 'length' <<<"$GH_SCOPE")
  if [[ "$PR_COUNT" -eq 0 ]]; then
    echo ">>   github: no open non-draft PRs attached"
  else
    jq -r '.[] | ">>   github: \(.url) [\(if .owned then "OWNED" else "not owned" end), reviewDecision: \(.review_decision)] — \(.unresolved | length) unresolved thread(s)"' <<<"$GH_SCOPE"
    jq -r '.[] | .unresolved[] | "     [\(.at)] \(.by): \(.text | gsub("\\s+"; " ") | .[0:160])"' <<<"$GH_SCOPE"
    if [[ "$GH_BLOCKING" -gt 0 ]]; then
      echo ">>   $GH_BLOCKING unresolved thread(s) on OWNED PR(s) — THIS RUN'S SCOPE regardless of Asana silence (a human review IS the re-arm reason; scope lives where the reviewer wrote it). Address per pr-address reply-then-resolve; Complete is gate-blocked until a re-check records zero."
    fi
  fi
else
  echo ">>   github: $GH_STATUS"
fi
echo ">>   marker written: $MARKER"

# PRIOR-REPORT RECALL. Every resume compacts the session, and the summary is
# lossy exactly where the report is dense (what was verified vs assumed, rejected
# review findings, deferred follow-ups). The report is the durable record and was
# never being re-read — runs re-litigated settled questions from paraphrased
# memory. Print a BOUNDED excerpt of the watermark report here, at the one call
# every followup makes while establishing scope. Best-effort: any failure is
# silent, this must never break the comment enumeration above.
if [[ -n "$WATERMARK_GID" ]]; then
  DL="$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
    "$API/attachments/$WATERMARK_GID?opt_fields=download_url,name" 2>/dev/null \
    | jq -r '.data.download_url // empty' 2>/dev/null || true)"
  if [[ -n "$DL" ]]; then
    BODY="$(curl -sSL --max-time 30 "$DL" 2>/dev/null || true)"
    if [[ -n "$BODY" ]]; then
      echo ">>"
      echo ">> PRIOR RUN REPORT (watermark $WATERMARK) — the durable record of what the"
      echo ">> last segment did. Your compacted memory is a lossy paraphrase of this;"
      echo ">> trust these lines over recollection, and do NOT re-derive what they settle."
      # Frontmatter (outcome/verified/verify_blockers) then the sections a followup
      # most often re-litigates. Each section capped so a long report cannot flood
      # the context this call exists to protect.
      printf '%s\n' "$BODY" | awk '
        /^---$/ { fm++; if (fm<=2) { print "     " $0; next } }
        fm==1 { print "     " $0; next }
      ' | head -12
      for SEC in "Testing" "Decisions" "Follow-ups & Risks"; do
        printf '%s\n' "$BODY" | awk -v sec="## $SEC" '
          index($0, sec)==1 { inSec=1; print "     " $0; next }
          /^## / { inSec=0 }
          inSec && NF { print "     " $0 }
        ' | head -14
      done
      echo ">>   (full report: the newest agent-run-report*.md attachment on the task)"
    fi
  fi
fi
