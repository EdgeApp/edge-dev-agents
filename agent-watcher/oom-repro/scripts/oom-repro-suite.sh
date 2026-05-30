#!/usr/bin/env bash
# oom-repro-suite.sh — Run controlled OOM-related benchmarks.
#
# Usage:
#   oom-repro-suite.sh                  # default: T0 T1 T2 (cheap subset)
#   oom-repro-suite.sh T0 T1 T2 T3 T4   # named tests
#   oom-repro-suite.sh all              # everything except T6 (which is open-ended)
#
# Tests:
#   T0  baseline snapshot
#   T1  process-spawn stress (500/1000/2000 parallel `node -e exit`)
#   T2  uncached-binary spawn (100 unique never-seen binaries)
#   T3  cold Metro boot timing (kills metro, clears cache, times --reset-cache boot)
#   T4  cold sim boot timing (shutdown all, boot iOS 18 iPhone 16 Pro Max, time to SpringBoard)
#   T5  Edge launch via simctl (NO Xcode/lldb attached, 90s observation)
#   T6  long-form observation (runs T3+T4+T5 then idles; user works normally for 30+ min)
#   T7  Claude.app renderer characterization (60s sampling at 2s, before/after annotated)
#   T7-open  Claude.app sampling with a guided action: open a long historic session
#   T8  Suspect-process memory tracker — 5min × 10s sampling of lldb-rpc-server, sim, Edge, mds_stores, syspolicyd
#   T9  Real-workflow Xcode clean+build timing (edge-react-gui)
#
# QUARANTINED:
#   T2  was originally "SentinelOne cold-verdict tax" but turned out to be macOS code-signature
#       verification of moved Apple binaries — unrelated to real workflows. Defaults dropped to
#       N=3 and the test prints a warning. Don't run unless investigating signatures.
#
# Each test writes a dated log under ~/.config/agent-watcher/oom-repro/logs/tests/
# The persistent trace (com.jontz.mem-trace) keeps logging across all tests.
#
# Exit codes:
#   0 = all requested tests completed (PASS/FAIL signal is in the log content, not exit code)
#   1 = setup error (missing tools, etc.)
#   2 = a test prerequisite was unmet (e.g. no booted sim for T5)

set -u

OOM_DIR="$HOME/.config/agent-watcher/oom-repro"
LOG_DIR="$OOM_DIR/logs/tests"
mkdir -p "$LOG_DIR"

# ─── Prereq checks ───────────────────────────────────────────────────────────
for cmd in vm_stat uptime ps xcrun node python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing: $cmd"; exit 1; }
done

# ─── Helpers ─────────────────────────────────────────────────────────────────
elapsed_ms() { python3 -c "import time;print(int(time.time()*1000))"; }

snapshot() {
  local label="$1"
  local out="$2"
  local page_size
  page_size=$(sysctl -n hw.pagesize)
  {
    echo "=== $label ==="
    date +"%Y-%m-%d %H:%M:%S"
    uptime
    echo
    echo "--- vm_stat (MB) ---"
    vm_stat | awk -v ps="$page_size" '
      /Pages free:/        { gsub("\\.","",$NF); printf "  free        = %d MB\n", $NF*ps/1024/1024 }
      /Pages inactive:/    { gsub("\\.","",$NF); printf "  inactive    = %d MB\n", $NF*ps/1024/1024 }
      /Pages wired down:/  { gsub("\\.","",$NF); printf "  wired       = %d MB\n", $NF*ps/1024/1024 }
      /Pages occupied by compressor:/ { gsub("\\.","",$NF); printf "  compressor  = %d MB\n", $NF*ps/1024/1024 }
      /Compressions:/      { gsub("\\.","",$NF); printf "  compressions= %d (cumulative)\n", $NF }
      /Swapouts:/          { gsub("\\.","",$NF); printf "  swapouts    = %d pages (%d MB cumulative)\n", $NF, $NF*ps/1024/1024 }
    '
    echo
    echo "--- top 15 RSS ---"
    ps -axo rss,comm | sort -k1 -nr | head -15 | awk '{cmd=$2; n=split(cmd,a,"/"); short=a[n]; printf "  %5dMB  %s\n", $1/1024, short}'
    echo
    echo "--- process counts ---"
    echo "  total: $(ps -ax | wc -l | tr -d ' ')"
    echo "  node*: $(ps -axo comm | grep -c '^.*node$\|^.*\.bin/node\|/node$')"
    echo "  simruntime: $(ps -axo command | grep -ic simruntime)"
    echo "  sentinel*: $(ps -axo command | grep -ic sentinel)"
    echo "  mds*: $(ps -axo command | grep -ic mds)"
    echo
  } >> "$out"
}

