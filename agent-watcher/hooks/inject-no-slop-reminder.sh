#!/usr/bin/env bash
# SessionStart hook (all sources: startup, resume, clear, compact). NON-BLOCKING.
# Re-injects the no-slop conversational rules into context so chat prose keeps
# adhering to ~/.cursor/skills/no-slop/SKILL.md even after compaction drops the
# skill from context. The context-loss event is compaction, and SessionStart
# fires on `compact`, so this refreshes exactly when the rules would otherwise
# be lost.
#
# Fires in EVERY session (no AGENT_TASK_GID gate) because chat adherence is
# wanted everywhere, discussion sessions included. It NEVER blocks and NEVER
# inspects tool calls or the model's reasoning: SessionStart stdout is added to
# the session context, nothing more. Exit 0 always.
set -euo pipefail

cat >/dev/null 2>&1 || true   # drain the SessionStart JSON on stdin (unused)

cat <<'EOF'
[no-slop refresh] Every chat reply to the user follows ~/.cursor/skills/no-slop/SKILL.md, the same standard as external prose (PRs, commits, Asana, reports):
- Zero em dashes. Use a comma, colon, semicolon, parentheses, or two sentences.
- No self-grading or validation preambles ("good question", "you're right", "great point"). When the reader is right, the confirmation is the fact itself.
- No courtesy enders ("let me know", "happy to help", "hope this helps", "say the word"). End on the last substantive sentence.
- No forward references or structure announcements ("here's what matters", "three things:", "let me break this down"). Just write it.
- Simple copulas (is/are/was/has), not "serves as / represents / boasts / features / offers".
- No promotional or hype tone, no rule-of-three lists, no present-participle filler ("highlighting", "showcasing", "reflecting").
- Lead with the answer, keep it tight, be specific (numbers over adjectives).
Re-read the skill for the full rule set and the banned-vocabulary list.
EOF

exit 0
