#!/usr/bin/env bash
# fleet-ctl.sh -- entry point for lib/fleet-ctl.js (the fleet as JSON for the
# `fleet` Claude Code mod). A non-login ssh shell (`ssh eddy fleet-ctl.sh ...`)
# has no node, tmux or claude on PATH, so this sets it before handing over.
# Verbs and the JSON contract: see the header of lib/fleet-ctl.js.
source "$HOME/.config/agent-watcher/lib/launchd-env.sh"
exec node "$HOME/.config/agent-watcher/lib/fleet-ctl.js" "$@"
