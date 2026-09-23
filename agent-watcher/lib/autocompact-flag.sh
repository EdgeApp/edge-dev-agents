#!/usr/bin/env bash
# autocompact-flag.sh — Print the `--autocompact <window>` flag every claude spawn
# on this box passes (orch runs, chat sessions, rc-heal anchors, resume-agent
# resumes), or nothing when the window is "auto".
#
# Why every spawn: left at `auto`, a long session holds its whole history and
# re-sends it on every call, so cost is average context times call count and a
# long run pays its early turns hundreds of times over (measured: 12 sessions,
# ZERO compactions, one at 967k over 735 calls). Capping trades that for periodic
# compaction, which the SessionStart:compact ground-truth injection and the
# mid-run state file exist to survive.
#
# Config: asana-config.json `.watcher.autocompact_window` ("auto", or 100k-1M;
# default 200k). Spawn-time only, so a change reaches the next spawn of every
# session with no per-session override to chase. The watchdog's RC respawn path
# carries the flag over from the old argv instead of re-reading config, so a
# respawn keeps the window its session started with.
#
# Usage:  FLAG="$(~/.config/agent-watcher/lib/autocompact-flag.sh)"
#         claude $FLAG ...          # FLAG is "" or "--autocompact 200k"
set -euo pipefail
cfg="$HOME/.config/agent-watcher/asana-config.json"
win="$(jq -r '.watcher.autocompact_window // "200k"' "$cfg" 2>/dev/null || echo 200k)"
[[ -n "$win" && "$win" != "auto" ]] && printf -- '--autocompact %s' "$win"
exit 0
