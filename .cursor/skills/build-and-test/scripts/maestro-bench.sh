#!/usr/bin/env bash
# maestro-bench.sh -- run one flow N times under each maestro engine and report
# wall time, CPU time and peak memory, so an engine choice rests on numbers.
#
# Engines:
#   maestro         ~/.maestro/bin/maestro (JVM CLI + XCTest driver on the sim)
#   maestro-runner  ~/.maestro-runner/bin/maestro-runner (Go binary + WebDriverAgent)
#   <label>=<path>  another maestro-runner build, e.g.
#                   fork=$HOME/.maestro-runner-fork/bin/maestro-runner, to
#                   compare builds in one alternating run
#
# Per run it records:
#   wall_s       end-to-end seconds of the `test` invocation
#   cpu_s        user+sys seconds of the engine and every descendant it reaped
#                (/usr/bin/time -l), i.e. host CPU the run cost
#   host_rss_mb  peak summed RSS of the engine's live process tree (sampled)
#   sim_rss_mb   peak RSS of the on-sim XCTest runner app (the engine's driver:
#                maestro-driver-iosUITests-Runner or WebDriverAgentRunner-Runner)
#   flow_s       the flow's own duration as the engine reports it (runner:
#                report.json; maestro: first command start to last command
#                end in its debug output), i.e. wall minus startup/teardown
#   pass         the flow's exit status (0 = pass)
#
# For runner engines it also writes wda.csv: every WDA request in the run's
# maestro-runner.log, grouped by method and endpoint (element ids and session
# ids folded), with count and total ms. The summary prints each engine's
# per-run average of those groups, which is where runner step time goes.
#
# Runs alternate engines (A B A B ...) so drift in sim or host load does not
# favor one engine. The first run of each engine is reported separately as
# "cold": it pays one-time costs (maestro installs its driver; maestro-runner
# builds WebDriverAgent into its cache on the first run per iOS version).
#
# Usage:
#   maestro-bench.sh --flow <yaml> [--runs N] [--engines maestro,maestro-runner]
#                    [--device <udid>] [--driver-port N] [--out <dir>]
#
# Defaults: --runs 5, both engines, --device $AGENT_SIM_UDID (required: this
# script never drives an unpinned device), --driver-port $AGENT_METRO_PORT+1000
# (maestro only), --out a fresh mktemp dir. Prints the per-run CSV path and a
# markdown summary table (medians over warm runs).
#
# Exit codes: 0 = all runs finished (pass or fail is in the table), 1 = usage
# or environment error.

set -euo pipefail

FLOW=""
RUNS=5
ENGINES="maestro,maestro-runner"
DEVICE="${AGENT_SIM_UDID:-}"
DRIVER_PORT=""
[[ -n "${AGENT_METRO_PORT:-}" ]] && DRIVER_PORT=$((AGENT_METRO_PORT + 1000))
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow)        FLOW="$2";        shift 2 ;;
    --runs)        RUNS="$2";        shift 2 ;;
    --engines)     ENGINES="$2";     shift 2 ;;
    --device)      DEVICE="$2";      shift 2 ;;
    --driver-port) DRIVER_PORT="$2"; shift 2 ;;
    --out)         OUT="$2";         shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$FLOW" ]]   || { echo "flow not found: $FLOW" >&2; exit 1; }
[[ -n "$DEVICE" ]] || { echo "no device: pass --device <udid> or set AGENT_SIM_UDID" >&2; exit 1; }
xcrun simctl list devices | grep "$DEVICE" | grep -q "(Booted)" ||
  { echo "device $DEVICE is not booted" >&2; exit 1; }
export PATH="$HOME/.maestro/bin:$HOME/.maestro-runner/bin:$PATH"
IFS=, read -ra ENGINE_SPECS <<< "$ENGINES"
ENGINE_LIST=()
ENGINE_BINS=() # parallel to ENGINE_LIST (bash 3.2 has no associative arrays)
for spec in "${ENGINE_SPECS[@]}"; do
  case "$spec" in
    maestro|maestro-runner) e=$spec; bin=$(command -v "$spec" || true) ;;
    *=*) e=${spec%%=*}; bin=${spec#*=} ;;
    *) echo "unknown engine: $spec (maestro, maestro-runner or <label>=<runner path>)" >&2; exit 1 ;;
  esac
  [[ -x "$bin" ]] || { echo "$e: no executable at '${bin}'" >&2; exit 1; }
  ENGINE_LIST+=("$e"); ENGINE_BINS+=("$bin")