# ─── Tests ───────────────────────────────────────────────────────────────────

T0_baseline() {
  local LOG="$LOG_DIR/T0-baseline-$(date +%Y%m%d-%H%M%S).log"
  echo ">> T0 baseline → $LOG"
  snapshot "T0 baseline" "$LOG"
  echo "T0 done."
}

T1_node_spawn() {
  local LOG="$LOG_DIR/T1-node-spawn-$(date +%Y%m%d-%H%M%S).log"
  echo ">> T1 node spawn stress → $LOG"
  snapshot "T1 BEFORE" "$LOG"
  for N in 500 1000 2000; do
    echo "  wave: $N parallel node spawns..."
    local t0=$(elapsed_ms)
    (for _ in $(seq 1 "$N"); do node -e 'process.exit(0)' & done; wait) 2>/dev/null
    local t1=$(elapsed_ms)
    {
      echo
      echo "--- T1 wave: $N parallel node -e exit ---"
      echo "elapsed_ms = $((t1 - t0))"
      echo "per_process_ms_amortized = $(( (t1 - t0) / N ))"
    } >> "$LOG"
    sleep 5
  done
  snapshot "T1 AFTER" "$LOG"
  echo "T1 done."
}

T2_uncached_spawn() {
  # T2 — QUARANTINED. Originally hypothesized to measure SentinelOne's cold-binary
  # verdict tax. Investigation 2026-05-27 proved this is actually macOS code-signature
  # verification of moved Apple binaries, NOT an EDR issue. Re-signing the copy with
  # `codesign --sign -` makes the hang disappear, conclusively. SentinelOne stop also
  # had no effect. Real workflows don't clone Apple bootstrap binaries, so this test
  # doesn't model anything that happens in normal use.
  #
  # Default count dropped to 3 to minimize zombie creation if accidentally invoked.
  # Each hung process becomes a permanent UE-state zombie (SIGKILL-proof, reboot only).
  echo "  ⚠ WARNING: T2 is quarantined — it measures a macOS code-signing edge case,"
  echo "    NOT a real OOM-relevant issue. Each invocation creates ~N permanent UE zombies."
  echo "    Continue only if you specifically want to demo / re-verify the finding."
  local N=${OOM_T2_COUNT:-3}
  local TIMEOUT=${OOM_T2_TIMEOUT:-10}  # seconds; bail rather than hanging the suite
  local LOG="$LOG_DIR/T2-uncached-$(date +%Y%m%d-%H%M%S).log"
  echo ">> T2 uncached-binary spawn (N=$N, timeout=${TIMEOUT}s) → $LOG"
  snapshot "T2 BEFORE" "$LOG"
  local BIN_DIR="/tmp/oom-repro-uncached"
  rm -rf "$BIN_DIR"; mkdir -p "$BIN_DIR"
  for i in $(seq 1 "$N"); do cp /bin/echo "$BIN_DIR/x$i"; done

  local t0; t0=$(elapsed_ms)
  local pids=()
  for i in $(seq 1 "$N"); do
    "$BIN_DIR/x$i" >/dev/null 2>&1 &
    pids+=($!)
  done

  # Poll for completion up to TIMEOUT seconds. Don't use `wait` because
  # SentinelOne-stuck procs in UE state would block it indefinitely.
  local deadline=$(( $(date +%s) + TIMEOUT ))
  local done_count=0 stuck_count=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    done_count=0
    for p in "${pids[@]}"; do
      kill -0 "$p" 2>/dev/null || done_count=$((done_count + 1))
    done
    [ "$done_count" -eq "$N" ] && break
    sleep 0.2
  done
  local t1; t1=$(elapsed_ms)
  stuck_count=$(( N - done_count ))

  {
    echo
    echo "--- T2: $N unique never-seen binaries spawned in parallel ---"
    if [ "$stuck_count" -eq 0 ]; then
      echo "elapsed_ms = $((t1 - t0))"
      echo "per_process_ms_amortized = $(( (t1 - t0) / N ))"
      echo "verdict: T2 completed cleanly (no stuck procs)"
    else
      echo "elapsed_ms = TIMEOUT after ${TIMEOUT}s"
      echo "stuck_procs = $stuck_count of $N"
      echo "VERDICT: SentinelOne held $stuck_count binaries in UE state — confirmed cold-verdict tax."
      echo "Note: stuck procs are SIGKILL-proof and persist until reboot."
      echo "  PIDs: ${pids[*]}"
    fi
    echo "(comparison: T1 cached node baseline = ~3ms per proc. If T2 >> T1 OR has stuck procs, SentinelOne is the cost.)"
  } >> "$LOG"

  # Best-effort cleanup of the binary copies (running procs hold them open
  # but inode unlink is fine; we don't want leftover x* files).
  rm -rf "$BIN_DIR"
  snapshot "T2 AFTER" "$LOG"
  echo "T2 done. $done_count/$N completed, $stuck_count stuck."
  [ "$stuck_count" -gt 0 ] && echo "  ⚠ $stuck_count unkillable UE zombies remain until reboot."
}

