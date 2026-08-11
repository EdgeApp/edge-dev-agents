#!/usr/bin/env bash
# UserPromptSubmit hook. NON-BLOCKING. Emits a ONE-LINE no-slop reminder on
# every user prompt so the rule sits at the recency end of context, where
# attention is strongest. The SessionStart refresh (inject-no-slop-reminder.sh)
# carries the full rule block but ages toward the buried end of context as the
# conversation grows; instruction-following decays with distance from the tail
# (context rot), and a long session drifts back into em dashes and courtesy
# enders with the refresh still technically in context. A per-turn line at the
# tail closes that gap for ~30 tokens per turn.
#
# Fires in EVERY session (no AGENT_TASK_GID gate): chat adherence is wanted in
# discussion sessions most of all. Never blocks, never inspects the prompt.
set -euo pipefail

cat >/dev/null 2>&1 || true   # drain the hook JSON on stdin (unused)

echo "[no-slop] Reply per ~/.cursor/skills/no-slop: zero em dashes; no courtesy enders or validation preambles; no structure announcements; lead with the answer; plain copulas; specific over general. Ordering/race/state-machine explanation: one diagram per diagram-escalation (widget if present, else mermaid fence)."

exit 0
