#!/usr/bin/env bash
# mem-trace-persistent.sh — One-shot memory snapshot.
#
# Invoked by launchd every 30s. Writes ONE timestamped line per invocation to a
# daily-rotated log under ~/.config/agent-watcher/oom-repro/logs/.
#
# Designed to add zero overhead between ticks (exits immediately) and ~10MB
# peak transient during the tick (vm_stat + ps + a few awks). No node, no
# python, no curl.
#
# Logs older than 7 days are auto-deleted on each tick.
#
# Line schema (one line per tick):
#   ts=HH:MM:SS load1=N load5=N procs=N freeMB=N inactiveMB=N wiredMB=N \
#     compressorMB=N swapoutsTotal=N top=<10 RSS entries> claude=<summary>
#
# Each top entry is "RSSMB=procname".
#
# claude= field captures Claude.app helper CPU + RSS, since the prior session
# showed renderer pegging at 34-45% CPU as the conversation DOM grew (separate
# from memory pressure). Format:
#   claude=ren=PCT%/RSSM gpu=PCT%/RSSM main=PCT%/RSSM tot=PCT%/RSSM n=N
# (empty if Claude.app isn't running)

set -u

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/oom-repro/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/trace-$(date +%Y-%m-%d).log"

# Rotate: delete trace logs older than 7 days. Cheap to do every tick.
find "$LOG_DIR" -name "trace-*.log" -type f -mtime +7 -delete 2>/dev/null

PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)

# Capture vm_stat once, parse multiple keys from the same blob.
VM=$(vm_stat 2>/dev/null)

vm_mb() {
  echo "$VM" | awk -v k="$1" -v ps="$PAGE_SIZE" '
    $0 ~ k { gsub("\\.", "", $NF); printf "%d", ($NF * ps) / 1024 / 1024; exit }
  '
}

TS=$(date +%H:%M:%S)
UP=$(uptime)
LOAD1=$(echo "$UP" | awk -F'load averages:' '{print $2}' | awk '{print $1}')
LOAD5=$(echo "$UP" | awk -F'load averages:' '{print $2}' | awk '{print $2}')
PROCS=$(ps -ax 2>/dev/null | wc -l | tr -d ' ')

FREE_MB=$(vm_mb "Pages free")
INACTIVE_MB=$(vm_mb "Pages inactive")
WIRED_MB=$(vm_mb "Pages wired down")
COMPRESSOR_MB=$(vm_mb "Pages occupied by compressor")
SWAPOUTS=$(echo "$VM" | awk '/Swapouts:/ {gsub("\\.",""); print $NF; exit}')

# macOS memory-pressure level: 1=NORMAL 2=WARN 4=CRITICAL. Pollable early-warning
# signal (research-confirmed 2026-05-28). Cheap single sysctl read.
PRESSURE=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "?")
# cli process count — the canary for a recursive-claude-spawn fork chain (the
# confirmed OOM cause). A healthy box has a handful; a runaway hits hundreds fast.
CLI_COUNT=$(ps -axo comm 2>/dev/null | grep -c '^cli$')

# Top 10 RSS consumers, compact format.
TOP=$(ps -axo rss,comm 2>/dev/null | sort -k1 -nr | head -10 | awk '{
  cmd=$2; n=split(cmd, a, "/"); short=a[n]
  printf "%dM=%s ", $1/1024, short
}')

# Claude.app summary — capture renderer + GPU + main + totals. Uses a single
# ps invocation; we identify processes by their /Applications/Claude.app/ path.
# Renderer = main app renderer (largest renderer by RSS, since multiple
# renderers exist for popovers/preview/etc).
CLAUDE=$(ps -axo pid,pcpu,rss,command 2>/dev/null | awk '
  /\/Applications\/Claude\.app\// {
    pcpu=$2; rss=$3
    # classify by command segment
    role="other"
    if ($0 ~ /Helper \(Renderer\)/) role="renderer"
    else if ($0 ~ /type=gpu-process/) role="gpu"
    else if ($0 ~ /MacOS\/Claude /||$0 ~ /MacOS\/Claude$/) role="main"
    else if ($0 ~ /Helper.*type=utility/) role="utility"
    else if ($0 ~ /Helper.*type=/) role="helperX"

    n[role]++
    cpu[role]+=pcpu
    mem[role]+=rss
    # track max renderer for ren= (biggest = main UI)
    if (role=="renderer" && rss>max_ren_rss) { max_ren_rss=rss; max_ren_cpu=pcpu }

    tot_cpu+=pcpu; tot_rss+=rss; tot_n++
  }
  END {
    if (tot_n==0) { print ""; exit }
    printf "ren=%.0f%%/%dM gpu=%.0f%%/%dM main=%.0f%%/%dM tot=%.0f%%/%dM n=%d",
      max_ren_cpu+0, max_ren_rss/1024,
      cpu["gpu"]+0,  mem["gpu"]/1024,
      cpu["main"]+0, mem["main"]/1024,
      tot_cpu,       tot_rss/1024,
      tot_n
  }
')

echo "ts=$TS load1=$LOAD1 load5=$LOAD5 procs=$PROCS freeMB=$FREE_MB inactiveMB=$INACTIVE_MB wiredMB=$WIRED_MB compressorMB=$COMPRESSOR_MB swapoutsTotal=$SWAPOUTS pressure=$PRESSURE cliCount=$CLI_COUNT top=$TOP claude=$CLAUDE" >> "$LOG_FILE"
