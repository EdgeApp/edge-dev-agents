# agent-watcher

Host-local control plane that turns **Pending** Asana tasks into autonomous
`claude --rc` sessions. As of the parallelization work it runs up to
`MAX_CONCURRENT` sessions at once — each in its own git worktree, on its own
cloned iOS simulator, on its own Metro port — behind a resource guardrail.

> This directory is **not** git-tracked. The runtime files here *are* the
> deliverable. A snapshot is mirrored to `edge-dev-agents:jon` (`agent-watcher/`)
> purely as a paper trail; the live copy is what runs.

## Parallel architecture

```
launchd ──tick──▶ asana-watcher.js ──┐
                                     ├─ per picked task:
                                     │    setup-task-workspace.sh  → worktree
                                     │    clone-ios-sim.sh         → sim clone
                                     │    lib/slots.js allocate     → slot + Metro port
                                     │    spawn-test-session.sh     → tmux: claude --rc
launchd ──tick──▶ session-watchdog.js ────┘
                    └─ on agent_status=Complete:
                         retire tmux (rename→done-asana-<gid>, claude kept alive) ▸ delete-ios-sim.sh ▸ slots release ▸ worktree retained
```

### Slot model

A **slot** is one parallel lane. Each slot owns:

| resource   | where it comes from                         | naming                     |
|------------|---------------------------------------------|----------------------------|
| worktree   | `setup-task-workspace.sh`                   | `~/git/.agent-worktrees/<gid>/<repo>/` on branch `agent/<gid>` |
| iOS sim    | `clone-ios-sim.sh` (clones the master)      | `agent-sim-<gid>`          |
| Metro port | `lib/slots.js` (`metro_base_port + slot_index`) | slot 0 → 8081, slot 1 → 8082, … |

**Accounting is by LIVE tmux sessions, not Asana state.** The watcher enforces
the cap against the count of real `claude-asana-*` tmux sessions. `slots.json` is
*bookkeeping for teardown* (which sim/worktree to reap), not the cap itself. So a
task that is blocked-or-in-flight in Asana but whose tmux session has died does
**not** hold a slot — its lane is immediately reusable.

### Lifecycle

1. **Spawn** (`asana-watcher.js`): pick oldest `(MAX - active)` Pending tasks; for
   each, set `Planning`, create worktree, clone sim, allocate slot, start the tmux
   session. The session's wrapper bash exports `$AGENT_SIM_UDID` and
   `$AGENT_METRO_PORT` so build-and-test and debugger inherit them transparently.
2. **Run**: the spawned `claude` runs `/one-shot --yolo <task-url>` in its worktree.
3. **Retire** (`session-watchdog.js`): when Asana shows `agent_status=Complete`, RETIRE the
   session — rename `claude-asana-<gid>` → `done-asana-<gid>` (so it no longer holds a slot)
   while leaving `claude` alive for inspection / remote re-engagement — kill its Metro, delete
   the cloned sim, drop the slot, and retain the worktree. The oldest retired sessions beyond
   `keep_completed_sessions` (default 3) and worktrees beyond `keep_completed_worktrees`
   (default 5) are pruned. Set either to 0 for the old hard-kill/destroy behavior.
4. **Shed-on-block** (`session-watchdog.js`): when a session's task has `blocked=Yes`, free its
   heavy resources (sim + Metro) so it stops squatting while it waits on a human, but keep the
   session + slot alive so it can resume on unblock. Done once and re-armed when unblocked.
   (A resumed task re-provisions its sim/Metro via build-and-test, since the sim returns to the pool.)

## Configuration knobs (`asana-config.json` → `.watcher`)

| key                              | default            | meaning |
|----------------------------------|--------------------|---------|
| `max_concurrent`                 | `2`                | Max parallel sessions. Env override `AGENT_WATCHER_MAX_CONCURRENT`. |
| `metro_base_port`                | `8081`             | Slot N → port `metro_base_port + N`. |
| `master_sim.device` / `.runtime` | iPhone 16 Pro Max / iOS 18 | Master sim cloned per slot (holds the test account). |
| `resource_guardrail.max_load_avg`| `12.0`             | Skip the tick if 1-min load avg exceeds this. Env override `AGENT_WATCHER_MAX_LOAD_AVG`. |
| `resource_guardrail.min_free_ram_gb` | `8.0`          | Skip the tick if free RAM is below this. Env override `AGENT_WATCHER_MIN_FREE_RAM_GB`. |
| `npm_migration_commit`           | `4d169a59e2`       | Cherry-picked onto each fresh worktree (yarn→npm). |
| `default_repo`                   | `edge-react-gui`   | Repo a spawned agent works in. |
| `worktrees_root` / `repos_root`  | `~/git/.agent-worktrees` / `~/git` | Path roots. |

### Guardrail defaults — why these values

Tuned for this host: **128 GB RAM, 16 logical cores** (`sysctl hw.memsize` =
137438953472, `hw.logicalcpu` = 16).

