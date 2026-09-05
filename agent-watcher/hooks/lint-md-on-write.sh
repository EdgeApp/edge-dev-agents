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
#   Write  *.md outside the allowlist -> FULL mechanical lint of content when
#          the file is new; when it already exists, FRAGMENT lint of the lines
#          the write ADDS (a whole-file rewrite must not be blocked by prose
#          already on disk, e.g. a banned word deep in a changelog's history)
#   Edit   *.md outside the allowlist -> FRAGMENT lint of new_string (position-
#          dependent sentence-shape checks skipped; em dashes / vocabulary /
#          session links / loudness still apply)
#   Bash   command WRITING a *.md outside the allowlist (redirect, tee, sed -i,
#          perl -pi; lib/md-write-target.sh owns the vector list) -> FRAGMENT
#          lint of the command text (prose interleaved with shell syntax, so
#          shape checks would false-positive)
#
# CHANGELOG.md targets additionally run the changelog skill's entry-shape lint
# (~/.cursor/skills/changelog/scripts/changelog-entry-lint.sh): length cap,
# mechanism-tail connectives, second sentences. A full Write is diffed against
# the file on disk so only NEW lines are judged; existing verbose entries are
# history, not this write's fault. The skill-read gate for CHANGELOG.md lives
# in require-skill-for-file.sh, not here.
#
# MECHANICAL TIER ONLY: no --semantic here. Writes are high-frequency and md
# files legitimately hold quoted data; the judge tier runs at the posting/attach
# boundaries (pr-create, slack gate, report attach), which see final artifacts.
#
# SKILL-READ GATE (orch runs only): a full Write of outward prose is the moment
# the writer needs the no-slop contract in context, and prose has no companion
# script for require-skill-read-for-scripts.sh to key on. So the first such
# Write in a segment without the no-slop marker is denied with the full skill
# body (lib/skill-read-gate.sh); the retry passes this check and is then
# linted. Interactive sessions (no AGENT_TASK_GID) skip the read check.
#
# Allowlist (never linted):
#   - internal tooling and state: ~/.cursor, ~/.claude, ~/.config, ~/.local,
#     ~/agent-evals (eval artifacts quote the slop under analysis; writing-style
#     exempts internal tooling). EXCEPTION: ~/.cursor/skills/no-slop itself IS
#     linted, so the literature agents read for the rules cannot carry the
#     patterns it bans; its deliberate-slop corpus is exempt by fixture NAME.
#   - data/fixture files by NAME: basename starting raw- or data-, or containing
#     "fixture" — the sanctioned way to save fetched text or deliberate-slop
#     test corpora as .md (or just use .txt/.json, which are never linted)
#   - agent skills ANYWHERE (any path segment `skills/<name>/SKILL.md`, and
#     anything under a `.claude/skills/` dir): skills are agent-facing tooling
#     wherever they live (repo-local skills, the site-orch install), and the
#     only skill that must itself read clean is no-slop (operator ruling
#     2026-09-04). The no-slop exception above still wins.
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
  b=$(basename "$p")
  case "$b" in raw-*|data-*|*fixture*) return 0 ;; esac
  case "$p" in
    "$HOME/.cursor/skills/no-slop/"*) return 1 ;;
    */skills/*/SKILL.md|*/.claude/skills/*) return 0 ;;
    "$HOME/.cursor/"*|"$HOME/.claude/"*|"$HOME/.config/"*|"$HOME/.local/"*|"$HOME/agent-evals/"*) return 0 ;;
    # Orch run machinery under /tmp: agent-state-<gid>.md (mid-run state file),
    # agent-run-report-*.md (its own boundary is the attach gate, which
    # AUTO-REWRITES em dashes instead of blocking — write-time blocking here
    # cost a live run two full heredoc regenerations on 2026-08-19), blocker
    # notes, plan docs. These are internal or later-gated; never block them.
    /tmp/agent-*|/private/tmp/agent-*|/tmp/plan-*|/private/tmp/plan-*) return 0 ;;
  esac
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
    if [ -f "$TARGET" ]; then
      TEXT=$(comm -13 <(sort -u "$TARGET") <(printf '%s\n' "$TEXT" | sort -u) 2>/dev/null || printf '%s' "$TEXT")
      MODE="--fragment"
    fi
    # Skill-read gate (see header). Only full Writes: an Edit or heredoc
    # fragment presupposes a document already written under the gate.
    if [ -n "${AGENT_TASK_GID:-}" ] && [ -f "$HOME/.config/agent-watcher/hooks/lib/skill-read-gate.sh" ]; then
      . "$HOME/.config/agent-watcher/hooks/lib/skill-read-gate.sh"
      if [ -n "$(skill_read_missing no-slop)" ]; then
        {
          echo "BLOCKED: $TARGET is outward prose and the no-slop contract has not entered this session's context yet. The full skill is below; it now counts as read. Rewrite the file against it, then retry the Write (the retry is linted)."
          skill_read_deliver no-slop
        } >&2
        exit 2
      fi
    fi
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
    # Target from the mention-stripped view (heredoc bodies and quoted spans
    # blanked): a command that QUOTES 'sed -i x.md' in a report is not a write.
    # The lint itself runs on the raw text, since the heredoc body IS the prose.
    [ -f "$HOME/.config/agent-watcher/hooks/lib/md-write-target.sh" ] || exit 0
    . "$HOME/.config/agent-watcher/hooks/lib/md-write-target.sh"
    CMD_M=$(printf '%s' "$CMD" | "$HOME/.config/agent-watcher/hooks/strip-cmd-mentions.sh" 2>/dev/null || printf '%s' "$CMD")
    TARGET=$(bash_write_target "$CMD_M" "$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)")
    [ -n "$TARGET" ] || exit 0
    allowlisted "$TARGET" && exit 0
    TEXT="$CMD"
    MODE="--fragment"
    ;;
esac
[ -n "$TEXT" ] || exit 0

# Trailing Xs required: macOS mktemp treats an embedded-X template
# (name.XXXXXX.md) as a LITERAL filename — concurrent sessions collide.
TMP=$(mktemp /tmp/lint-md-write.XXXXXX) || exit 0
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

# CHANGELOG entry shape (see header). Judged on the lines this write ADDS
# (Write over an existing file is already reduced to them above).
CL_LINT="$HOME/.cursor/skills/changelog/scripts/changelog-entry-lint.sh"
if [ "$(basename "$TARGET")" = "CHANGELOG.md" ] && [ -x "$CL_LINT" ]; then
  CL_FLAG=""; [ "$TOOL" = "Bash" ] && CL_FLAG="--fragment"
  CL_OUT=$(printf '%s\n' "$TEXT" | "$CL_LINT" $CL_FLAG 2>/dev/null); CL_RC=$?
  if [ "$CL_RC" -eq 1 ]; then
    echo "BLOCKED: CHANGELOG entry shape (changelog skill \`entry-shape\`). One line, one clause, under ${CHANGELOG_MAX_LEN:-140} chars, outcome only; the mechanism and the why belong in the commit body:
$(printf '%s' "$CL_OUT" | grep '^HARD' | head -6)" >&2
    exit 2
  fi
fi
exit 0