T3_cold_metro() {
  local LOG="$LOG_DIR/T3-cold-metro-$(date +%Y%m%d-%H%M%S).log"
  echo ">> T3 cold Metro boot → $LOG"
  snapshot "T3 BEFORE" "$LOG"
  pkill -f "react-native start" 2>/dev/null
  sleep 2
  rm -rf ~/Library/Caches/com.facebook.ReactNativeBuild 2>/dev/null
  if ! [ -d ~/git/edge-react-gui ]; then
    echo "  edge-react-gui not at expected path; skipping T3" | tee -a "$LOG"
    return
  fi
  rm -f /tmp/metro-boot.log
  local t0=$(elapsed_ms)
  (cd ~/git/edge-react-gui && npx react-native start --reset-cache > /tmp/metro-boot.log 2>&1) &
  local metro_pid=$!
  local ready=0
  for _ in $(seq 1 60); do
    if grep -q -i "Welcome to Metro\|metro waiting\|Loading dependency graph" /tmp/metro-boot.log 2>/dev/null; then
      local t1=$(elapsed_ms)
      {
        echo
        echo "--- T3: Metro ready ---"
        echo "elapsed_ms = $((t1 - t0))"
        echo "metro_pid = $metro_pid"
      } >> "$LOG"
      ready=1
      break
    fi
    sleep 2
  done
  if [ "$ready" = 0 ]; then
    {
      echo
      echo "--- T3: Metro NEVER readied within 120s ---"
      echo "metro_pid = $metro_pid (still running — pkill -f 'react-native start' to stop)"
      tail -30 /tmp/metro-boot.log
    } >> "$LOG"
  fi
  echo "  Metro left running (PID $metro_pid). pkill -f 'react-native start' to stop."
  snapshot "T3 AFTER" "$LOG"
  echo "T3 done."
}

T4_cold_sim_boot() {
  local LOG="$LOG_DIR/T4-cold-sim-$(date +%Y%m%d-%H%M%S).log"
  echo ">> T4 cold sim boot → $LOG"
  snapshot "T4 BEFORE" "$LOG"
  xcrun simctl shutdown all 2>&1 | head -5
  sleep 5
  local UDID
  UDID=$(xcrun simctl list devices 2>/dev/null | awk '/-- iOS 18/,/^-- /' | grep "iPhone 16 Pro Max" | head -1 | grep -oE '[0-9A-F-]{36}')
  if [ -z "$UDID" ]; then
    echo "  iPhone 16 Pro Max on iOS 18 not found; skipping T4" | tee -a "$LOG"
    return
  fi
  echo "  booting $UDID..."
  local t0=$(elapsed_ms)
  xcrun simctl boot "$UDID" 2>&1
  local ready=0
  for _ in $(seq 1 60); do
    if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q SpringBoard; then
      local t1=$(elapsed_ms)
      {
        echo
        echo "--- T4: SpringBoard up ---"
        echo "elapsed_ms = $((t1 - t0))"
        echo "sim_child_processes = $(ps -axo command | grep -ic simruntime)"
      } >> "$LOG"
      ready=1
      break
    fi
    sleep 2
  done
  open -a Simulator
  if [ "$ready" = 0 ]; then
    {
      echo
      echo "--- T4: SpringBoard NEVER readied within 120s ---"
    } >> "$LOG"
  fi
  snapshot "T4 AFTER" "$LOG"
  echo "T4 done."
}

