#!/usr/bin/env bash
# cap-skill-slice-size.sh -- PreToolUse(Write|Edit) and PostToolUse(Bash). Keeps
# each split skill's core SKILL.md and rule slices (one-shot, pr-land and
# build-and-test; lib/skill-slice-size.js lists the files) under 20,000
# characters.
#
# Why: Claude Code re-attaches an invoked skill after compaction, cut at 20,000
# characters, which is why those skills are split into a core plus references/
# slices. The *-slices.test.py contract tests check the cap, but only when
# someone runs the hook suite, so a rule added to a nearly full slice shipped
# over the cap and stayed there unnoticed. This hook moves the check to the
# write itself, where the author still has the context to decide what moves.
#
# Vectors:
#   Write  denies when the new content is at or over the cap and larger than the
#          file on disk (a write that shrinks an over-cap file is the fix).
#   Edit   the same, on the file with old_string replaced by new_string.
#   Bash   the result is not knowable before the command runs, so PostToolUse
#          checks the capped files the command names and exits 2 with the
#          overage, which the agent reads as feedback; the write has happened.
#
# Scope: every session. Skills are edited in chat sessions as often as in runs.
# SKILL_SLICE_LIMIT overrides the cap for tests. Exit 0 allow, 2 deny/report.
set -uo pipefail
exec node "$HOME/.config/agent-watcher/hooks/lib/skill-slice-size.js"
