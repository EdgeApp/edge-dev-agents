#!/usr/bin/env bash
# completion-evidence.sh -- assemble the EVIDENCE BUNDLE the completion judge reads
# (completion-judge skill). Deterministic collection, no judgment: task fields and
# description, operator asks since the run-report watermark, the run report, the
# state file, the attempt-log, proof frames, the concession reason, per-worktree git
# facts (commits, diff stat, CHANGELOG diff, scaffolding scan, capped diff) and the
# mechanical CHANGELOG lint. The bundle's sha256 (over everything but the generated
# line) binds the verdict to exactly this evidence.
#
# Usage:
#   completion-evidence.sh --gid <gid> --event complete|pr-create|block [--reason "<text>"]
#                          [--out <file>] [--offline]
# Prints:  path=<bundle> hash=<sha256 first 16>
# --offline skips the Asana/GitHub fetches (tests; a run whose scope marker is fresh).
# Env: COMPLETION_JUDGE_OFFLINE=1 has the same effect as --offline.
# Exit: 0 bundle written; 2 usage.
set -uo pipefail

GID="" EVENT="" REASON="" OUT="" OFFLINE="${COMPLETION_JUDGE_OFFLINE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    *) echo "completion-evidence: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] && [ -n "$EVENT" ] || { echo "usage: completion-evidence.sh --gid <gid> --event complete|pr-create|block [--reason R] [--out F] [--offline]" >&2; exit 2; }
case "$EVENT" in complete|pr-create|block) ;; *) echo "completion-evidence: bad --event $EVENT" >&2; exit 2 ;; esac

H="$HOME/.config/agent-watcher"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
[ -n "$OUT" ] || OUT="/tmp/agent-completion-evidence-$GID.md"
TMP="$OUT.tmp.$$"
: > "$TMP"
TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$H/credentials.json" 2>/dev/null)}"
API="https://app.asana.com/api/1.0"

cap() { # cap <bytes>: pass stdin through, truncated with a marker
  local n="$1"; head -c "$n"; local rest; rest=$(head -c 1 | wc -c); [ "$rest" -gt 0 ] && printf '\n[... truncated at %s bytes ...]\n' "$n"; return 0; }
section() { printf '\n## %s\n\n' "$1" >> "$TMP"; }
line() { printf '%s\n' "$*" >> "$TMP"; }
file_or_note() { # file_or_note <path> <cap> <note-if-missing>
  if [ -s "$1" ]; then printf '```\n' >> "$TMP"; cap "$2" < "$1" >> "$TMP"; printf '\n```\n' >> "$TMP"; else line "$3"; fi; }

line "# Completion evidence: task $GID"
line "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
line "event: $EVENT"
[ -n "$REASON" ] && { line "claimed reason:"; line '```'; line "$REASON"; line '```'; }

# ---- Task ----
section "Task"
if [ "$OFFLINE" = 1 ] || [ -z "$TOKEN" ]; then
  line "(task fetch skipped: offline)"
else
  RESP=$(curl -sf --max-time 20 -H "Authorization: Bearer $TOKEN" \
    "$API/tasks/$GID?opt_fields=name,completed,notes,custom_fields.name,custom_fields.display_value" 2>/dev/null || true)
  if [ -n "$RESP" ]; then
    printf '%s' "$RESP" | jq -r '.data | "name: \(.name)\ncompleted: \(.completed)\nfields: " + ([.custom_fields[]? | select(.name|test("^(agent_status|blocked|tested|TDD\\?|Build \\(staging/cheese\\)|Release \\(4\\.x\\.x\\)|Force Land|agent_lane|Repo)$")) | "\(.name)=\(.display_value // "null")"] | join("; "))' >> "$TMP" 2>/dev/null || line "(task fields unparseable)"
    line ""; line "description:"; line '```'
    printf '%s' "$RESP" | jq -r '.data.notes // ""' | cap 12000 >> "$TMP"
    line ""; line '```'
  else
    line "(task fetch failed)"
  fi
fi

# ---- Segment scope + operator asks (live scope check) ----
# The judge grades THIS SEGMENT only: a first run (no report ever attached) is
# scoped to the task description; a followup is scoped to the operator comments
# since the last report attach (the latest followup batch) and the description
# is background. Everything else the task ever wanted is context, not the bar.
MARKER="/tmp/agent-followup-scope-$GID.json"
if [ "$OFFLINE" != 1 ] && [ -x "$H/check-followup-scope.sh" ]; then
  "$H/check-followup-scope.sh" --task-gid "$GID" >/dev/null 2>&1 || true