T5_edge_launch() {
  local LOG="$LOG_DIR/T5-edge-launch-$(date +%Y%m%d-%H%M%S).log"
  echo ">> T5 Edge launch (simctl, no Xcode) → $LOG"
  snapshot "T5 BEFORE" "$LOG"
  local UDID
  UDID=$(xcrun simctl list devices booted 2>/dev/null | grep "iPhone 16 Pro Max" | head -1 | grep -oE '[0-9A-F-]{36}')
  if [ -z "$UDID" ]; then
    echo "  no booted iPhone 16 Pro Max; run T4 first." | tee -a "$LOG"
    return 2
  fi
  xcrun simctl launch "$UDID" co.edgesecure.app 2>&1 | tee -a "$LOG"
  sleep 2
  for t in 10 30 60 90; do
    sleep $((t - 2))  # cumulative wait
    local edge_rss
    edge_rss=$(ps -axo rss,command | grep "/Edge\.app/.*Edge$" | grep -v grep | head -1 | awk '{printf "%dMB", $1/1024}')
    local lldb_rss
    lldb_rss=$(ps -axo rss,comm | grep lldb-rpc-server | grep -v grep | head -1 | awk '{printf "%dMB", $1/1024}')
    [ -z "$edge_rss" ] && edge_rss="(not running)"
    [ -z "$lldb_rss" ] && lldb_rss="(absent)"
    echo "  t+${t}s: Edge=$edge_rss lldb=$lldb_rss" | tee -a "$LOG"
  done
  snapshot "T5 AFTER" "$LOG"
  echo "T5 done."
}

claude_sample() {
  # Emit one ps snapshot of all Claude.app processes, formatted for human reading.
  # $1 = sample tag (e.g. "t+0s")
  local tag="$1"
  ps -axo pid,pcpu,rss,command 2>/dev/null | awk -v tag="$tag" '
    BEGIN { printf "[%s]\n", tag }
    /\/Applications\/Claude\.app\// {
      pcpu=$2; rss=$3
      role="other"
      if ($0 ~ /Helper \(Renderer\)/) role="renderer"
      else if ($0 ~ /type=gpu-process/) role="gpu"
      else if ($0 ~ /MacOS\/Claude $/||$0 ~ /MacOS\/Claude$/) role="main"
      else if ($0 ~ /type=utility/) role="utility"
      else if ($0 ~ /Helper/) role="helper"
      printf "  pid=%-6s cpu=%5s%% rss=%6dM role=%s\n", $1, pcpu, rss/1024, role
      tot_cpu+=pcpu; tot_rss+=rss; n++
    }
    END {
      if (n==0) print "  (Claude.app not running)"
      else printf "  TOTAL: cpu=%.1f%% rss=%dM nprocs=%d\n", tot_cpu, tot_rss/1024, n
    }
  '
}

summarize_claude_samples() {
  # Parse a claude-sample tmp file, print peak/avg stats. $1 = tmp path.
  awk '
    /role=renderer/ { if ($3+0 > max_ren) max_ren=$3+0 }
    /TOTAL: cpu=/ {
      gsub("cpu=",""); gsub("%","")
      v=$2+0
      if (v>max_tot) max_tot=v
      sum_tot+=v; nt++
    }
    END {
      printf "  peak_renderer_cpu = %.1f%%\n", max_ren
      printf "  peak_total_cpu    = %.1f%%\n", max_tot
      if (nt>0) printf "  avg_total_cpu     = %.1f%%\n", sum_tot/nt
      if (max_ren+0 > 30)      print "  VERDICT: renderer peaked >30% — conversation likely too long; consider new chat."
      else if (max_ren+0 > 15) print "  VERDICT: renderer 15-30% — borderline; watch trend."
      else                     print "  VERDICT: renderer healthy (<15%)."
    }
  ' "$1"
}

T7_claude_renderer() {
  local LOG="$LOG_DIR/T7-claude-$(date +%Y%m%d-%H%M%S).log"
  local TMP; TMP=$(mktemp -t T7-samples.XXXXXX)
  echo ">> T7 Claude.app renderer characterization → $LOG"
  echo "   Sampling Claude.app every 2s for 60s (30 samples)."
  echo "   USE Claude.app normally during this window (scroll/switch focus/etc) to observe per-action CPU."
  snapshot "T7 BEFORE" "$LOG"
  for i in $(seq 0 29); do
    claude_sample "t+$((i*2))s" >> "$TMP"
    sleep 2
  done
  {
    echo
    echo "--- T7: Claude.app samples (every 2s, 30 samples = 60s) ---"
    cat "$TMP"
    echo
    echo "--- T7: peak/summary across all samples ---"
    summarize_claude_samples "$TMP"
  } >> "$LOG"
  rm -f "$TMP"
  snapshot "T7 AFTER" "$LOG"
  echo "T7 done. Highlights:"
  grep -E "peak_|avg_|VERDICT" "$LOG" | sed 's/^/  /'
}

