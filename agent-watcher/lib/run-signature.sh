#!/usr/bin/env bash
# run-signature.sh: shared predicate for "is this transcript a genuine orch RUN?"
# Sourced by resume-task.sh (followup resume), resolve-run.sh (eval manifest) and
# resume-agent.sh (candidate list; feeds the Fleet page and session-tui).
# Single source of truth; do not copy this block back into callers.
#
# A genuine run transcript carries an actual `/one-shot --yolo` USER message
# (a JSON string starting with it) in its head: fresh spawns open with it, and
# watcher resumes re-send it right after the resume summary. The head is
# append-only, so compaction never removes it. `resume-agent --chat` DISCUSSION
# FORKS inherit the run's first asana URL but never receive a /one-shot, so
# without this gate a chat fork (newest mtime) is mistaken for the run: followups
# resume the chat, evals grade discussion as the run.
#
# Implementation scars (each was a real failure; keep all three):
#   - line-based head, NOT `head -c`: a compaction/resume summary is one huge
#     line, so a byte-based head truncates before the /one-shot message
#   - captured to a var first: under pipefail, `head | grep -q` returns 141 on a
#     match (grep quits, head SIGPIPEs), which reads as no-match
#   - grep -a: BSD grep binary-detects transcript heads and silently misses

# ERE shared with session-index.sh (JS regex of the same text); keep them identical.
RUN_SIGNATURE_RE='"/(one-shot|task-run) --yolo|<command-name>/(one-shot|task-run)</command-name>[^"]{0,8}<command-args>--yolo'

has_run_signature() { # $1=transcript.jsonl -> 0 iff head carries a /one-shot user message
  local sig_head
  sig_head=$(head -50 "$1" 2>/dev/null || true)
  # /task-run is the no-PR run shape (agent_deliverable Task). Two recorded forms:
  # the raw prompt string, and (newer CLI builds) the slash-command message
  # `<command-name>/one-shot</command-name>\n<command-args>--yolo ...`, whose raw
  # form only lands later in a `last-prompt` line, past a short head.
  grep -qaE "$RUN_SIGNATURE_RE" <<<"$sig_head"
}
