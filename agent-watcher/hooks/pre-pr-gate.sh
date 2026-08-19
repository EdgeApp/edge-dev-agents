#!/usr/bin/env bash
# pre-pr-gate.sh — PreToolUse hook (matcher: Bash). The quality gate at the
# PR-creation moment for orchestrated sessions. Two checks, one firing point:
#
#   1. TEST EVIDENCE (hard, exit 2): blocks pr-create.sh until in-app test
#      evidence exists, per build-and-test's test-on-sim-by-default and
#      gui-dependency-integration rules. Deterministic counterpart to the prose
#      rules that 4/7 dep-repo runs skipped (2026-06-10 audit).
#      Evidence, any of: proof screenshot /tmp/agent-proof-<gid>-*.png; Android
#      build log /tmp/agent-android-build-<gid>*.log or .apk proof; a
#      sanctioned-blocker note /tmp/agent-test-blocker-<gid>.md (audited by
#      /eval-run — an unjustified note is a finding).
#
#   2. DUPLICATE-UTILITY SCAN (soft, additionalContext): when the branch diff
#      adds general-purpose helper functions, enumerate them, best-effort grep
#      the repo + package.json for prior art on each helper's name tokens, and
#      inject the findings so the session checks BEFORE the PR exists (and
#      before bugbot bills). Never blocks: name/token matching has unknown
#      false-positive rates, and a helper can be legitimately novel. Fires once
#      per task (flag file) so pr-create retries stay quiet.
#
# Formerly require-test-evidence-before-pr.sh; renamed 2026-08-13 when the
# dedup scan broadened its role (name-tracks-scope).
#
# Scope: no-ops unless AGENT_TASK_GID is set. Draft dependency PRs created with
# `gh pr create --draft` are not gated (per one-shot's dep-pr-draft-vs-bump).
# Exit 0 = allow. Exit 2 = block (stderr is fed back to the model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$CMD" ] || exit 0
# Mention-stripped view for TRIGGER matching (heredoc bodies, quoted and
# backticked spans blanked): a command that merely QUOTES a trigger string --
# a report heredoc, an echo -- must not fire this hook. Raw $CMD is kept for
# argument extraction, where quoted values are load-bearing. Fail-open to the
# raw command if the helper is unavailable.
CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")

case "$CMD_M" in
  *pr-create.sh*) ;;
  *) exit 0 ;;
esac

# ---- Check 1: test evidence (hard) ------------------------------------------
HAS_EVIDENCE=0
if ls /tmp/agent-proof-"$AGENT_TASK_GID"-*.png >/dev/null 2>&1; then
  HAS_EVIDENCE=1
# Android build evidence: an assembleDebug log or APK is valid terminal-success
# evidence for an Android-called-out / build-only task (GitHub CI does not build
# Android, so this is the only gate that catches those regressions).
elif ls /tmp/agent-android-build-"$AGENT_TASK_GID"*.log >/dev/null 2>&1 || ls /tmp/agent-proof-"$AGENT_TASK_GID"-*.apk >/dev/null 2>&1; then
  HAS_EVIDENCE=1
elif [ -s "/tmp/agent-test-blocker-$AGENT_TASK_GID.md" ]; then
  HAS_EVIDENCE=1
fi

if [ "$HAS_EVIDENCE" = 0 ]; then
  echo "BLOCKED: no in-app test evidence for task $AGENT_TASK_GID. Before creating the PR, run /build-and-test and drive the changed behavior on the sim to its terminal state (proof screenshots land at /tmp/agent-proof-$AGENT_TASK_GID-NN-<slug>.png). For a gui-dependency repo this includes the gui integration test. If a playbook-sanctioned blocker genuinely applies (provider halt; a funded attempt hit a documented crash; a funded attempt produced a TRUE loss of principal — fees/slippage never count; repo is not a gui dependency), write the specific justification to /tmp/agent-test-blocker-$AGENT_TASK_GID.md and retry — the note is audited. NOT valid blockers: 'no funds' (swap-to-fund per the playbook); anticipated loss risk (fees/slippage are budgeted at \$15 equivalent per run; blocked-ness is established by ATTEMPTING, never predicted); task scope ('deliverable is dep-repo only', 'prototype', 'gui wiring deferred' — local gui-worktree wiring is test scaffolding, not a production change); 'unvetted code + real funds' (small sanctioned-roster swaps through new plugins are the prescribed test)." >&2
  exit 2