T7_open_session() {
  local LOG="$LOG_DIR/T7-open-$(date +%Y%m%d-%H%M%S).log"
  local TMP; TMP=$(mktemp -t T7-open-samples.XXXXXX)
  echo ">> T7-open Claude.app open-historic-session test → $LOG"
  echo "   10s baseline, then prompt to open a long historic session, then 60s sampling."
  snapshot "T7-open BEFORE" "$LOG"
  for i in $(seq 0 4); do
    claude_sample "baseline_t+$((i*2))s" >> "$TMP"
    sleep 2
  done
  echo
  echo ">>> NOW: in Claude.app, open a LONG historic conversation from the sidebar. <<<"
  echo ">>> Sampling continues for 60s. <<<"
  say "open a long historic chat now" 2>/dev/null &
  for i in $(seq 0 29); do
    claude_sample "action_t+$((i*2))s" >> "$TMP"
    sleep 2
  done
  {
    echo
    echo "--- T7-open: samples (10s baseline + 60s post-action) ---"
    cat "$TMP"
    echo
    echo "--- T7-open: peak/summary ---"
    summarize_claude_samples "$TMP"
  } >> "$LOG"
  rm -f "$TMP"
  snapshot "T7-open AFTER" "$LOG"
  echo "T7-open done. Highlights:"
  grep -E "peak_|VERDICT" "$LOG" | sed 's/^/  /'
}

