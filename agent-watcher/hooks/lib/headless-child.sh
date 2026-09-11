#!/usr/bin/env bash
# headless-child.sh -- shared guard: is this hook running inside a HEADLESS
# `claude -p` child spawned by a script (the no-slop semantic judge at attach /
# post boundaries, pr-address's judge, the completion judge, ad-hoc helpers)?
# Such children inherit the run's environment (AGENT_TASK_GID, TMUX_PANE) and
# fire the same hooks as the run itself, but their "prompt" is a script's
# payload, never a human typing; a hook that reads it as a human stamps a hold
# or a presence mark on the parent run. Detection: walk up to 4 ancestors; only the EXECUTABLE
# token decides whether an ancestor is the claude CLI (wrapper shells quote
# arbitrary text in argv), and only a bare -p/--print marks print mode.
# Source this file, then: `if headless_child; then exit 0; fi`.
headless_child() {
  local pp="$PPID" pcmd exe _
  for _ in 1 2 3 4; do
    pcmd=$(ps -o command= -p "$pp" 2>/dev/null) || return 1
    exe="${pcmd%% *}"
    case "$exe" in
      claude|*/claude)
        case " $pcmd " in
          *" -p "*|*" --print "*|*" --print") return 0 ;;
        esac
        return 1 ;;
    esac
    pp=$(ps -o ppid= -p "$pp" 2>/dev/null | tr -d ' ')
    [ -n "$pp" ] && [ "$pp" != 0 ] || return 1
  done
  return 1
}