fi

# ---- Check 2: duplicate-utility scan (soft, once per task) ------------------
DEDUP_FLAG="/tmp/agent-dedup-scan-$AGENT_TASK_GID"
[ -f "$DEDUP_FLAG" ] && exit 0
: > "$DEDUP_FLAG"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
TOP=$(git -C "${CWD:-/nonexistent}" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$TOP" ] || exit 0

BASE=""
for b in origin/develop origin/master origin/main; do
  BASE=$(git -C "$TOP" merge-base HEAD "$b" 2>/dev/null || true)
  [ -n "$BASE" ] && break
done
[ -n "$BASE" ] || exit 0

# Added helper definitions: new exported/top-level function-ish lines.
HELPERS=$(git -C "$TOP" diff "$BASE"...HEAD -U0 2>/dev/null \
  | grep -E '^\+\s*(export\s+)?(const|function)\s+[a-zA-Z_][a-zA-Z0-9_]*\s*(=\s*(async\s*)?\(|\()' \
  | grep -oE '(const|function)\s+[a-zA-Z_][a-zA-Z0-9_]*' \
  | awk '{print $2}' | sort -u | head -20 || true)
[ -n "$HELPERS" ] || exit 0

CHANGED_FILES=$(git -C "$TOP" diff --name-only "$BASE"...HEAD 2>/dev/null || true)

FINDINGS=""
GENERIC_HELPERS=""
for name in $HELPERS; do
  # Only helpers whose names smell general-purpose: primitive tokens, not
  # feature nouns. Split camelCase into lowercase tokens and keep the helper
  # when any token is a known cross-cutting primitive.
  tokens=$(printf '%s' "$name" | sed -E 's/([A-Z])/ \1/g' | tr 'A-Z' 'a-z')
  hit_tokens=""
  for t in $tokens; do
    case "$t" in
      encode|decode|base64|base64url|hex|utf8|hash|hmac|sha256|sha512|sign|seal|unseal|parse|normalize|sanitize|escape|retry|backoff|sleep|delay|clamp|chunk|dedupe|uniq|shuffle|format|header|cookie|uuid|random)
        hit_tokens="$hit_tokens $t" ;;
    esac
  done
  [ -n "$hit_tokens" ] || continue
  GENERIC_HELPERS="$GENERIC_HELPERS $name"
  for t in $hit_tokens; do
    # Prior art: the token appearing OUTSIDE the changed files, or in a dep name.
    art=$(grep -rli "$t" "$TOP/src" 2>/dev/null | grep -vxF -f <(printf '%s\n' "$CHANGED_FILES" | sed "s|^|$TOP/|") | head -3 || true)
    dep=$(jq -r --arg t "$t" '(.dependencies // {}) + (.devDependencies // {}) | keys[] | select(test($t))' "$TOP/package.json" 2>/dev/null | head -2 || true)
    [ -n "$art" ] && FINDINGS="$FINDINGS
  $name (token '$t'): existing usage in $(printf '%s' "$art" | sed "s|$TOP/||g" | tr '\n' ' ')"
    [ -n "$dep" ] && FINDINGS="$FINDINGS
  $name (token '$t'): declared dependency $(printf '%s' "$dep" | tr '\n' ' ') may already provide this"
  done
done
[ -n "$GENERIC_HELPERS" ] || exit 0

CONTEXT="Pre-PR duplicate-utility scan: this branch adds general-purpose helper(s):$GENERIC_HELPERS."
if [ -n "$FINDINGS" ]; then
  CONTEXT="$CONTEXT Possible prior art found (check each BEFORE creating the PR; reuse or extend instead of re-deriving, and delete the new helper if it duplicates):$FINDINGS"
else
  CONTEXT="$CONTEXT No prior art found by token grep, but verify against package.json deps and the repo's util dirs before shipping a new primitive."
fi

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
exit 0