T8_suspect_memory_tracker() {
  # T8 — sample memory of the OOM-suspect processes every 10s for 5min.
  # Reports per-process RSS at each sample + growth rate per minute.
  #
  # Suspects: lldb-rpc-server (Xcode debug session), iOS sim subsystem total,
  # Edge.app, mds_stores (Spotlight), syspolicyd, com.apple.WebKit (Safari Tech
  # Preview if running). Light enough to run while doing normal work.
  local SAMPLES=${OOM_T8_SAMPLES:-30}    # 30 × 10s = 5 min
  local INTERVAL=${OOM_T8_INTERVAL:-10}  # seconds between samples
  local LOG="$LOG_DIR/T8-suspect-mem-$(date +%Y%m%d-%H%M%S).log"
  local TMP; TMP=$(mktemp -t T8-samples.XXXXXX)
  echo ">> T8 suspect-process memory tracker → $LOG"
  echo "   ${SAMPLES} samples × ${INTERVAL}s = $((SAMPLES * INTERVAL / 60)) min"
  echo "   USE Edge / Xcode normally during the window — that's the point"
  snapshot "T8 BEFORE" "$LOG"

  # Header for CSV-style data. xcode_mb covers the full Xcode toolchain
  # (Xcode.app, SwiftBuildService, SourceKit-LSP, dt.SKAgent, IDEs).
  printf 'sample,ts,lldb_mb,sim_total_mb,sim_proc_count,xcode_mb,edge_mb,mds_mb,syspolicy_mb,webkit_mb,claude_total_mb,inactive_mb,procs,free_mb,compressor_mb\n' > "$TMP"
  # Also track top-N processes per sample for "what grew that we don't track" detection.
  local TOPN="${TMP}.topn"
  : > "$TOPN"

  for i in $(seq 0 $((SAMPLES - 1))); do
    ts=$(date +%H:%M:%S)
    # Gather everything in one ps invocation (faster + less noise)
    ps_out=$(ps -axo rss,command 2>/dev/null)

    lldb_mb=$(echo "$ps_out" | awk '/lldb-rpc-server/ && !/grep/ {sum += $1} END {printf "%d", sum/1024}')
    # iOS sim total = anything under CoreSimulator runtime root OR is com.apple.CoreSimulator
    sim_mb=$(echo "$ps_out" | awk '/CoreSimulator|simruntime|com\.apple\.simulator/ {sum += $1} END {printf "%d", sum/1024}')
    sim_n=$(echo "$ps_out"  | awk '/CoreSimulator|simruntime|com\.apple\.simulator/ {n++} END {printf "%d", n+0}')
    # Xcode toolchain: the IDE itself, build, index and language servers.
    xcode_mb=$(echo "$ps_out" | awk '/Xcode\.app|SwiftBuildService|SourceKitService|SourceKit-LSP|com\.apple\.dt\.SKAgent|cc1as|swift-frontend/ {sum += $1} END {printf "%d", sum/1024}')
    edge_mb=$(echo "$ps_out" | awk '/\/Edge\.app\/.*\/Edge$|co\.edgesecure\.app/ {sum += $1} END {printf "%d", sum/1024}')
    mds_mb=$(echo "$ps_out" | awk '/mds_stores|mdworker_shared|^[ ]*[0-9]+ +\/usr\/sbin\/mds$/ {sum += $1} END {printf "%d", sum/1024}')
    sp_mb=$(echo "$ps_out" | awk '/syspolicyd|amfid$|com\.apple\.security/ {sum += $1} END {printf "%d", sum/1024}')
    wk_mb=$(echo "$ps_out" | awk '/WebKit.WebContent|com\.apple\.WebKit/ {sum += $1} END {printf "%d", sum/1024}')
    claude_mb=$(echo "$ps_out" | awk '/\/Applications\/Claude\.app\// {sum += $1} END {printf "%d", sum/1024}')
    procs=$(echo "$ps_out" | wc -l | tr -d ' ')
    page_size=$(sysctl -n hw.pagesize)
    free_mb=$(vm_stat | awk -v ps="$page_size" '/Pages free:/ {gsub("\\.","",$NF); printf "%d", $NF*ps/1024/1024}')
    inact_mb=$(vm_stat | awk -v ps="$page_size" '/Pages inactive:/ {gsub("\\.","",$NF); printf "%d", $NF*ps/1024/1024}')
    comp_mb=$(vm_stat | awk -v ps="$page_size" '/Pages occupied by compressor:/ {gsub("\\.","",$NF); printf "%d", $NF*ps/1024/1024}')
    printf '%d,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n' \
      "$i" "$ts" "$lldb_mb" "$sim_mb" "$sim_n" "$xcode_mb" "$edge_mb" "$mds_mb" "$sp_mb" "$wk_mb" "$claude_mb" "$inact_mb" "$procs" "$free_mb" "$comp_mb" >> "$TMP"

    # Top 5 RSS process basenames at this sample — feeds the "unknown grower" detector
    echo "$ps_out" | sort -k1 -nr | head -5 | awk -v s="$i" -v t="$ts" '{
      cmd=$2; n=split(cmd, a, "/"); bn=a[n]
      sub(/[ \t].*$/, "", bn)  # strip args
      printf "%s,%s,%d,%s\n", s, t, $1/1024, bn
    }' >> "$TOPN"

    [ "$i" -lt "$((SAMPLES - 1))" ] && sleep "$INTERVAL"
  done

  {
    echo
    echo "--- T8: per-sample memory (MB) ---"
    cat "$TMP"
    echo
    echo "--- T8: per-suspect summary (start → end, delta, MB/min growth) ---"
    awk -F, '
      NR==1 { for (i=1; i<=NF; i++) col[$i]=i; next }
      NR==2 {
        for (k in col) if (k != "sample" && k != "ts") { idx = col[k]+0; start[k] = $idx }
        first_ts = $(col["ts"]+0)
      }
      { for (k in col) if (k != "sample" && k != "ts") { idx = col[k]+0; end[k] = $idx }
        last_ts = $(col["ts"]+0); n_samples = NR - 1
      }
      END {
        # rough minutes from sample count: (n-1) * INTERVAL / 60
        mins = (n_samples - 1) * '"$INTERVAL"' / 60
        printf "%-20s %10s %10s %10s %12s\n", "metric", "start_MB", "end_MB", "delta_MB", "MB/min"
        for (k in start) {
          d = end[k] - start[k]
          rate = (mins > 0) ? d / mins : 0
          printf "%-20s %10s %10s %+10d %+12.1f\n", k, start[k], end[k], d, rate
        }
      }
    ' "$TMP"
    echo
    echo "--- T8: verdict heuristics ---"
    awk -F, '
      NR==1 { for (i=1; i<=NF; i++) col[$i]=i; next }
      NR==2 {
        lldb_s   = $(col["lldb_mb"]+0)
        sim_s    = $(col["sim_total_mb"]+0)
        edge_s   = $(col["edge_mb"]+0)
        xcode_s  = $(col["xcode_mb"]+0)
        free_s   = $(col["free_mb"]+0)
        inact_s  = $(col["inactive_mb"]+0)
      }
      {
        lldb_e   = $(col["lldb_mb"]+0)
        sim_e    = $(col["sim_total_mb"]+0)
        edge_e   = $(col["edge_mb"]+0)
        xcode_e  = $(col["xcode_mb"]+0)
        mds_e    = $(col["mds_mb"]+0)
        free_e   = $(col["free_mb"]+0)
        inact_e  = $(col["inactive_mb"]+0)
        n = NR - 1
      }
      END {
        mins = (n - 1) * '"$INTERVAL"' / 60
        if (mins == 0) { print "  (only one sample)"; exit }
        edge_rate  = (edge_e - edge_s)  / mins
        lldb_rate  = (lldb_e - lldb_s)  / mins
        sim_rate   = (sim_e  - sim_s)   / mins
        xcode_rate = (xcode_e - xcode_s) / mins
        free_drop  = free_s - free_e
        inact_gain = inact_e - inact_s
        tracked_gain = (edge_e - edge_s) + (lldb_e - lldb_s) + (sim_e - sim_s) + (xcode_e - xcode_s)

        if (edge_rate > 100)  printf "  ⚠ Edge growing %d MB/min — confirms Suspect 2 (JS heap)\n", edge_rate
        if (lldb_rate > 50)   printf "  ⚠ lldb-rpc growing %d MB/min — confirms Suspect 1\n", lldb_rate
        if (sim_rate > 100)   printf "  ⚠ sim subsystem growing %d MB/min — confirms Suspect 1\n", sim_rate
        if (xcode_rate > 200) printf "  ⚠ Xcode toolchain growing %d MB/min — heavy IDE+build load\n", xcode_rate
        if (mds_e > 2000)     printf "  ⚠ mds_stores at %d MB — confirms Suspect 3 (Spotlight reindex)\n", mds_e

        if (free_drop > 2000) {
          printf "  free_mb dropped %d MB; tracked-suspects gained %d MB; inactive gained %d MB\n", free_drop, tracked_gain, inact_gain
          unaccounted = free_drop - tracked_gain - inact_gain
          if (unaccounted > 1000)
            printf "  ⚠ UNACCOUNTED %d MB consumed by processes outside suspect list (see top-growers below)\n", unaccounted
          else
            printf "  ✓ memory shift accounted for (most likely tracked suspects + inactive/file-cache fill)\n"
        }

        if (edge_rate < 50 && lldb_rate < 20 && sim_rate < 50 && xcode_rate < 50 && mds_e < 1000 && free_drop < 2000)
          print "  ✓ All suspects under threshold during this window. Either OOM is intermittent or trigger requires longer observation."
      }
    ' "$TMP"
    echo
    echo "--- T8: top growers (processes with biggest RSS delta across the window) ---"
    # For each process basename seen in top-5, find max - min RSS in MB across samples.
    local GROWERS="${TMP}.growers"
    awk -F, '
      { rss = $3; bn = $4
        if (!(bn in min_rss) || rss < min_rss[bn]) min_rss[bn] = rss
        if (!(bn in max_rss) || rss > max_rss[bn]) max_rss[bn] = rss
      }
      END {
        for (b in min_rss) {
          d = max_rss[b] - min_rss[b]
          printf "%+10d\t%-40s %10d %10d\n", d, substr(b,1,40), min_rss[b], max_rss[b]
        }
      }
    ' "$TOPN" | sort -k1 -nr > "$GROWERS"
    printf "%-10s %-40s %10s %10s\n" "delta_MB" "process" "min_MB" "max_MB"
    head -10 "$GROWERS" | awk -F'\t' '{print $1, $2}' OFS=' '
    rm -f "$GROWERS"
  } >> "$LOG"
  rm -f "$TMP" "$TOPN"
  snapshot "T8 AFTER" "$LOG"
  echo "T8 done. Verdict + growth summary:"
  grep -E "verdict|MB/min|growing|threshold|^[a-z_]+ +[0-9]+ +" "$LOG" | tail -20 | sed 's/^/  /'
}

