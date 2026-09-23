#!/usr/bin/env bash
# install-rc-heal.sh — arm/disarm the pinned-anchor healing pair:
#   com.jontz.tmux      KeepAlive persistent tmux server (holds the anchor sessions)
#   com.jontz.rc-heal   the healing tick, every 5 min
# Healing only: no watcher, no watchdog, no Asana. See rc-heal.sh for the policy.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LA="$HOME/Library/LaunchAgents"
TMUX_LABEL="com.jontz.tmux"
HEAL_LABEL="com.jontz.rc-heal"

# launchd hands a job a BARE environment (no HOME, minimal PATH). Bake in HOME and the
# dirs holding tmux/node/claude, or every tick fails with `command not found` while a
# hand-run tick works (the exact trap hit on the tcg-art cron, 2026-06-27).
BIN_PATH="$(cd "$(dirname "$(command -v tmux)")" && pwd -P):$(cd "$(dirname "$(command -v node)")" && pwd -P):$(cd "$(dirname "$(command -v claude)")" && pwd -P):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

case "${1:-}" in
  install)
    cat > "$LA/$TMUX_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$TMUX_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$HERE/tmux-keepalive.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$BIN_PATH</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/anchor-tmux-keepalive.log</string>
  <key>StandardErrorPath</key><string>/tmp/anchor-tmux-keepalive.log</string>
</dict>
</plist>
EOF
    cat > "$LA/$HEAL_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$HEAL_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$HERE/rc-heal.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$BIN_PATH</string>
  </dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/rc-heal.out</string>
  <key>StandardErrorPath</key><string>/tmp/rc-heal.err</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
    launchctl unload "$LA/$TMUX_LABEL.plist" 2>/dev/null || true
    launchctl load "$LA/$TMUX_LABEL.plist"
    sleep 2   # let the holder's server come up before the first heal tick
    launchctl unload "$LA/$HEAL_LABEL.plist" 2>/dev/null || true
    launchctl load "$LA/$HEAL_LABEL.plist"
    echo "armed $TMUX_LABEL (persistent tmux server) + $HEAL_LABEL (heal tick @300s)"
    ;;
  uninstall)
    launchctl unload "$LA/$HEAL_LABEL.plist" 2>/dev/null || true
    launchctl unload "$LA/$TMUX_LABEL.plist" 2>/dev/null || true
    rm -f "$LA/$HEAL_LABEL.plist" "$LA/$TMUX_LABEL.plist"
    echo "disarmed both (anchor tmux sessions are left running; kill them by hand if wanted)"
    ;;
  status)
    # Capture once: `launchctl list | grep -q` makes grep exit on the first match, and the
    # resulting SIGPIPE trips `pipefail` into a false "NOT armed" (it did, for rc-heal).
    LIST=$(launchctl list)
    grep -q "$TMUX_LABEL" <<<"$LIST" && echo "$TMUX_LABEL: armed" || echo "$TMUX_LABEL: NOT armed"
    grep -q "$HEAL_LABEL" <<<"$LIST" && echo "$HEAL_LABEL: armed (idle between ticks shows pid '-')" || echo "$HEAL_LABEL: NOT armed"
    tmux has-session -t __anchor_keepalive__ 2>/dev/null && echo "keepalive session: alive" || echo "keepalive session: MISSING"
    "$HERE/rc-heal.sh" --status
    ;;
  *) echo "usage: install-rc-heal.sh {install|uninstall|status}"; exit 2 ;;
esac
