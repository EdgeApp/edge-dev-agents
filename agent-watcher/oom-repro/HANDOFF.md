# OOM investigation — handoff

This doc captures everything a fresh session needs to pick up the investigation.

> **★ ACTUAL ROOT CAUSE FOUND — 2026-05-28 ~13:35 PDT (supersedes everything below)**
>
> **The OOM is caused by recursive claude-code session spawning, not npm install and not SentinelOne.**
>
> Two confirmed incidents, same mechanism:
> - **Overnight 02:17 AM**: agent-orchestration session `afeb9f53` (Asana task 1215201512214395, "Zcash ZIP-321 deeplink") spawned ~1500 `cli` (claude-code node) processes in ~5 min → VM compressor 0→70 GB → ~15 GB swap → jetsam killed ~1880 procs.
> - **Live 13:34 PM**: the SAME session was resumed (`claude --resume afeb9f53`, launched manually from a Warp shell) and re-detonated — caught it growing at ~475 procs/sec, compressor at 64 GB, swap exhausted to 471 MB free, total procs 4371. Killed it live.
>
> **Mechanism**: the session ran a `/loop` / "babysit PR until green" pattern under `--remote-control`. On resume, the loop re-arms by spawning a new `claude`, which spawns another — an unbounded self-replicating CHAIN (each `cli` spawns exactly one child `cli`), all sharing ONE process group, orphaning to launchd as parents detach. The `anon<node>` processes jetsam killed overnight were these `cli`, not npm workers.
>
> **The kill that works**: `kill -9 -<PGID>` (atomic process-group kill). `pkill -x cli` FAILS — the chain self-replicates faster than non-atomic kills clear it. During the live incident all 564 procs shared pgid 74806; one `kill -9 -74806` ended it. `pkill`/`pkill -STOP` loops lost the race repeatedly.
>
> **Toxic sessions — DO NOT RESUME** (each re-detonates on resume):
> - `afeb9f53-0509-490a-88fa-eb1ee6d094da` (task 1215201512214395) — confirmed bad, both incidents
> - `4373931a-397e-46d8-9515-122e588f038e` — killed alongside, likely same pattern
> - 3 other agent-worktree sessions exist (1098d0a2, 4af85ca3, e1dafd07, 86383ed4) — same orchestration, treat as suspect until inspected
>
> **Prevention now in place**: `~/.config/agent-watcher/runaway-guard.sh` + `com.jontz.runaway-guard` launchd job (loaded). Every 60s (3s inner cadence) it counts `cli` per process group and `kill -9 -<PGID>` any group ≥50 (RUNAWAY_CLI_THRESHOLD). Legit claude workflows fan out flat at ≤16 concurrent/group, so 50 is a safe separator. Logs to `~/.config/agent-watcher/runaway-guard.log`.
>
> **What this means for prior conclusions**: the APFS-clone fix in setup-task-workspace.sh (added 2026-05-28) addresses npm-install storms, now understood as a SECONDARY concern, not the trigger. The SentinelOne and code-signature findings below are real but unrelated to the OOM. The deep-research report (2026-05-28) is valid; its jetsam-mechanism findings are folded into the "macOS jetsam behavior" section below.
>
> **Box facts measured during the incident** (research had flagged these as unknown/refuted):
> - `kern.maxproc=16000`, `kern.maxprocperuid=10666` (NOT the 532/100 some docs claim) — so the cascade was memory-pressure-driven, not a process-count-limit hit; the chain peaked ~2800 procs, far below 16000.
> - `vm.compressor_mode=4` (compression+swap, default). Do NOT set to 2/disable swap — research confirms that makes jetsam fire SOONER.
> - `sysctl kern.memorystatus_vm_pressure_level` → 1=NORMAL 2=WARN 4=CRITICAL is a pollable early-warning signal (but node/CLI procs don't get the redemption path that UIKit apps do, so it's only useful for the monitor, not self-defense).
>
> ---
>
> **⚠ EARLIER VERDICT — 2026-05-27 ~12:00 PDT (still valid, but not the OOM cause)**
>
> **SentinelOne is NOT the OOM cause.** Confirmed by stopping the agent entirely and observing identical hang behavior. The T2 synthetic test (which initially looked like a smoking gun) was discovered to be testing a **macOS code-signature verification edge case**, not a real-world workflow problem:
>
> - `cp /bin/echo new_path; new_path` → hangs ~7s at `_dyld_start` (Apple's designated-requirement check)
> - `cp /bin/echo new_path; codesign --sign - new_path; new_path` → runs in 22 ms (ad-hoc re-sign removes the check)
> - Identical behavior with SentinelOne **stopped** — definitive proof
>
> Real workflows (Xcode builds, npm install, configure scripts) don't clone Apple-signed bootstrap binaries, so they don't hit this path. The OOM that prompted this investigation is **still un-root-caused**. Re-focus on the original suspect list (Xcode 26.3 + iOS sim runtime, lldb-rpc growth, Edge.app JS heap, Spotlight). See **"Refocused investigation plan"** section below.
>
> **What's still useful from this investigation:**
> - Persistent logger (now capturing memory + load + Claude.app + procs every 30s) — runs continuously
> - Claude.app finding (active streaming = wedge, static DOM = cheap) — actionable behavior change
> - SentinelOne path exclusions you added (DerivedData, .npm, .nvm, Caches in Performance Focus mode) — harmless and provide minor file-scan benefit; leave them in place

## TL;DR

Jon's Mac OOMed (became unresponsive) yesterday during normal Edge dev work on the "large" account.

**Two adjacent UI-wedge issues observed during this session (2026-05-26)** — both are SEPARATE from the OOM investigation, but they look superficially like an OOM (UI unresponsive) so they need to be ruled out first when diagnosing. Memory was healthy throughout both (76 GB free, 5.7 GB compressor, no swap growth, load avg 4.5).

### Issue A: WindowServer / UI subsystem wedge (~18:45 PDT)
Apps in the dock unresponsive to clicks, top menu bar disappeared, keyboard input only worked in the foreground app (Claude.app). Initially diagnosed as `WindowServer` at 42-47% CPU sustained, not memory.

Attempted recoveries:
- `killall AltTab` → made the menu bar disappear (AltTab.app was holding WindowServer state)
- `killall Dock && killall SystemUIServer` → respawned, brought menu bar + dock back visually, but apps still unresponsive to clicks
- `killall karabiner_console_user_server` → didn't restore input to other apps

Suspect: third-party WindowServer hooks (AltTab.app) + many concurrent Electron renderers (Cursor, Claude, Asana, Slack, Arc, Warp) accumulating state over a multi-hour session may have leaked into WindowServer.

### Issue B: Claude.app renderer overload — likely root cause of Issue A
Investigation continued and revealed: `Claude Helper (Renderer)` was at 34-45% CPU and `Claude Helper` at 39-41% CPU, sustained. **Combined ~76-85% CPU on Claude.app alone.** The renderer was re-drawing the entire conversation DOM on every tool-result update.

Within Claude.app's chat textarea: the text cursor disappeared, only-type-at-end behavior. This is Electron-renderer-pegged symptoms — input events arriving fine, but the renderer too CPU-busy to redraw cursor position in real time.

Cause: this conversation accumulated many hours of dense tool calls (vm_stat dumps, ps outputs, large code edits, file writes, MCP responses). Each new tool result triggered the renderer to re-walk + re-paint a huge DOM tree.

**Likely the proximate cause of Issue A** — Claude.app's renderer hammering WindowServer with frequent graphics updates may have starved the rest of the UI from getting GPU/compositor time. AltTab.app + other Electron apps amplified the strain.

### What to do about it
- Don't run multi-hour Claude.app sessions for tool-heavy investigations. The renderer accumulates load.
- If Claude.app's renderer goes above ~30% CPU sustained, the conversation is too big; end and start a fresh one (the chat history is server-side, so context can be re-loaded).
- For sustained heavy work, prefer Cursor's Claude integration or the web version — both have different rendering models.
- Recovery path when wedged: `launchctl bootout user/$(id -u)` (logs out, kills Claude.app, frees WindowServer) — faster than reboot, conversation survives in the cloud.
- Hard reboot (hold power 10s) is the bulletproof fallback when even keyboard input outside the foreground app is dead.

### Why this matters for the OOM investigation
Three reasons to keep them separate:
1. **Memory was healthy during Issue A** — vm_stat showed 76 GB free. Anyone running the OOM diagnostic during a UI wedge will see misleading "system unresponsive" symptoms and might incorrectly conclude OOM. Always check `vm_stat | grep -E "free|compressor|Swapouts"` BEFORE blaming memory.
2. **The trace logger captures only memory + load, not WindowServer/renderer CPU**. If the next investigation hits unresponsiveness, also capture `ps -axo pid,pcpu,rss,comm | sort -k2 -nr | head -10` to distinguish.
3. **Yesterday's actual OOM was during Edge dev work, no Claude.app involvement** — so Issue B isn't the cause of yesterday's event. But Issue B can MASK an OOM if both happen at once, and the symptoms overlap enough that an unwary diagnostic could conflate them.
 Suspects in rough priority order:

1. **Xcode 26.3 + iOS 18 sim runtime footprint** — 21 GB of sim-side processes (223 of them) plus 5.5 GB lldb-rpc-server per attached debug session. This is new since the laptop migration.
2. **SentinelOne EDR** — newly installed (today). Kernel-level interceptor for fork/exec/connect. Hypothesized to add fork-serialization tax during heavy spawn bursts.
3. **Edge.app's JS heap on the large account** — gradual growth observed (~200 MB/min during active use, ~400 MB/min during Cmd+Play cycles). Resets on relaunch.
4. **Spotlight (`mds_stores`) reindex storms** — post-reboot catch-up + DerivedData churn during build cycles.

User's existing memory monitor (`com.jontz.memory-monitor`) didn't fire warnings before the OOM. Likely causes:
- 30s polling too slow for minute-scale spikes
- Modal alert via launchd-spawned osascript is fragile on Sequoia (silent failure)
- State machine only fires on level transition, no re-fire
- Thresholds too lenient (critical at avail<1.5% = avail<1.9GB on 128GB box)

## Hardening Jon already has in place

- `~/.npmrc` and `~/git/edge-react-gui/.npmrc`: `ignore-scripts=true` (blocks postinstall RCE)
- `~/.npmrc`: `min-release-age=7` (refuses packages <7 days old)
- `NPM_TOKEN` from env, not plaintext in npmrc

These materially reduce supply-chain attack surface, which means SentinelOne file-write monitoring on `node_modules` provides marginal additional protection. Important context for the SentinelOne exclusion decision.

## What's installed

```
~/.config/agent-watcher/oom-repro/
├── HANDOFF.md                          # this file
├── scripts/
│   ├── mem-trace-persistent.sh         # Logger — one-shot, ~10MB transient, exits immediately
│   ├── install.sh                      # Loads/unloads the launchd job
│   └── oom-repro-suite.sh              # Test driver T0–T6
└── logs/
    ├── trace-YYYY-MM-DD.log            # Persistent trace, one line per 30s, daily rotation, 7-day retention
    └── tests/
        └── T<N>-YYYYMMDD-HHMMSS.log    # Per-test snapshots (before/after)

~/Library/LaunchAgents/com.jontz.mem-trace.plist  # 30s scheduler for the persistent logger
```

The persistent logger is **loaded and running**. Survives reboots. Confirm with:
```bash
~/.config/agent-watcher/oom-repro/scripts/install.sh --status
```

## Existing related infra (separate concerns)

| Label | Purpose | Status |
|---|---|---|
| `com.jontz.memory-monitor` | Jon's existing alerting monitor — modal on critical, audio on warn, log-only on recovery | Loaded. Thresholds too lenient (see "what we know"). Logs to `/tmp/memory-monitor.log`. |
| `com.jontz.asana-watcher` | Polls Asana for Pending agent tasks, spawns tmux sessions to run them | Loaded, idle. Not contributing to OOM. |
| `com.jontz.session-watchdog` | Watches `claude-asana-*` tmux sessions for liveness | Loaded, idle. Not contributing to OOM. |
| `com.jontz.config-watch` | Watches security-sensitive config files (Cursor settings, .zshrc, etc.) for drift | Loaded, last exit 1 (= drift detected, expected). Not contributing to OOM. |
| `com.jontz.mem-trace` | **NEW** — the persistent OOM trace logger | Loaded. |
| `com.jontz.runaway-guard` | **NEW (2026-05-28)** — kills runaway `cli` fork-chain process groups (≥50 cli/PGID) via atomic `kill -9 -PGID`. 60s launchd interval, 3s inner cadence. The backstop against recursive claude-spawn OOMs. | Loaded. Logs to `~/.config/agent-watcher/runaway-guard.log` (only writes on a kill). |

None of the agent-watcher launchd jobs run anything heavy. They spawn briefly, do their work, exit.

## What we observed today (post-reboot at ~16:00 PDT)

Reasonably-controlled trace data exists in `~/.config/agent-watcher/oom-repro/logs/trace-2026-05-26.log` from 17:18 onward, and in `/tmp/mem-trace.log` (earlier, may rotate away).

Highlights from earlier in the session:
- **lldb-rpc-server**: 5.5 GB baseline when Xcode is attached to a sim. Drops to ~1 GB when sim is shut down. NOT a continuous leak — high allocation at attach time, slow creep (~50 MB per Cmd+Play cycle).
- **Sim subsystem**: 223 processes, total 21.12 GB RSS when iOS 18 iPhone 16 Pro Max is booted. Includes SpringBoard, WebKit, NewsToday2, healthappd, MobileCal, PosterBoard, etc. The iOS subsystem is heavier in Xcode 26.3 than in earlier versions.
- **Edge.app growth during active use**: 200 MB/min in observation; spikes to 400 MB/min during Cmd+Play. Resets to ~0.9 GB on each relaunch.
- **Process-spawn benchmark results (with SentinelOne fully active, warm caches)**:
  - 200 parallel `node -e exit`: 467 ms (2.3 ms amortized per process)
  - 5000 file writes in `/tmp`: 381 ms
  - These are FAST. The benchmarks don't show heavy SentinelOne tax on warm cached operations. **Cold-cache behavior is unmeasured.**

The "68 GB compressor + 9.4 GB swap" reading earlier in the session was a **transient spike caused by the 200-parallel-node-spawn benchmark itself** (12 GB burst → kernel emergency-compressed inactive pages). The compressor was reclaimed to <10 GB within 2 minutes. NOT evidence of a real OOM event in this session.

## ⚠ SUPERSEDED — kept as audit trail of how the wrong conclusion was reached

> The findings below were based on a flawed proxy (T2 cold-binary test). See the headline VERDICT at the top of this file. Skip past these to "Refocused investigation plan" unless you specifically want to audit how the investigation went sideways and back on track.

## ~~Confirmed~~ Superseded finding (2026-05-26 19:05, T2 run)

**SentinelOne creates SIGKILL-proof zombies on uncached binary spawn.**

Ran `oom-repro-suite.sh T0 T1 T2`. T1 (cached `node -e exit`) scaled cleanly:
- 500 procs: 1554 ms (3 ms/proc)
- 1000 procs: 3076 ms (3 ms/proc)
- 2000 procs: 6482 ms (3 ms/proc)
- No compressor pressure, no swap, memory steady at ~35 GB free.

T2 (100 unique never-seen binaries — `cp /bin/echo /tmp/oom-repro-uncached/x$i`, spawn all 100 in parallel, `wait`) **hung indefinitely**. 19 minutes later:
- 99 of 100 procs still alive (one survived past SentinelOne's gate; 99 stuck)
- `STAT=UE` = uninterruptible wait + trying to exit (the procs called `exit()` but the kernel won't let them through)
- `kill -9` did **not** terminate them — they are SIGKILL-proof
- The parent `wait` blocks until kernel releases the procs; we had to `kill` the suite parent to unstick
- Memory cost: 0 RSS each, but each consumes a PCB slot and inflates `procs` count permanently
- **Only a reboot clears them** — confirmed via `pgrep -af /tmp/oom-repro-uncached/` after SIGKILL attempt

### Mechanism (inferred)
SentinelOne's kernel interceptor for `execve`/`exit` is performing some verdict on cold binaries that either takes much longer than expected, fails silently, or deadlocks. The verdict gate sits in the exit path, so procs that already called `exit()` get held in UE state.

### Implications for the OOM event
- Any workflow that bursts one-shot uncached binaries (npm install scripts even with `ignore-scripts=true`, configure helpers, build sub-processes, Xcode build phases invoking shell scripts) leaves residual zombie PCBs.
- Each zombie is small individually but cumulative across a workday.
- This is consistent with the original "minute-scale spike" and "cumulative cliff after hours of work" hypotheses.
- The persistent logger's `procs=N` count is the canary — watch for it climbing without explanation.

### What this means for SentinelOne action plan
The decision is no longer "do T2 numbers justify exclusions" — they overwhelmingly do. The recommended exclusions in the original plan should be applied. Once applied:
1. Reboot to clear the 100 existing zombies
2. Re-run `OOM_T2_COUNT=10 oom-repro-suite.sh T2` — should complete cleanly in <100 ms (no UE state)
3. If it still hangs, the exclusion didn't reach the kernel interceptor and SentinelOne admin needs to verify

T2 has been hardened to default to N=10 with a 15s timeout (override with `OOM_T2_COUNT` and `OOM_T2_TIMEOUT` env vars) so reruns can't recreate the 100-zombie situation.

## Confirmed finding (2026-05-27 ~01:36, T7 + T7-open)

**Claude.app renderer trigger is active tool streaming, not DOM size at rest.**

T7 (60s passive sample of this active investigation session):
- peak_renderer = 52.3%, peak_total = 85.5%, avg_total = 64.4%
- Sustained 60–85% total CPU while tool calls were arriving

T7-open (10s baseline + 60s post-action, with Jon clicking a long historic chat in the sidebar at the audio cue):
- baseline (me still running tools): total 64–69%
- click-moment (action_t+6 to +8s): renderer RSS jumped 515M → 573M, new helper proc appeared (nprocs 10 → 11), brief total-CPU 47% spike
- **settled steady state (action_t+18s onward, no incoming tool calls): renderer 5–7%, total 18–22%**

Implications:
- A long static DOM is cheap. Opening big historic chats is safe.
- The "long conversation = renderer wedge" rule from yesterday is wrong as stated. The correct rule: **long conversation + active streaming workload (continuous tool results arriving) = renderer wedge.**
- The wedge symptom from yesterday (renderer 34–45% sustained) needed BOTH conditions present. Once Jon stops sending messages, the conversation becomes idle and CPU drops to ~20%.
- Practical: don't bail out of a long investigation session just because it's been hours — bail when YOU are actively driving high tool-call density and the renderer goes >30% sustained. Stale tabs are fine to leave open.

The persistent logger now records `claude=` on every 30s tick, so this can be retroactively verified across the workday — look for renderer CPU correlating with the timestamps when tool-heavy work was happening.

## ~~Refined~~ Superseded finding (2026-05-27 ~11:30, post-exclusion T2 diagnostics)

**The hang is in the macOS Endpoint Security (ES) framework exec-verdict gate, not in any post-exec scan that SentinelOne path exclusions cover.**

After applying 4 path exclusions in **Agent Interoperability / Performance Focus** mode (the strongest mode this tenant exposes; East Coast Cybersecurity / Pax8 / `usea1-pax8-03.sentinelone.net`) and rebooting:

- T2 still hangs identically with binaries in `~/Library/Caches/oom-repro-excluded-test/` (excluded path) vs `/tmp/oom-repro-uncached-control/` (non-excluded). 10/10 stuck in both. Confirmed via A/B.
- A **single** cold binary (no parallelism) hangs ~8s+. Each call individually times out. Not load-dependent.
- 5 sequential cold spawns hang one-at-a-time, each ~8s.
- `sample` on a stuck process shows: stuck at `_dyld_start` (the very first dyld instruction) for >22 minutes. Process never reached main(). Physical footprint: 96K, peak 96K — it has never run a single instruction.
- This is the ES framework's `es_event_exec_t` notify→authorize gate: macOS holds the process pre-exec until all ES subscribers respond. SentinelOne's agent (an ES subscriber) is not responding (fast) to verdicts for files in our excluded paths.

### Why Performance Focus exclusions don't help here

The Performance Focus description reads: *"The Agent will disable monitoring and all detection engines for processes that run from the excluded path."* The catch is "run from" — the verdict has to be returned **before** the process runs. The exclusion only kicks in after the agent has identified the binary's path, which requires processing the ES authorization call that's currently slow. Chicken-and-egg.

### What this actually means for the OOM hypothesis

Two scenarios:
1. **Yesterday's OOM was caused by this** — heavy workflows (Xcode build phases, npm install scripts, configure helpers) spawned many cold binaries; each took 5-30s+ to clear, accumulating UE zombies and load. The fork-side state per zombie is small but cumulative; load average went high; kernel pressure mounted.
2. **Yesterday's OOM was something else** — the synthetic T2 test exercises a path that real workflows may not hit (real exec is of properly-resident binaries, not freshly-copied ones; reputation cache may help).

We can't distinguish (1) vs (2) until we instrument actual workflows. Suggested A/B test: time a clean Xcode build with SentinelOne in **passive mode** (`sentinelctl protect off` if admin allows, then re-enable). If Xcode is materially faster passive, scenario 1 is real and SentinelOne is the OOM amplifier. If similar, scenario 2.

### Action items, in order of expected payoff

1. **Email Pax8 / East Coast Cybersecurity support** asking to enable **Interoperability Extended** (a higher tier than Performance Focus) at the account level. Justify: "Developer workstation; cold binaries hang at dyld_start; path exclusions in Performance Focus do not bypass the ES framework verdict gate. Need Interoperability Extended to skip the exec interceptor for build paths." Attach the dyld_start `sample` output as evidence.
2. **Check "Missing Authorizations"** in `sentinelctl status`. On macOS Sequoia, ES subscribers need Full Disk Access + System Extension + Network Filter + Background Items. If any are missing, the agent may be on a slow fallback IPC path — which would explain why even "trusted" verdicts take seconds.
3. **Real-workflow A/B**: time `xcodebuild clean build` and `npm install` on `edge-react-gui` with current config; compare to numbers with SentinelOne in passive mode. This tells you whether the synthetic T2 result matters in practice.
4. **Stop running T2-style tests** in the meantime — each one creates ~10 permanent UE zombies that only clear on reboot.

### Suite changes during this session

- `mem-trace-persistent.sh`: now logs `claude=ren=X%/RSSM gpu=X%/RSSM main=X%/RSSM tot=X%/RSSM n=N` on every 30s tick
- `oom-repro-suite.sh`: added `T7` (60s Claude.app sample) and `T7-open` (guided historic-session trigger test)
- `oom-repro-suite.sh`: T2 hardened — defaults to `OOM_T2_COUNT=10` with `OOM_T2_TIMEOUT=15s` polling instead of indefinite `wait`, so it can no longer wedge the suite. Per-run output reports `stuck_count` explicitly.

## Tonight's hypothesis test (set up 2026-05-28 ~17:15 PDT)

**Hypothesis:** the recursive `cli` fork chain is seeded by an agent session running a `/loop`-style PR babysitter (or a resume of one), NOT by npm install or cron accumulation. We never captured the exact spawn line live; tonight's orchestration runs are the chance to confirm/refute.

**What records it automatically:**
- `runaway-guard.sh` now captures forensics at a RECORD threshold (25 cli in one process group) BEFORE it kills (at 50). Capture runs `capture-runaway-forensics.sh <pgid>`, once per pgid per 10 min.
- `capture-runaway-forensics.sh` writes `~/.config/agent-watcher/oom-repro/forensics/runaway-<ts>-pgid<N>.log` with: an instant full `ps` snapshot (preserves lineage before procs detach), per-pgid cli counts, the offending group's tree, the **SEED ancestor trace** (walk the chain up to the first non-`cli` parent — this is the discriminator), any live `claude --resume/--rc/--yolo/loop` launcher, OS scheduler state (crontab/launchd/atq), tmux panes + start commands, the owning worktree's task gid + that session's last jsonl events, and a stack sample.
- Persistent logger (`mem-trace-persistent.sh`) records `cliCount=` and `pressure=` every 30s → the timeline.

**How to read it tomorrow (decision tree on the SEED ancestor):**
- Seed is `claude --resume <id>` (esp. repeated/stacking) → resume-driven respawn; tighten the resume path.
- Seed is a `claude` running `/loop` / a `ScheduleWakeup`/cron-fired claude → confirms the `/loop` self-respawn hypothesis; the `/one-shot` Step-6 rewrite (bounded in-process watch) is the fix.
- Seed is `claude --rc` shelling out to another `claude` → something in the session invokes claude directly; find and remove it.
- OS scheduler section shows an armed cron firing claude → orphaned-cron vector; the `bugbot-in-watch` CronDelete rule covers the bugbot case.
- Chain procs all stuck at `_dyld_start` with no live seed → the seed already exited; rely on the instant `ps` snapshot's lineage + the worktree session jsonl tail.

**If the guard fires tonight:** check `~/.config/agent-watcher/runaway-guard.log` for `RECORD`/`RUNAWAY` lines and read the referenced forensic file. The guard kills the chain at 50, so the box should stay healthy regardless of what we learn.

## Definitive root cause of the T2 hang (2026-05-27 ~12:00 PDT)

After ~6 hours of investigation, the cold-binary hang we kept seeing in T2 was **NOT caused by SentinelOne and is NOT related to the original OOM**. It is a macOS code-signature verification edge case.

### How we proved it

1. Disabled SentinelOne self-protection (`sentinelctl unprotect`) — T2 still hung identically (14.5s, 0/10 completed).
2. Stopped the full SentinelOne agent (`sentinelctl stop`, confirmed `sentineld` process gone) — T2 **still** hung identically (~14.5s, 0/10).
3. Ran T2-style variants to isolate:

   | Variant | Time | Result |
   |---|---|---|
   | Direct `/bin/echo` | 22 ms | OK |
   | Symlink → `/bin/echo` | 20 ms | OK |
   | `cp /bin/echo` (fresh inode, original signature) | **7107 ms** | **STUCK** |
   | `cp` + `xattr -c` (no quarantine attrs) | 7981 ms | STUCK |
   | `cp` + `codesign --sign -` (ad-hoc re-sign) | **22 ms** | **OK** |
   | `cp /usr/bin/true` | 195 ms | OK |
   | Fresh `/bin/sh` script | 137 ms | OK |
   | Fresh python script | 138 ms | OK |

   The only mitigation that worked was **re-signing the copy with an ad-hoc signature**, which replaces Apple's original designated-requirement check with a trivial one. This is direct evidence that the hang is in Apple's signature verification, not in any EDR.

### Mechanism

`/bin/echo` is signed by Apple with a strict **designated requirement** — typically including the binary's identity and its install location. When the kernel execs a copy of `/bin/echo` at a new path:

1. amfid (Apple Mobile File Integrity Daemon) is asked to verify the signature
2. The designated requirement check enters a slow Gatekeeper / notary-lookup path because the binary's identity/path doesn't match expectations
3. syspolicyd is involved (we see `Unable to initialize qtn_proc: 3` and `dispatch_mig_server returned 268435459` errors in the unified log on every exec, including unrelated Cursor helpers — the provenance sandbox is broken)
4. The verdict either takes ~7s or never returns
5. Process hangs at `_dyld_start` (sample shows literally zero instructions executed; Physical footprint 96K = just the initial allocation)
6. When/if the verdict does come back negative, kernel marks proc `UE` (uninterruptible-exit). These zombies are SIGKILL-proof and only clear on reboot.

### Why this is irrelevant to the OOM

Real workflows don't copy Apple system binaries:
- **Xcode builds** run already-compiled binaries from `~/Library/Developer/Xcode/DerivedData` (self-signed for their build path) and Apple toolchain binaries from `/Applications/Xcode.app` (signed for their actual location).
- **npm install** with `ignore-scripts=true` (Jon's config) doesn't exec node_modules scripts.
- **configure scripts** use `/bin/sh` directly (scripts are fast, see table above).

The T2 test was a synthetic worst-case that never happens in normal use. The yesterday-OOM has a different cause.

### A separate, unrelated finding from the diagnostics

The `syspolicyd: Unable to initialize qtn_proc: 3` and `kernel: (AppleSystemPolicy) ASP: Unable to apply provenance sandbox` errors fire on **every exec on this machine**, including ones that don't hang (e.g., Cursor helpers). This is a macOS Sequoia-side bug or config issue separate from the T2 hang. Worth noting because:
- It might add small per-exec overhead even for non-hanging cases
- Could be a side-effect of the laptop migration
- Could be fixed by reinstalling syspolicyd / Apple system services. Low priority unless we see correlations with OOM.

## Finding (2026-05-27 14:33, T8 second run)

**Xcode + its build toolchain is a previously-unmodeled ~7 GB instant cost.**

T8 run during a 5-min window where Xcode was launched showed:
- `free_mb` dropped 7.8 GB (54066 → 46241)
- All tracked suspects (sim/lldb/Edge/Claude/mds) barely moved
- Top RSS at end of window: **Xcode 1.2 GB + SwiftBuildService 3.9 GB + SourceKit-LSP 2.1 GB = 7.2 GB**
- Trace timeline shows `procs` jumped from 971 → 1029 in the 14:30:04 sample = Xcode launching

This wasn't in the original suspect list because the focus was on already-running processes that *grow*. Xcode launch is a step-function cost. **Each Xcode launch immediately consumes ~7 GB before any build runs**, which:
- Combined with one booted sim (19-31 GB), takes you to 26-38 GB just from "Xcode is open with a sim".
- Combined with Edge.app + Cursor + Claude + Slack + GitKraken + Arc (~10-15 GB), takes you to 40-55 GB baseline.
- A 128 GB machine has 70-90 GB headroom from this baseline, which is normally plenty — but a sim re-boot (briefly 2x sim size), a heavy build burst, and an Edge JS heap that's been growing for hours can collectively push toward an OOM.

### T8 updates from this finding

1. **New tracked metric**: `xcode_mb` covers Xcode.app + SwiftBuildService + SourceKitService + SourceKit-LSP + dt.SKAgent + cc1as + swift-frontend.
2. **New CSV column**: `inactive_mb` (so we can distinguish "free went to inactive = file cache" from "free went somewhere else = real consumer").
3. **New "top growers" section**: per-sample top-5 RSS basenames are tracked; the post-run summary computes max-min delta per basename, sorted. Catches any process outside the suspect list that grows during the window.
4. **New verdict logic**: when `free_mb` drops materially, T8 now decomposes the drop into (tracked-suspects gain) + (inactive gain) + (unaccounted). If unaccounted > 1 GB, it flags it for follow-up.

### Implications for the OOM hypothesis

The "cumulative cliff after hours of work" suspect just got more credible. The pattern likely looks like:
1. Morning baseline: ~15 GB used (browser + chat + IDE shell)
2. Open Xcode + sim: +7 GB + 20 GB = ~42 GB used (1 hr in)
3. Cmd+Play + Edge active session: +5 GB Edge + 5 GB lldb-rpc = ~52 GB (2 hr in)
4. Multiple Cmd+Play cycles: +50 MB lldb each = small but cumulative
5. Edge JS heap grows on large account: ~200 MB/min = +12 GB/hour
6. Spotlight reindexes during build cycles: occasional 1-2 GB bursts
7. At hour 6-8, total ~90 GB used, occasional bursts spike to 110 GB
8. One unlucky burst → kernel emergency compress → swap → cascade → OOM

This is consistent with everything we've observed. The next time Jon does a full day of Edge dev, **let T8 run periodically (every hour for 5 min)** and inspect the trends. Or better: let the persistent logger do its work and read the trace post-OOM if it happens again.

## Refocused investigation plan (active 2026-05-27)

With SentinelOne ruled out, return to the original suspect list. Priority order based on evidence weight:

### Suspect 1: lldb-rpc-server + iOS sim runtime footprint
- **Evidence**: post-reboot trace shows 5 GB lldb-rpc-server baseline when Xcode is attached
- **Mechanism**: each Cmd+Play cycle adds ~50 MB; sim subsystem is 21 GB; both grow under typical day-long Edge dev
- **Action**: T8 (new) — periodic memory snapshots of sim/lldb/Edge processes; the persistent logger already captures top-RSS but doesn't break out sim subprocesses
- **Mitigation if confirmed**: kill lldb-rpc-server periodically; or use `simctl launch` instead of Cmd+Play for non-debug Edge runs; or run a lighter Xcode version side-by-side

### Suspect 2: Edge.app JS heap on the large account
- **Evidence**: ~200 MB/min during active use, 400 MB/min during Cmd+Play, resets on relaunch
- **Mechanism**: progressive JS heap accumulation; the "large account" has many wallets/transactions loaded
- **Action**: T8 includes Edge RSS sampling
- **Mitigation if confirmed**: periodic Edge relaunch; or investigate JS heap fix in edge-react-gui

### Suspect 3: Spotlight reindex storms
- **Evidence**: `mds_stores` CPU spikes post-reboot and during DerivedData churn
- **Mechanism**: every build invalidates many files → Spotlight reindexes → I/O + CPU
- **Action**: T8 includes `mds_stores` RSS+CPU tracking
- **Mitigation if confirmed**: `mdutil -i off /Users/jontz/Library/Developer/Xcode/DerivedData` to exclude DerivedData from Spotlight (and possibly `~/git` too)

### Suspect 4: Cumulative cliff after hours of dev work
- **Evidence**: yesterday's OOM was hours into a session; no single trigger event was visible
- **Mechanism**: combination of all three above accumulating + nothing reclaims until OOM-killer
- **Action**: long-running persistent logger captures this organically; on next OOM, compare 1h/4h/8h-before snapshots
- **Mitigation if confirmed**: harden the memory-monitor (see "memory monitor improvements" section below) so it warns before the cliff

### Suspect 5 (NEW from this session): syspolicyd / AppleSystemPolicy errors
- **Evidence**: kernel + syspolicyd log spam on every exec; provenance sandbox failing to initialize
- **Mechanism**: unknown; may add small per-exec overhead even for non-hanging cases
- **Action**: T8 captures syspolicyd CPU+log volume
- **Mitigation if confirmed**: investigate syspolicyd reinstall; check if a system OS update fixes it

## What we still don't know (post-correction)

- Whether the original yesterday OOM was triggered by sim/lldb/Edge growth, Spotlight storm, or accumulation of all three
- Whether the syspolicyd/ASP errors are a separate macOS-side problem worth fixing on their own
- Whether the 100+ UE zombies created by the T2 tests (now sitting permanently in the process table) are themselves contributing measurable pressure — they're free of RSS but do consume PCB slots

## How to use what's been built

### Persistent logger
Already running. Each 30s tick appends one line to `~/.config/agent-watcher/oom-repro/logs/trace-YYYY-MM-DD.log`. Survives reboots. View:
```bash
tail -f ~/.config/agent-watcher/oom-repro/logs/trace-$(date +%Y-%m-%d).log
```

Each line:
```
ts=HH:MM:SS load1=N load5=N procs=N freeMB=N inactiveMB=N wiredMB=N compressorMB=N swapoutsTotal=N top=<10 entries>
```

Signals to watch for:
- `freeMB` < 5000 sustained (~5 GB free) = memory pressure real
- `compressorMB` > 30000 (~30 GB) = compressor working hard
- `swapoutsTotal` growing fast (>10000 pages/min) = swap is being written
- `load1` > 30 sustained = process queue depth high, fork serialization possible

### Test suite
After reboot, run:
```bash
~/.config/agent-watcher/oom-repro/scripts/oom-repro-suite.sh T0 T1 T2 T3 T4 T5
```

T0–T2 are cheap (~1 min). T3+ are heavier (kill Metro, shutdown sim, etc.). Each writes to `~/.config/agent-watcher/oom-repro/logs/tests/`.

For the long-form repro:
```bash
~/.config/agent-watcher/oom-repro/scripts/oom-repro-suite.sh T6
```
This runs T3+T4+T5 in sequence then idles. User uses Edge normally for 30+ min. Persistent logger captures everything.

### Tests defined

| Test | What | Status / Manual step |
|---|---|---|
| T0 | baseline snapshot of vm_stat, top RSS, process counts | active — none |
| T1 | 500/1000/2000 parallel `node -e exit` — measures cached-fork tax (proven harmless, kept as baseline) | active — none |
| T2 | ~~cold SentinelOne verdict tax~~ → renamed to **macOS code-signing edge case** demonstration. Defaults to N=3 with re-signed bypass available. **Do not run** unless explicitly investigating signature checks; each invocation creates ~N permanent UE zombies | quarantined — see comments in script |
| T3 | cold Metro boot timing | active — none |
| T4 | cold sim boot timing | active — none |
| T5 | Edge launch via `simctl launch`, 90s observation | active — needs booted sim (run T4 first) |
| T6 | T3+T4+T5 then idle for normal use | active — use Edge for 30+ min |
| T7 | Claude.app renderer characterization — 60s sampling | active — none |
| T7-open | Same sampler with guided "open historic chat" trigger | active — manual click |
| **T8 (NEW)** | **Suspect-process memory tracker** — 5 min of 10s-interval RSS samples for lldb-rpc-server, sim subsystem total, Edge.app, mds_stores, syspolicyd. Reports per-process growth rate per minute. The primary tool for the refocused investigation. | active — none |
| **T9 (NEW)** | **Real-workflow Xcode build timing** — clean + build the active edge-react-gui scheme, time it, snapshot memory before/after. Captures whether a single build cycle moves the needle. | active — requires edge-react-gui present and Xcode workspace path correct |

### Why T7 / what triggers Claude.app renderer overload

The handoff's Issue B hypothesis: long sessions accumulate a huge DOM (every tool call/result adds to the conversation), and each new tool-result update triggers a full re-render. The unknowns:
- Is it cumulative tool-result count, or DOM node count, or token count, that drives it?
- Does opening a *historic* long session reproduce it on demand (i.e. is it the DOM regardless of how it got there)?
- Is it specific to actively-streaming sessions (re-paint per token chunk), or any large convo?

T7 captures a 60s steady-state sample of whatever Claude.app is doing right now. Useful as the per-session "convo too big yet?" check.

T7-open is the controlled trigger test: do a baseline sample, then open a known-long historic conversation, sample again. If the renderer pegs above 50% during the post-action window, opening historic sessions reproduces the issue and the trigger is "DOM size at hydration", not "active streaming load". If it doesn't peg, the trigger is something else (incremental updates during active streaming) and a different test is needed.

The persistent logger now also captures `claude=ren=X%/RSSM gpu=X%/RSSM main=X%/RSSM tot=X%/RSSM n=N` on every 30s tick, so you can correlate Claude.app load with overall system state across the full day.

### ~~Interpreting T1 vs T2~~ Historical note

T1 vs T2 interpretation logic from the original plan was based on a false premise (that T2 measured SentinelOne cold-verdict cost). Disregard the original interpretation. T2 is now understood to measure macOS code-signature verification, which exclusions don't affect.

## ~~SentinelOne action plan~~ Historical — already executed

Jon has admin on SentinelOne. The decision tree:

1. **If T2 shows cold-binary spawn is 5x+ slower than T1**: apply path exclusions.
2. **If T2 ~= T1**: SentinelOne is not the bottleneck. Skip exclusions, look elsewhere (Xcode/sim footprint).

Recommended exclusions if applying (low security cost given `ignore-scripts=true` + `min-release-age=7` are already in place):

| Path | Why |
|---|---|
| `~/Library/Developer/Xcode/DerivedData` | Build cache; massive churn during builds, no security-sensitive contents |
| `~/.npm`, `~/.nvm/versions/node` | Package cache + node binaries; runs constantly |
| `~/git/**/node_modules` | High file count; ignore-scripts already prevents postinstall RCE |
| `~/Library/Caches` | OS+app caches |

What to KEEP monitoring (essential, never exclude):
- `~/.ssh`, `~/.aws`, `~/Library/Keychains` — credential paths
- `~/Library/LaunchAgents`, `/Library/LaunchDaemons` — persistence vectors
- All process exec events (separate config from file-watch — keep enabled everywhere)
- All network egress monitoring

Manual SentinelOne config steps:
1. Open SentinelOne management console (or `sentinelctl`, depending on which interface admin gives)
2. Find the policy applied to this Mac
3. Add the path exclusions above to the "File system exclusions" or equivalent section
4. KEEP "Process Execution" and "Network" monitoring enabled
5. Save and let the policy push to the endpoint (usually ~minute)

Verify the exclusions didn't break detection — synthetic tests:
```bash
# Test 1: process exec outside dev paths should still trigger SentinelOne
/tmp/no_such_binary 2>/dev/null  # benign, just see if SentinelOne logs the attempted exec

# Test 2: credential-path access should still trigger
echo test | tee ~/.ssh/sentinel_test_pls_delete >/dev/null && rm ~/.ssh/sentinel_test_pls_delete

# Test 3: suspicious-network connection should still trigger
curl -fsSL evil.example.invalid >/dev/null 2>&1
```

Check SentinelOne console after each — if detection still fires, exclusions didn't blind it to the things that matter.

Re-run T2 after exclusions are applied. If T2 elapsed_ms drops materially (5x+), the exclusion worked.

## Monitor improvements deferred until after repro

Jon's existing `com.jontz.memory-monitor` needs three changes once OOM is reproducible:
1. Drop poll interval from 30s → 10s
2. Add rate-of-change signal (warn if free drops >5 GB in 60s, independent of absolute level)
3. Repeat critical alerts every N ticks while in critical state (not just on transition)
4. Backup notification path (`say "memory critical"` via TTS) since osascript modals are fragile on Sequoia
5. Tighten thresholds: warn at `freeMB < 15000`, critical at `freeMB < 8000`, plus compressor-based critical at `compressorMB > 40000`

Don't change the monitor until after T2 + the SentinelOne exclusion test — we need the original behavior as the comparison baseline.

## Workflow for fresh session

1. Reboot when ready
2. After login, run `~/.config/agent-watcher/oom-repro/scripts/install.sh --status` — confirm persistent logger is running
3. Run `~/.config/agent-watcher/oom-repro/scripts/oom-repro-suite.sh T0 T1 T2` — cheap controlled tests, takes ~5 min
4. Look at `~/.config/agent-watcher/oom-repro/logs/tests/T1-*.log` and `T2-*.log`. Compare elapsed_ms between T1 (cached) and T2 (uncached).
5. Run `oom-repro-suite.sh T6` — full workflow
6. Use Edge with the large account normally for 30+ min
7. Watch `tail -f ~/.config/agent-watcher/oom-repro/logs/trace-$(date +%Y-%m-%d).log` in another terminal
8. When the OOM signals appear (or you call uncle), stop. Capture the final trace line + vm_stat output for record.
9. Compare against the baseline (T0). The delta is the OOM trajectory.

If T2 shows SentinelOne is the cost: apply exclusions per the action plan, reboot, repeat steps 1–8. Compare. Job done.

If T2 doesn't show SentinelOne cost: the bottleneck is Xcode/sim/Edge itself. Options then are:
- Side-by-side install of Xcode 16.x (older Xcode has lighter lldb + lighter sim runtime)
- Run Edge via `simctl launch` instead of Cmd+Play (saves the 5.5 GB lldb-rpc-server)
- `killall lldb-rpc-server` periodically during Edge dev to reset its baseline
- Add agent-spawning gates that refuse to spawn when free memory < 20 GB

## Files Jon has agreed are pending publish to edge-dev-agents

These are local-ahead of `~/git/edge-dev-agents:jon`. Run `/convention-sync` when ready (after OOM investigation concludes, not now):

- `~/.cursor/skills/pr-land/scripts/pr-land-comments.sh`
- `~/.cursor/skills/pr-land/scripts/pr-land-discover.sh`
- `~/.cursor/scripts/tool-sync.sh`
- `~/.cursor/skills/one-shot/SKILL.md`
- `~/.cursor/skills/pr-create/SKILL.md`
- `~/.cursor/skills/asana-task-update/SKILL.md`
- `~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh`
- `~/.cursor/skills/install-deps.sh`
- `~/.cursor/skills/verify-repo.sh`
- `~/.cursor/skills/build-and-test/SKILL.md` (refactor) + `scripts/*.sh` (new)
- `~/.cursor/skills/debugger/SKILL.md` (new) + `scripts/*` (new)
- `~/.cursor/scripts/tool-sync.sh` (already listed, but for the agent-watcher: scripts under `~/.config/agent-watcher/` are NOT in scope for /convention-sync — those are host-specific)