fi
section "Segment scope"
# segment_* fields (check-followup-scope.sh own the rationale); older markers without
# them fall back to the plain watermark.
WM=""; SEG_START=""; ASKS_KEY="comments"; SEG_NOTE=""
if [ -s "$MARKER" ]; then
  if jq -e 'has("segment_comments")' "$MARKER" >/dev/null 2>&1; then
    WM=$(jq -r '.segment_watermark // empty' "$MARKER" 2>/dev/null); SEG_START=$(jq -r '.segment_start // empty' "$MARKER" 2>/dev/null); ASKS_KEY="segment_comments"
  else
    WM=$(jq -r '.watermark // empty' "$MARKER" 2>/dev/null)
  fi
fi
[ -n "$SEG_START" ] && SEG_NOTE=" (segment started $SEG_START)"
if [ -z "$WM" ]; then
  line "segment: FIRST RUN$SEG_NOTE: no run report was attached before this segment started. THE ASK IS THE TASK DESCRIPTION above; any operator comments below are amendments to it."
else
  line "segment: FOLLOWUP$SEG_NOTE: the report attached before it is dated $WM. THE ASKS ARE ONLY THE OPERATOR COMMENTS BELOW, newer than that report; when there are none, the re-arm reason is the field deltas and GitHub counters below, each mapped to what the orch owes for it (the rubric carries the field table). A report attached during this segment does not change the asks. The task description is background: earlier segments already reported on it, and whatever it still leaves open is NOT this segment's bar unless a comment below asks for it."