T9_xcode_build_timing() {
  # T9 — real-workflow Xcode clean+build. Times a single edge-react-gui iOS Debug
  # build. Memory snapshot before+after; reports elapsed + memory delta. The first
  # build after a reboot is the most expensive; subsequent ones are faster.
  local LOG="$LOG_DIR/T9-xcode-$(date +%Y%m%d-%H%M%S).log"
  local PROJECT_DIR="${OOM_T9_PROJECT:-$HOME/git/edge-react-gui}"
  local SCHEME="${OOM_T9_SCHEME:-edge}"
  local WORKSPACE="${OOM_T9_WORKSPACE:-$PROJECT_DIR/ios/edge.xcworkspace}"

  echo ">> T9 Xcode build timing → $LOG"
  echo "   project: $PROJECT_DIR"
  echo "   workspace: $WORKSPACE"
  echo "   scheme: $SCHEME"

  if [ ! -d "$PROJECT_DIR" ]; then
    echo "  edge-react-gui not at $PROJECT_DIR; skipping T9 (set OOM_T9_PROJECT)"
    return 2
  fi
  if [ ! -d "$WORKSPACE" ]; then
    echo "  workspace not at $WORKSPACE — try OOM_T9_WORKSPACE=/path/to/edge.xcworkspace"
    # Try to autodetect
    found=$(find "$PROJECT_DIR/ios" -maxdepth 2 -name "*.xcworkspace" -type d 2>/dev/null | head -1)
    [ -n "$found" ] && echo "  hint: found $found"
    return 2
  fi

  snapshot "T9 BEFORE" "$LOG"
  local t0; t0=$(elapsed_ms)
  ( cd "$PROJECT_DIR" && xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug -destination 'generic/platform=iOS Simulator' clean build 2>&1 | tail -100 ) >> "$LOG" 2>&1
  local rc=$?
  local t1; t1=$(elapsed_ms)
  {
    echo
    echo "--- T9: xcodebuild result ---"
    echo "elapsed_ms = $((t1 - t0))"
    echo "elapsed_min = $(echo "scale=2; ($t1 - $t0) / 60000" | bc 2>/dev/null || python3 -c "print(f'{($t1 - $t0) / 60000:.2f}')")"
    echo "exit_code = $rc"
  } >> "$LOG"
  snapshot "T9 AFTER" "$LOG"
  echo "T9 done. elapsed=$(( (t1 - t0) / 1000 ))s exit=$rc"
}

