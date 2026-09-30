#!/usr/bin/env bash
# run-signature.sh: the pattern that marks a transcript as a genuine orch RUN.
# lib/transcript-heads.js reads RUN_SIGNATURE_RE from this file and applies it
# to a transcript's first 50 lines (cached per transcript); resume-agent.sh,
# resume-task.sh, resolve-run.sh and session-index.sh all go through it.
# Single source of truth; do not copy the pattern into callers.
#
# A genuine run transcript carries an actual `/one-shot --yolo` USER message
# (a JSON string starting with it) in its head: fresh spawns open with it, and
# watcher resumes re-send it right after the resume summary. The head is
# append-only, so compaction never removes it. `resume-agent --chat` DISCUSSION
# FORKS inherit the run's first asana URL but never receive a /one-shot, so
# without this gate a chat fork (newest mtime) is mistaken for the run: followups
# resume the chat, evals grade discussion as the run.
#
# The head is LINE-based, not byte-based: a compaction/resume summary is one
# huge line, so a byte-based head truncates before the /one-shot message.
#
# /task-run is the no-PR run shape (agent_deliverable Task). Two recorded forms:
# the raw prompt string, and (newer CLI builds) the slash-command message
# `<command-name>/one-shot</command-name>\n<command-args>--yolo ...`, whose raw
# form only lands later in a `last-prompt` line, past a short head.
RUN_SIGNATURE_RE='"/(one-shot|task-run) --yolo|<command-name>/(one-shot|task-run)</command-name>[^"]{0,8}<command-args>--yolo'
