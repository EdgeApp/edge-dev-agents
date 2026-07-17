#!/usr/bin/env bash
# stamp-orch-version.sh — record WHICH version of the orchestration a session runs under.
#
# The orch changes between eval cohorts (skills, hooks, watcher scripts), so cohort
# comparisons need to know what governed each run SEGMENT. Every spawn and resume
# funnels through spawn-test-session.sh, which calls this to append one stamp line to
# $STATE/versions/<gid>.jsonl and prints the orch digest (exported as AGENT_ORCH_VERSION).
#
# Digests are CONTENT-based (mtimes churn on sync without behavior change):
#   orch_digest      behavior-governing files: run-facing skills + rules + watcher
#                    scripts/config + hooks + the hooks section of settings.json
#   eval_digest      the eval family (agent-eval, orch-eval, resolve-run, eval-run,
#                    rubric lock) — separate so rubric edits don't fork the orch version
#   components       per-tree sub-digests to localize what changed between versions
# repo_head + repo_dirty tie the stamp to the synced edge-dev-agents repo: when clean,
# the repo reconstructs the exact governing files for any stamp; when dirty, dirty
# component names bound the ambiguity.
#
# fields — a snapshot of the Asana task's custom fields (+ completed) at this
# segment's START: the record of what this session COULD see, so evals can tell
# "agent ignored the field" from "field wasn't set yet" (the Nym staging/force-land
# case, set minutes AFTER Complete). It is a RECORD and a delta baseline for
# check-followup-scope.sh, NEVER a read source for decisions — build routing,
# force-land, and cheese checks keep reading live at decision time. null = fetch
# failed (distinct from {} = task has no fields).
#
# Usage: stamp-orch-version.sh --gid <gid> --segment spawn|resume
#          [--model <m>] [--effort <e>] [--session-uuid <u>]
# Prints the 12-hex orch digest on stdout. Never fails the caller (best-effort): on
# internal error prints nothing and exits 0.

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
REPO="$HOME/git/edge-dev-agents"
EVAL_FAMILY="agent-eval|orch-eval|resolve-run|eval-run"

GID="" SEGMENT="" MODEL="" EFFORT="" SUUID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --segment) SEGMENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --session-uuid) SUUID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$GID" && -n "$SEGMENT" ]] || exit 0

# digest <root> [egrep-exclude] → 12-hex content digest of all files under root
digest() {
  local root="$1" exclude="${2:-__none__}"
  [[ -d "$root" ]] || { echo "------------"; return; }
  find "$root" -type f 2>/dev/null \
    | grep -vE "$exclude" \
    | grep -vE '(^|/)(credentials\.json|.*\.log|\.DS_Store)$' \
    | LC_ALL=C sort \
    | xargs shasum -a 256 2>/dev/null \
    | shasum -a 256 | cut -c1-12
}

D_SKILLS=$(digest "$HOME/.cursor/skills" "/skills/($EVAL_FAMILY)/")
D_RULES=$(digest "$HOME/.cursor/rules")
D_WATCHER=$(digest "$HOME/.config/agent-watcher" '/hooks/|/oom-repro/|pool\.json|slots\.json|watchdog-state\.json')
D_HOOKS=$(digest "$HOME/.config/agent-watcher/hooks")
D_SETTINGS=$(jq -S '.hooks // {}' "$HOME/.claude/settings.json" 2>/dev/null | shasum -a 256 | cut -c1-12)
ORCH=$(printf '%s %s %s %s %s' "$D_SKILLS" "$D_RULES" "$D_WATCHER" "$D_HOOKS" "$D_SETTINGS" | shasum -a 256 | cut -c1-12)
D_EVAL=$( { digest "$HOME/.cursor/skills/agent-eval"; digest "$HOME/.cursor/skills/orch-eval"; \
            digest "$HOME/.cursor/skills/resolve-run"; digest "$HOME/.cursor/skills/eval-run"; \
            shasum -a 256 "$HOME/.cursor/skills/rubric-drift.lock.json" 2>/dev/null; } | shasum -a 256 | cut -c1-12)

REPO_HEAD=""; DIRTY_COMPONENTS="[]"
if [[ -d "$REPO/.git" ]]; then
  REPO_HEAD=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)
  # Compare deployed components against the repo's distribution copies (content digests
  # with matching exclusions). settings_hooks has no repo counterpart — not compared.
  R_SKILLS=$(digest "$REPO/skills" "/skills/($EVAL_FAMILY)/")
  R_RULES=$(digest "$REPO/rules")
  R_WATCHER=$(digest "$REPO/agent-watcher" '/hooks/|/oom-repro/|credentials\.example\.json')
  R_HOOKS=$(digest "$REPO/agent-watcher/hooks")
  DC=()
  [[ "$D_SKILLS"  != "$R_SKILLS"  ]] && DC+=("skills")
  [[ "$D_RULES"   != "$R_RULES"   ]] && DC+=("rules")
  [[ "$D_WATCHER" != "$R_WATCHER" ]] && DC+=("watcher")
  [[ "$D_HOOKS"   != "$R_HOOKS"   ]] && DC+=("hooks")
  DIRTY_COMPONENTS=$(printf '%s\n' "${DC[@]:-}" | grep -v '^$' | jq -R . | jq -sc . 2>/dev/null || echo "[]")
fi
REPO_DIRTY=$([[ "$DIRTY_COMPONENTS" != "[]" ]] && echo true || echo false)

# Asana field snapshot (best-effort; null on any failure). Whole field map, not a
# curated list — same API call either way, future fields ride along.
FIELDS="null"
TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
if [[ -n "$TOKEN" ]]; then
  RESP=$(curl -sf --max-time 20 \
    "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=completed,custom_fields.name,custom_fields.display_value" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null) \
    && FIELDS=$(echo "$RESP" | jq -c '{completed: .data.completed}
         + ([.data.custom_fields[]? | {(.name // "?"): (.display_value // null)}] | add // {})' 2>/dev/null) \
    || FIELDS="null"
  [[ -n "$FIELDS" ]] || FIELDS="null"
fi

mkdir -p "$STATE_DIR/versions"
jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg gid "$GID" --arg segment "$SEGMENT" \
  --arg orch "$ORCH" --arg eval "$D_EVAL" \
  --arg skills "$D_SKILLS" --arg rules "$D_RULES" --arg watcher "$D_WATCHER" \
  --arg hooks "$D_HOOKS" --arg settings "$D_SETTINGS" \
  --arg head "$REPO_HEAD" --argjson dirty "$REPO_DIRTY" --argjson dcomp "$DIRTY_COMPONENTS" \
  --arg cli "$(claude --version 2>/dev/null | head -1 || true)" \
  --arg model "$MODEL" --arg effort "$EFFORT" --arg suuid "$SUUID" \
  --argjson fields "$FIELDS" \
  '{ts:$ts, gid:$gid, segment:$segment, orch_digest:$orch, eval_digest:$eval,
    components:{skills:$skills, rules:$rules, watcher:$watcher, hooks:$hooks, settings_hooks:$settings},
    repo_head:$head, repo_dirty:$dirty, dirty_components:$dcomp,
    claude_version:$cli, model:$model, effort:$effort, session_uuid:$suuid, fields:$fields}' \
  >> "$STATE_DIR/versions/$GID.jsonl" 2>/dev/null || exit 0

echo "$ORCH"