- `max_load_avg = 12.0` ≈ 0.75 × 16 cores. Leaves headroom before the machine is
  saturated; an RN/Xcode build is CPU-heavy and spikes load, so we don't want to
  pile a third build onto an already-busy box.
- `min_free_ram_gb = 8.0` (raised from the spec's conservative 4.0 floor). Each
  lane is `claude` + Metro + an Xcode build + a booted sim clone, which can
  transiently want 8–16 GB. Requiring ≥ 8 GB free before spawning another lane
  keeps us off the swap cliff even though 128 GB is generous.
- `max_concurrent = 2` — the spec default. The hardware could sustain 3–4, but 2
  is the validated starting point; bump it in config once 2-wide is proven.

## Inspecting `slots.json`

```bash
cat ~/.config/agent-watcher/slots.json | jq
node ~/.config/agent-watcher/lib/slots.js list
node ~/.config/agent-watcher/lib/slots.js get --task-gid <gid>
```

Shape:

```json
{ "slots": [
  { "slot_index": 0, "task_gid": "12…", "worktree_path": "…/edge-react-gui",
    "sim_udid": "XXXX-…", "metro_port": 8081, "spawned_at": "2026-05-27T…Z" }
] }
```

Writes are atomic (tmpfile + rename) and serialized by an exclusive lock
(`slots.json.lock`, stale-stolen after 30 s), so concurrent allocate/release from
the watcher, watchdog, and CLI never corrupt the file.

## Manual garbage collection

`gc-worktrees.sh` is **not** on launchd. Run it by hand when you suspect leaked
worktrees (e.g. after a crash/reboot left a session half-cleaned):

```bash
~/.config/agent-watcher/gc-worktrees.sh --dry-run   # report orphans only
~/.config/agent-watcher/gc-worktrees.sh             # tear them down
```

It scans `~/git/.agent-worktrees/`, asks Asana the status of each task, and reaps
any whose task is `Complete` or has been deleted. In-flight tasks are left alone.

## Env-var contract (`$AGENT_SIM_UDID`, `$AGENT_METRO_PORT`)

Watcher-spawned sessions get these exported in the bash that wraps `claude`:

- `$AGENT_SIM_UDID` — the slot's cloned simulator UDID. `select-ios-sim.sh
  --accept-udid` confirms it boots; `ios-rn-build.sh` targets it when `--udid` is
  not passed.
- `$AGENT_METRO_PORT` — the slot's Metro port. `ios-rn-build.sh` passes `--port`
  to `react-native run-ios` when it differs from 8081; `check-metro.sh` and
  `cdp-attach.js` default their `--port`/`--metro` to it.

Manual runs (no env set) behave exactly as before: sim is resolved by
name/runtime, Metro defaults to 8081.

## Files

| file | role |
|------|------|
| `asana-watcher.js` | spawner (multi-pick, cap, guardrail) |
| `session-watchdog.js` | liveness + completion sweep (slot reaper) |
| `spawn-test-session.sh` | start a `claude --rc` tmux session (slot mode + legacy mode) |
| `setup-task-workspace.sh` / `cleanup-task-workspace.sh` | worktree create / teardown |
| `clone-ios-sim.sh` / `delete-ios-sim.sh` | per-slot sim clone / delete |
| `lib/slots.js` | atomic slot allocator (lib + CLI) |
| `slots.json` | slot state |
| `gc-worktrees.sh` | manual orphan cleanup |
| `resume-agent.sh` | resume a session; `--recover` re-provisions a missing slot |
| `asana-config.json` | project GIDs + `.watcher.*` knobs |
| `update-status.sh` | set `agent_status` (+ kanban section move) |

## Known limitations

- **Orphan cleanup on reboot**: launchd restarts the watcher/watchdog after a
  reboot, but tmux sessions don't survive. Worktrees + sim clones from before the
  reboot are orphaned until `gc-worktrees.sh` runs. There's no boot-time GC hook.
- **Sub-repo worktree caveats**: `edge-react-gui` already has nested worktrees
  (`.claude/worktrees`, `staging`). `git worktree add` for an agent slot is
  independent of those, but `worktree prune` operates repo-wide — don't prune
  while another tool is mid-worktree-add.
- **Cloning a booted master**: `simctl clone` snapshots a booted master fine, but
  the snapshot reflects the master's state at clone time. If the master is mid-PIN
  entry the clone inherits that; clone from a settled master.
- **Metro port reuse**: ports are derived from `slot_index`, which is reused after
  a slot frees. If a session left Metro bound to its port, the next slot on that
  index can collide. On retirement the watchdog explicitly kills the listener on the
  slot's Metro port (`freeMetroPort`) before/while freeing the slot — claude stays
  alive but its Metro does not — so this only bites if Metro was orphaned
  out-of-band. (Re-engaging a retired session means restarting Metro yourself.)
- **Guardrail is a snapshot**: load/RAM are read once per tick. Two lanes spawned
  in the same tick both see pre-spawn headroom; the cap (not the guardrail) is the
  real backstop against oversubscription.
