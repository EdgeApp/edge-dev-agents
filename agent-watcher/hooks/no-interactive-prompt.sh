#!/usr/bin/env bash
# PreToolUse hook (matcher: AskUserQuestion). In an orchestrated autonomous agent
# session (AGENT_TASK_GID set), an interactive prompt has NO human watching it: it
# hard-stalls the headless run indefinitely, holding a slot, until someone notices.
# The watchdog only DETECTS a parked choice prompt (paneAwaitingChoice) and escalates
# after a delay — it cannot answer it. So deny AskUserQuestion outright: a --yolo run
# must pick the defensible default and proceed. The ONLY sanctioned human-input path
# is a genuine true-blocker via update-status.sh --blocked yes --reason, which the
# concession-validator gates.
#
# Scope: no-op (exit 0) unless AGENT_TASK_GID is set, so interactive use is unaffected.
# Exit 0 = allow. Exit 2 = block (stderr fed to the model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

echo "BLOCKED: AskUserQuestion is not available in an orchestrated autonomous run (AGENT_TASK_GID=$AGENT_TASK_GID). No human is watching this session, so an interactive prompt stalls it indefinitely and squats a slot. Per one-shot \`yolo-execution\`: PICK THE DEFENSIBLE DEFAULT AND PROCEED. For a 'which approach / how should I prioritize / how to spend the session' question, the default is to ATTEMPT the work — link any WIP or unpublished dep into the worktree (updot / --existing-branch), build it, and drive it; an unpublished/WIP dep or a large native migration is attemptable work, NOT a reason to ask or to declare it unachievable. The ONLY sanctioned way to request human input is a GENUINE true-blocker (yolo-true-blockers: destructive-with-no-recovery, user-only credential, no-defensible-default, dirty-tree on a non-agent branch) written via update-status.sh <gid> <status> --blocked yes --reason \"<the precise blocker>\", which the concession-validator judges against the true-blocker taxonomy. Re-decide now and continue without asking." >&2
exit 2
