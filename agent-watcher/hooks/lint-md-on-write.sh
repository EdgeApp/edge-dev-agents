#!/usr/bin/env bash
# lint-md-on-write.sh — PreToolUse(Write|Edit|Bash). Runs the shared no-slop
# lint at the FILE-CREATION choke point for markdown, closing the gap the
# posting boundaries cannot see: prose travels to gh/curl as `--body-file` /
# `$(cat file)` per the author file-over-args convention, so a command-string
# hook greps `$(cat r1.md)` and finds nothing. The bytes are fully visible
# exactly once before assembly — when the file is written — and every posting
# path (pr-address replies, review submits, raw `gh api --input`) starts life
# here. (2026-08-19: a PR review with a courtesy ender and a forward reference
# shipped unlinted because no boundary between Write and `gh api` ran the lint.)
#
# Coverage by vector:
#   Write  *.md outside the allowlist -> FULL mechanical lint of content
#   Edit   *.md outside the allowlist -> FRAGMENT lint of new_string (position-
#          dependent sentence-shape checks skipped; em dashes / vocabulary /
#          session links / loudness still apply)
#   Bash   command REDIRECTING into *.md outside the allowlist (heredoc, > or
#          >>) -> FRAGMENT lint of the command text (prose interleaved with
#          shell syntax, so shape checks would false-positive)
#
# MECHANICAL TIER ONLY: no --semantic here. Writes are high-frequency and md
# files legitimately hold quoted data; the judge tier runs at the posting/attach
# boundaries (pr-create, slack gate, report attach), which see final artifacts.
#
# Allowlist (never linted):
#   - internal tooling and state: ~/.cursor, ~/.claude, ~/.config, ~/.local,
#     ~/agent-evals (eval artifacts quote the slop under analysis; writing-style
#     exempts internal tooling, and the no-slop skill's own corpus is made of
#     violations)
#   - data/fixture files by NAME: basename starting raw- or data-, or containing
#     "fixture" — the sanctioned way to save fetched text or deliberate-slop
#     test corpora as .md (or just use .txt/.json, which are never linted)
#
# Fail-open on every infra error: a lint outage must never block file writes.
# Exit 2 = block (stderr -> model). Not gid-gated: interactive sessions post
# PRs and Slack messages too (same reasoning as slack-prose-gate.sh).
set -uo pipefail

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in Write|Edit|Bash) ;; *) exit 0 ;; esac

LINT="$HOME/.cursor/skills/no-slop/scripts/no-slop-lint.sh"
[ -x "$LINT" ] || exit 0

allowlisted() { # $1 = absolute-ish path; exit 0 = skip linting
  local p="$1" b
  case "$p" in
    "$HOME/.cursor/"*|"$HOME/.claude/"*|"$HOME/.config/"*|"$HOME/.local/"*|"$HOME/agent-evals/"*) return 0 ;;
    # Orch run machinery under /tmp: agent-state-<gid>.md (mid-run state file),
    # agent-run-report-*.md (its own boundary is the attach gate, which
    # AUTO-REWRITES em dashes instead of blocking — write-time blocking here
    # cost a live run two full heredoc regenerations on 2026-08-19), blocker
    # notes, plan docs. These are internal or later-gated; never block them.
    /tmp/agent-*|/private/tmp/agent-*|/tmp/plan-*|/private/tmp/plan-*) return 0 ;;
  esac
  b=$(basename "$p")
  case "$b" in raw-*|data-*|*fixture*) return 0 ;; esac
  return 1
}

TEXT="" MODE="" TARGET=""
case "$TOOL" in
  Write)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    case "$TARGET" in *.md) ;; *) exit 0 ;; esac
    allowlisted "$TARGET" && exit 0
    TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)
    MODE=""
    ;;
  Edit)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
    case "$TARGET" in *.md) ;; *) exit 0 ;; esac
    allowlisted "$TARGET" && exit 0
    TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null || true)
    MODE="--fragment"
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    [ -n "$CMD" ] || exit 0
    # A redirect into a .md target ('> x.md', '>> x.md', 'tee x.md'); heredoc
    # bodies ride inside $CMD so linting the command text covers them.
    TARGET=$(printf '%s' "$CMD" | grep -oE '(>>?|tee([[:space:]]+-a)?)[[:space:]]*"?[^"[:space:];|&]+\.md' | sed -E 's/^(>>?|tee([[:space:]]+-a)?)[[:space:]]*"?//' | head -1 || true)
    [ -n "$TARGET" ] || exit 0
    TARGET="${TARGET/#\~/$HOME}"
    case "$TARGET" in /*) ;; *) TARGET="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)/$TARGET" ;; esac
    allowlisted "$TARGET" && exit 0
    TEXT="$CMD"
    MODE="--fragment"
    ;;
esac
[ -n "$TEXT" ] || exit 0

TMP=$(mktemp /tmp/lint-md-write.XXXXXX.md) || exit 0
printf '%s\n' "$TEXT" > "$TMP"
if [ -n "$MODE" ]; then
  OUT=$("$LINT" "$TMP" "$MODE" 2>/dev/null); RC=$?
else
  OUT=$("$LINT" "$TMP" 2>/dev/null); RC=$?
fi
rm -f "$TMP"

if [ "$RC" -eq 1 ]; then
  HARD=$(printf '%s' "$OUT" | grep '^HARD' | head -6)
  echo "BLOCKED: markdown being written to $TARGET fails the shared no-slop lint (md is outward-facing prose by default). Fix these and rewrite:
$HARD
Carve-outs: internal tooling paths (~/.cursor, ~/.claude, ~/.config, ~/agent-evals) are exempt; a file that holds FETCHED TEXT AS DATA or a deliberate-slop test corpus is exempt by NAME — save it as .txt/.json, or name it raw-*/data-*/*fixture*." >&2
  exit 2
fi
exit 0