done
engine_bin() { # $1 engine label
  local i
  for i in "${!ENGINE_LIST[@]}"; do
    [[ "${ENGINE_LIST[$i]}" = "$1" ]] && { echo "${ENGINE_BINS[$i]}"; return; }
  done
}
[[ -n "$OUT" ]] || OUT=$(mktemp -d /tmp/maestro-bench.XXXXXX)
mkdir -p "$OUT"
CSV="$OUT/runs.csv"
echo "engine,run,wall_s,flow_s,cpu_s,host_rss_mb,sim_rss_mb,pass" > "$CSV"
WDA_CSV="$OUT/wda.csv"
echo "engine,run,method,endpoint,count,total_ms" > "$WDA_CSV"

engine_cmd() { # $1 engine, $2 run dir
  if [[ "$1" = maestro ]]; then
    local a=("$(engine_bin maestro)" --device "$DEVICE")
    [[ -n "$DRIVER_PORT" ]] && a+=(--driver-host-port "$DRIVER_PORT")
    printf '%s\0' "${a[@]}" test --debug-output "$2/debug" --flatten-debug-output "$FLOW"
  else
    printf '%s\0' "$(engine_bin "$1")" --platform ios --device "$DEVICE" --no-ansi \
      --output "$2/report" test "$FLOW"
  fi
}

# The flow's own duration in seconds, as the engine reports it (0 if absent).
flow_seconds() { # $1 engine, $2 run dir
  node -e '
const fs = require("fs"), path = require("path"), [engine, d] = process.argv.slice(1);
const files = (dir, re) => { try { return fs.readdirSync(dir).filter(f => re.test(f)).map(f => path.join(dir, f)) } catch { return [] } };
let s = 0;
try {
  if (engine === "maestro") {
    const m = files(d + "/debug", /^commands-.*\.json$/).flatMap(f => JSON.parse(fs.readFileSync(f))).map(c => c.metadata).filter(m => m && m.timestamp);
    if (m.length) s = (Math.max(...m.map(x => x.timestamp + (x.duration || 0))) - Math.min(...m.map(x => x.timestamp))) / 1000;
  } else {
    for (const r of files(d + "/report", /./)) for (const f of files(r, /^report\.json$/))
      s += JSON.parse(fs.readFileSync(f)).flows.reduce((a, x) => a + (x.duration || 0), 0) / 1000;
  }
} catch {}
console.log(s.toFixed(1));
' "$1" "$2"
}

