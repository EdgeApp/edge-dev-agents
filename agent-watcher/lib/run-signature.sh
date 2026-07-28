#!/usr/bin/env bash
# run-signature.sh: shared predicate for "is this transcript a genuine orch RUN?"
# Sourced by resume-task.sh (followup resume) and resolve-run.sh (eval manifest).
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

has_run_signature() { # $1=transcript.jsonl -> 0 iff head carries a /one-shot user message
  local sig_head
  sig_head=$(head -50 "$1" 2>/dev/null || true)
  grep -qa '"/one-shot --yolo' <<<"$sig_head"
}