fi
section "Operator asks (this segment's scope)"
if [ -s "$MARKER" ]; then
  jq -r --arg k "$ASKS_KEY" '"checked_at: \(.checked_at // "?")\nnewest report attach overall: \(.watermark // "NONE")\ngithub_blocking_threads: \(.github_blocking_threads // 0); github_unanswered_bodies: \(.github_unanswered_bodies // 0); github_bots_incomplete: \(.github_bots_incomplete // 0)\n"
    + ((.[$k] // []) | if length == 0 then "(no operator comments in scope)" else ([.[] | "- [\(.created_at)] \(.by) (\(.authored)): \(.text)"] | join("\n")) end)
    + "\n\nfield deltas since the previous segment: " + ((.field_deltas // []) | map("\(.field): \(.was) -> \(.now)") | join("; "))' "$MARKER" >> "$TMP" 2>/dev/null || line "(marker unparseable)"
else
  line "(no followup-scope marker: run check-followup-scope.sh --task-gid $GID)"
fi

# ---- Run report ----
section "Run report"
REPORT=$(ls -t /tmp/agent-run-report-"$GID"-*.md 2>/dev/null | head -1)
if [ -n "$REPORT" ]; then line "file: $REPORT ($(stat -f %Sm -t %Y-%m-%dT%H:%M:%S "$REPORT" 2>/dev/null))"; file_or_note "$REPORT" 60000 "(empty)"; else line "(no run report at /tmp/agent-run-report-$GID-*.md)"; fi

# ---- State file ----
section "State file"
file_or_note "/tmp/agent-state-$GID.md" 20000 "(no state file)"

# ---- Attempt log ----
section "Attempt log (authoritative record of drives and value-moving actions)"
file_or_note "$STATE/attempts/$GID.jsonl" 30000 "(EMPTY: no attempt was ever logged for this task)"

# ---- Proof frames, blocker note, concession reason ----
section "Proof frames and notes"
FRAMES=$(ls -la /tmp/agent-proof-"$GID"-*.png 2>/dev/null | awk '{print $5" "$9}')
if [ -n "$FRAMES" ]; then line "proof frames (bytes path):"; line '```'; line "$FRAMES"; line '```'; else line "no proof frames at /tmp/agent-proof-$GID-*.png"; fi
[ -s "/tmp/agent-test-blocker-$GID.md" ] && { line "test-blocker note:"; file_or_note "/tmp/agent-test-blocker-$GID.md" 4000 ""; }
[ -s "/tmp/agent-concession-reason-$GID.txt" ] && { line "concession reason file:"; file_or_note "/tmp/agent-concession-reason-$GID.txt" 4000 ""; }
[ -s "/tmp/agent-history-concession-$GID.md" ] && { line "history concession note:"; file_or_note "/tmp/agent-history-concession-$GID.md" 4000 ""; }

# ---- Git per worktree ----
section "Git (per worktree)"
WT_ROOT="${AGENT_WORKTREE_ROOT:-$HOME/git/.agent-worktrees}/$GID"
found=0
for wt in "$WT_ROOT"/*/; do
  [ -d "$wt/.git" ] || [ -f "$wt/.git" ] || continue
  found=1
  repo=$(basename "$wt"); branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  line ""; line "### $repo (branch $branch)"
  base=""; prinfo=""
  if [ "$OFFLINE" != 1 ] && command -v gh >/dev/null 2>&1; then
    prinfo=$(git -C "$wt" -c core.quotepath=off ls-remote --get-url >/dev/null 2>&1 && gh pr view --repo "$(git -C "$wt" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')" "$branch" --json url,state,isDraft,baseRefName,reviewDecision,statusCheckRollup 2>/dev/null | jq -c '{url,state,isDraft,baseRefName,reviewDecision,checks:([.statusCheckRollup[]? | {name:(.name // .context), status:(.conclusion // .state)}])}' 2>/dev/null || true)
    [ -n "$prinfo" ] && base=$(printf '%s' "$prinfo" | jq -r '.baseRefName // empty')
  fi
  [ -n "$prinfo" ] && line "pr: $prinfo" || line "pr: none found"
  if [ -z "$base" ]; then
    for b in develop master main; do git -C "$wt" rev-parse --verify -q "origin/$b" >/dev/null 2>&1 && { base="$b"; break; }; done
  fi
  if [ -z "$base" ]; then line "(no base branch resolvable)"; continue; fi
  line "base: origin/$base"
  line "commits (base..HEAD):"; line '```'
  git -C "$wt" log --format='%h %s' "origin/$base..HEAD" 2>/dev/null | head -60 >> "$TMP"; line '```'
  line "diff stat:"; line '```'
  git -C "$wt" diff --stat "origin/$base...HEAD" 2>/dev/null | tail -40 >> "$TMP"; line '```'
  line "uncommitted changes in the worktree:"; line '```'
  git -C "$wt" status --porcelain 2>/dev/null | head -30 >> "$TMP"; line '```'
  CL=$(git -C "$wt" diff "origin/$base...HEAD" -- CHANGELOG.md 2>/dev/null)
  if [ -n "$CL" ]; then
    line "CHANGELOG diff:"; line '```'; printf '%s\n' "$CL" | cap 6000 >> "$TMP"; line '```'
    CL_LINT="$HOME/.cursor/skills/changelog/scripts/changelog-entry-lint.sh"
    if [ -x "$CL_LINT" ]; then
      ADDED=$(printf '%s\n' "$CL" | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//')
      LINT_RC=0; LINT_OUT=$(printf '%s\n' "$ADDED" | "$CL_LINT" 2>&1) || LINT_RC=$?
      line "changelog-entry-lint exit $LINT_RC:"; line '```'; printf '%s\n' "$LINT_OUT" | cap 3000 >> "$TMP"; line '```'
    fi
  else
    line "CHANGELOG diff: none"
  fi
  SCAN=$(git -C "$wt" diff "origin/$base...HEAD" 2>/dev/null | grep -nE '^\+' | grep -vE '^[0-9]+:\+\+\+' | grep -E 'corePlugins|DEBUG_|forceProvider|force[A-Z][a-zA-Z]*Provider|console\.log\(|debugger;|\.hype-bal-probe|probe\.cjs|__DEV__ *= *true' | head -30)
  if [ -n "$SCAN" ]; then line "scaffolding scan (added lines matching debug/trim patterns; judge in context):"; line '```'; line "$SCAN"; line '```'; else line "scaffolding scan: no matches"; fi
  line "diff (capped):"; line '```diff'
  git -C "$wt" diff "origin/$base...HEAD" 2>/dev/null | cap 120000 >> "$TMP"; line '```'
done
[ "$found" = 1 ] || line "(no worktrees under $WT_ROOT)"

# ---- Hash + finalize ----
HASH=$(grep -v '^generated: ' "$TMP" | shasum -a 256 | cut -c1-16)
line ""; line "evidence_hash: $HASH"
mv -f "$TMP" "$OUT"
echo "path=$OUT hash=$HASH"