# WDA requests in a runner run's log, grouped by method and endpoint.
wda_requests() { # $1 engine, $2 run index, $3 run dir
  local log
  log=$(ls "$3"/report/*/maestro-runner.log 2>/dev/null | head -1)
  [[ -n "$log" ]] || return 0
  sed -nE 's/.*WDA (GET|POST|DELETE) ([^ ]+) completed \(([0-9]+)ms.*/\1 \2 \3/p' "$log" |
    sed -E 's#/session/[^/ ]+##; s#/element/[^/ ]+/#/element/:id/#; s#\?[^ ]*##' |
    awk -v e="$1" -v r="$2" '{ k=$1","$2; n[k]++; ms[k]+=$3 } END { for (k in n) print e","r","k","n[k]","ms[k] }' \
    >> "$WDA_CSV"
}

# Peak summed RSS (KB) of $1's process tree and of the on-sim XCTest runner,
# sampled every 0.5s until $1 exits. Writes "<host_kb> <sim_kb>" to $2.
sample_peaks() {
  local root=$1 dest=$2 host=0 sim=0 h s
  while kill -0 "$root" 2>/dev/null; do
    read -r h s < <(ps -axo pid=,ppid=,rss=,command= | awk -v root="$root" -v dev="/Devices/$DEVICE/" '
      { pid[NR]=$1; ppid[NR]=$2; rss[NR]=$3; $1=$2=$3=""; cmd[NR]=$0 }
      END {
        live[root]=1; changed=1
        while (changed) { changed=0
          for (i=1;i<=NR;i++) if (live[ppid[i]] && !live[pid[i]]) { live[pid[i]]=1; changed=1 } }
        for (i=1;i<=NR;i++) {
          if (live[pid[i]]) h+=rss[i]
          if (index(cmd[i], dev) && cmd[i] ~ /Runner\.app/) s+=rss[i]
        }
        print h+0, s+0
      }')
    (( h > host )) && host=$h
    (( s > sim )) && sim=$s
    sleep 0.5
  done
  echo "$host $sim" > "$dest"
}

run_one() { # $1 engine, $2 run index
  local e=$1 i=$2 dir="$OUT/$1-$2" cmd=() pid t0 t1 rc
  mkdir -p "$dir"
  while IFS= read -r -d '' w; do cmd+=("$w"); done < <(engine_cmd "$e" "$dir")
  t0=$(python3 -c 'import time; print(time.time())')
  /usr/bin/time -l "${cmd[@]}" >"$dir/out.log" 2>"$dir/time.log" &
  pid=$!
  sample_peaks "$pid" "$dir/peaks" &
  local spid=$!
  rc=0; wait "$pid" || rc=$?
  wait "$spid" 2>/dev/null || true
  t1=$(python3 -c 'import time; print(time.time())')
  local cpu host sim
  cpu=$(awk '/ real .* user .* sys/ { print $3 + $5 }' "$dir/time.log" | tail -1)
  read -r host sim < "$dir/peaks"
  [[ "$e" = maestro ]] || wda_requests "$e" "$i" "$dir"
  printf '%s,%s,%.1f,%s,%.1f,%d,%d,%s\n' "$e" "$i" "$(echo "$t1 - $t0" | bc)" "$(flow_seconds "$e" "$dir")" \
    "${cpu:-0}" $((host / 1024)) $((sim / 1024)) "$rc" | tee -a "$CSV"
}

for ((i = 1; i <= RUNS; i++)); do
  for e in "${ENGINE_LIST[@]}"; do
    echo "[bench] $e run $i/$RUNS" >&2
    run_one "$e" "$i"
  done
done

echo
echo "per-run CSV: $CSV"
node -e '
const rows = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").slice(1)
  .map(l => l.split(",")).map(([engine, run, wall, flow, cpu, host, sim, pass]) =>
    ({ engine, run: +run, wall: +wall, flow: +flow, cpu: +cpu, host: +host, sim: +sim, pass: pass === "0" }));
const med = a => { const s = [...a].sort((x, y) => x - y), m = s.length >> 1;
  return s.length ? (s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2) : NaN; };
console.log("| engine | cold wall s | warm wall s (median) | warm flow s | warm CPU s | peak host RSS MB | peak sim driver RSS MB | passed |");
console.log("|---|---|---|---|---|---|---|---|");
for (const e of [...new Set(rows.map(r => r.engine))]) {
  const all = rows.filter(r => r.engine === e), cold = all.find(r => r.run === 1), warm = all.filter(r => r.run > 1);
  const w = warm.length ? warm : all;
  console.log(`| ${e} | ${cold.wall.toFixed(1)} | ${med(w.map(r => r.wall)).toFixed(1)} | ${med(w.map(r => r.flow)).toFixed(1)} | ${med(w.map(r => r.cpu)).toFixed(1)} | ${Math.max(...all.map(r => r.host))} | ${Math.max(...all.map(r => r.sim))} | ${all.filter(r => r.pass).length}/${all.length} |`);
}
const wda = require("fs").readFileSync(process.argv[2], "utf8").trim().split("\n").slice(1)
  .map(l => l.split(",")).map(([engine, run, method, endpoint, count, ms]) => ({ engine, run: +run, key: method + " " + endpoint, count: +count, ms: +ms }));
for (const e of [...new Set(wda.map(r => r.engine))]) {
  const rs = wda.filter(r => r.engine === e && r.run > 1), runs = new Set(rs.map(r => r.run)).size;
  if (!runs) continue;
  const g = {};
  for (const r of rs) { g[r.key] ??= { count: 0, ms: 0 }; g[r.key].count += r.count; g[r.key].ms += r.ms; }
  console.log(`\nWDA requests per warm run, ${e} (average of ${runs}):\n`);
  console.log("| request | count | total s | ms each |");
  console.log("|---|---|---|---|");
  for (const [k, v] of Object.entries(g).sort((a, b) => b[1].ms - a[1].ms).slice(0, 12))
    console.log(`| ${k} | ${(v.count / runs).toFixed(1)} | ${(v.ms / runs / 1000).toFixed(1)} | ${Math.round(v.ms / v.count)} |`);
}
' "$CSV" "$WDA_CSV"
