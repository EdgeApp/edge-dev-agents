#!/usr/bin/env bash
# tmux-keepalive.sh — hold ONE tmux server alive for the pinned anchors.
#
# WHY: launchd tears down a job's context when the job exits, and reaps the tmux
# server that job started — so a session created by the 5-minute rc-heal tick dies
# with the tick (proven on the tcg-art orch: cron-spawned agents died ~60s in while
# an off-cron spawn of the same agent ran 17 min; AbandonProcessGroup did NOT fix it,
# because the server daemonizes out of the PGID but is still reaped with the context).
#
# FIX: this script runs as a KeepAlive LaunchAgent (com.jontz.tmux). While it loops,
# launchd holds ITS context — and the tmux server — alive. rc-heal.sh's
# `tmux new-session` then attaches to this already-running server, so anchor sessions
# are children of the persistent server, not of a dying tick, and survive across ticks
# and logins.
set -u
SESSION="__anchor_keepalive__"
while true; do
  tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" 'while true; do sleep 86400; done'
  sleep 30
done