T6_long_observation() {
  echo ">> T6 long observation: T3 + T4 + T5 then idle for 30+ min"
  echo "   Persistent trace continues recording every 30s."
  echo "   Stop manually when you've seen what you wanted."
  T3_cold_metro
  T4_cold_sim_boot
  T5_edge_launch
  echo
  echo "T6 setup complete. Now use Edge with the large account normally."
  echo "  Trace log: ~/.config/agent-watcher/oom-repro/logs/trace-$(date +%Y-%m-%d).log"
  echo "  Stop when: load > 30 OR compressor > 30 GB OR you call uncle."
  echo "  Inspect: tail -f ~/.config/agent-watcher/oom-repro/logs/trace-$(date +%Y-%m-%d).log"
}

# ─── Driver ──────────────────────────────────────────────────────────────────

TESTS=("$@")
if [ ${#TESTS[@]} -eq 0 ]; then
  TESTS=(T0 T1 T2)
fi

if [ "${TESTS[0]:-}" = "all" ]; then
  TESTS=(T0 T1 T2 T3 T4 T5)
fi

for t in "${TESTS[@]}"; do
  case "$t" in
    T0) T0_baseline ;;
    T1) T1_node_spawn ;;
    T2) T2_uncached_spawn ;;
    T3) T3_cold_metro ;;
    T4) T4_cold_sim_boot ;;
    T5) T5_edge_launch ;;
    T6) T6_long_observation ;;
    T7) T7_claude_renderer ;;
    T7-open|T7open) T7_open_session ;;
    T8) T8_suspect_memory_tracker ;;
    T9) T9_xcode_build_timing ;;
    *) echo "Unknown test: $t (valid: T0 T1 T2 T3 T4 T5 T6 T7 T7-open T8 T9 all)"; exit 1 ;;
  esac
done

echo
echo "All requested tests complete."
echo "  Per-test logs: $LOG_DIR/"
echo "  Persistent trace: $OOM_DIR/logs/trace-$(date +%Y-%m-%d).log"
