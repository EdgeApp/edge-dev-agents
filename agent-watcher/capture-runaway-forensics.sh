#!/usr/bin/env bash
# capture-runaway-forensics.sh — Snapshot a runaway `cli` fork chain to pin its spawn mechanism.
#
# Called by runaway-guard.sh on EARLY detection (before the kill), or run manually:
#   capture-runaway-forensics.sh [<pgid>]
#
# Writes a timestamped report to ~/.config/agent-watcher/oom-repro/forensics/.
# Goal: while the chain's parents are still alive, capture enough to answer
# "what is spawning each new claude?" — confirming or refuting the recursive-/loop
# hypothesis. The first action is an INSTANT full `ps` snapshot to a side file so the
# parent lineage is preserved even if processes detach during the slower steps.
#
# Best-effort throughout; never exits non-zero (must not wedge the guard).

set -u
PGID="${1:-}"
DIR="$HOME/.config/agent-watcher/oom-repro/forensics"
mkdir -p "$DIR"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$DIR/runaway-$TS${PGID:+-pgid$PGID}.log"
RAW="$OUT.ps"

# [0] INSTANT snapshot — one ps call, preserves lineage before anything detaches.
ps -axo pid,ppid,pgid,stat,etime,rss,comm,command > "$RAW" 2>/dev/null

{
  echo "=== runaway forensic capture $TS ==="
  echo "host uptime: $(uptime)"
  echo "trigger pgid: ${PGID:-<none specified>}"
  page=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  vm_stat 2>/dev/null | awk -v ps="$page" '
    /Pages free/{gsub("\\.","",$NF);printf "mem: free=%dMB",$NF*ps/1024/1024}
    /occupied by compressor/{gsub("\\.","",$NF);printf " compressor=%dMB",$NF*ps/1024/1024}
    END{print ""}'
  echo "pressure: $(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null) (1=NORMAL 2=WARN 4=CRITICAL)"
  echo "swap: $(sysctl -n vm.swapusage 2>/dev/null)"

  echo
  echo "--- [1] cli counts by process group ---"
  # comm column ($7) is 'cli' for claude-code; group by pgid ($3).
  awk '$7=="cli"{n[$3]++; tot++} END{print "  total cli:", tot+0; for(g in n) print "  pgid "g": "n[g]}' "$RAW" | sort -t: -k2 -rn | head

  echo
  echo "--- [2] full tree for pgid ${PGID:-(top group)} ---"
  TARGET="$PGID"
  [ -z "$TARGET" ] && TARGET=$(awk '$7=="cli"{n[$3]++} END{m=0;for(g in n)if(n[g]>m){m=n[g];b=g}; print b}' "$RAW")
  echo "  target pgid: $TARGET"
  awk -v g="$TARGET" '$3==g{print "    "$0}' "$RAW" | head -40

  echo
  echo "--- [3] SEED: trace a chain member up to the first non-cli ancestor ---"
  # Pick the lowest-PID cli in the target group (oldest = closest to the seed).
  seed_start=$(awk -v g="$TARGET" '$7=="cli" && $3==g{print $1}' "$RAW" | sort -n | head -1)
  echo "  starting from cli pid $seed_start"
  cur="$seed_start"
  for _ in $(seq 1 200); do
    line=$(awk -v p="$cur" '$1==p{print; exit}' "$RAW")
    [ -z "$line" ] && { echo "    pid $cur not in snapshot (detached)"; break; }
    comm=$(echo "$line" | awk '{print $7}')
    ppid=$(echo "$line" | awk '{print $2}')
    if [ "$comm" != "cli" ]; then
      echo "    >>> SEED ANCESTOR (first non-cli): "
      echo "$line" | sed 's/^/      /'
      echo "    >>> its parent:"
      awk -v p="$ppid" '$1==p{print "      "$0}' "$RAW"
      break
    fi
    [ "$ppid" -le 1 ] && { echo "    chain root pid $cur orphaned to launchd (seed already exited)"; echo "$line" | sed 's/^/      /'; break; }
    cur="$ppid"
  done

  echo
  echo "--- [4] any live claude --resume / --rc / one-shot / loop process (the real launcher) ---"
  # These keep their real argv (not masked to 'cli'); they reveal the launch intent.
  awk '/claude (--|[a-z])/ && !/awk|grep|capture-runaway/{print "    "$0}' "$RAW" | grep -iE "resume|--rc|one-shot|--yolo|loop|babysit" | head -10
  echo "    (none above = launcher already exited / masked)"

  echo
  echo "--- [5] SCHEDULER state (tests the cron / scheduled-respawn hypothesis) ---"
  echo "  system crontab:"; crontab -l 2>/dev/null | grep -iE "claude|cli|agent|loop" | sed 's/^/    /' || echo "    (none)"
  echo "  launchd jobs (claude/agent):"; launchctl list 2>/dev/null | grep -iE "claude|jontz|agent" | sed 's/^/    /'
  echo "  at-queue:"; atq 2>/dev/null | head | sed 's/^/    /' || echo "    (atq empty/unavailable)"
  echo "  NOTE: Claude Code /loop & /schedule crons are stored in claude state, not OS cron —"
  echo "        check CronList from a claude session separately if OS scheduler is clean."

  echo
  echo "--- [6] tmux sessions + pane launch commands ---"
  tmux list-panes -a -F "  #{session_name} pane_pid=#{pane_pid} start=#{pane_start_command}" 2>/dev/null | head -20 || echo "  (no tmux server)"

  echo
  echo "--- [7] which worktree/session owns the chain (cwd of a sample cli) ---"
  sample=$(awk -v g="$TARGET" '$7=="cli" && $3==g{print $1; exit}' "$RAW")
  if [ -n "$sample" ]; then
    cwd=$(lsof -a -p "$sample" -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//')
    echo "  cli $sample cwd: ${cwd:-<unreadable>}"
    # cwd like ~/git/.agent-worktrees/<gid>/<repo> → find the session jsonl + tail it
    gid=$(echo "$cwd" | grep -oE 'agent-worktrees/[0-9]+' | grep -oE '[0-9]+')
    if [ -n "$gid" ]; then
      echo "  task gid: $gid"
      sess=$(ls -t "$HOME/.claude/projects/"*"agent-worktrees-$gid"*/*.jsonl 2>/dev/null | head -1)
      if [ -n "$sess" ]; then
        echo "  session: $sess"
        echo "  --- last 3 events of that session ---"
        tail -3 "$sess" 2>/dev/null | cut -c1-300 | sed 's/^/    /'
      fi
    fi
  fi

  echo
  echo "--- [8] stack sample of one chain proc (dyld_start = held pre-exec; main = running) ---"
  [ -n "$sample" ] && sample "$sample" 1 2>&1 | grep -E "Call graph|_dyld_start|main \(|Thread_" | head -6 | sed 's/^/    /'

  echo
  echo "=== end capture $TS — raw ps at $RAW ==="
} > "$OUT" 2>&1

echo "$OUT"
