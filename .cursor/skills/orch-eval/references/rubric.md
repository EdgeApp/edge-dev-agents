# Orch-Eval Rubric — Infrastructure Health of an Agent Run

Derived from the cited local-research pass over `~/.config/agent-watcher` + `~/Library/LaunchAgents` (2026-06-10).
Verdicts: `GOOD` | `MINOR` | `BAD` | `NA` | `NOT_CAPTURED`. **GATE** dimensions hard-fail the run when BAD.

## Dimensions

| # | Dimension | GOOD | BAD | Key thresholds / grounding |
|---|---|---|---|---|
| O1 | slot-citizenship | one `claude-asana-<gid>` session, one slot record, unique slot_index, admitted under cap | over-cap spawn; duplicate/orphan session for the gid | cap = the LIVE `.watcher.max_concurrent` in asana-config.json (read it at eval time — it changes; do not assume a number); `asana-watcher.js` cap check + at-cap short-circuit. Primary evidence: run-report capture fields and the release receipt; live slots.json only for in-flight runs. |
| O2 | **no-fork-storm (GATE)** | run's `cli` procs stay a flat tree ≲16 in one pgid; no RECORD/KILL events in window | pgid crossed 25 (forensic RECORD) or 50 (`kill -9 -PGID`); run seeded a self-replicating chain | thresholds 25 record / 50 kill (`runaway-guard.sh`); evidence: runaway-guard.log RECORD/KILL lines + forensics reports in window (seed-ancestor trace identifies the owning session) |
| O3 | **no-memory-critical (GATE on critical)** | memory stayed green in window; no cliCount growth in mem-trace | critical transition in window (avail<1.5% / compressor>50% / any swap) attributable to the run; warn-only = MINOR | `memory-monitor.sh` warn 6%/25%, crit 1.5%/50%/swap>0; `/tmp/memory-monitor.log` + mem-trace daily logs (7-day retention) |
| O4 | liveness | no watchdog revive needed; pane kept advancing | `<watchdog-revive-ping>` present in transcript (idle >20 min with RC down) | `session-watchdog.js` IDLE_THRESHOLD 20 min; revive ping lands IN the transcript → durable. manifest `signals.revive_pings_in_transcript` |
| O5 | process-survival | live claude under the pane throughout; clean retirement | death-path log for the session (claude died; no auto-resume exists) | `session-watchdog.js` death-path; evidence: watchdog log mentions + session gone while status in-flight |
| O6 | resource-release | at Complete: session retired to `done-asana-<gid>`, sim → dirty, slot released, Metro port freed, worktree retained; DURING the run: after planning, the lane decision was recorded (`$STATE/lanes/<gid>.json`, from one-shot:`lane-release-after-plan`) and a non-sim-lane / land-only run released its sim early (decision `release`) while any sim-lane run kept it — a `release` decision on a run that later drove the sim, or a lanes file absent on a post-2026-07-14 planned run, is a finding | sim/slot/Metro still held after Complete; Metro listener left to collide on port reuse | `session-watchdog.js` retire sweep; one-shot:`lane-release-after-plan` + `$STATE/lanes/<gid>.json` for the early-release decision. **Default NOT_CAPTURED post-hoc (release leaves no durable record). Live check possible shortly after Complete: manifest slot/pool_entry non-null on a Complete run = BAD (leak). null = NOT_CAPTURED, not GOOD.** |
| O7 | blocked-shed | if blocked=Yes occurred: sim+Metro shed once, slot+session retained, re-armed on unblock | held sim/Metro while blocked; lost slot/lane during block | `session-watchdog.js` shed-on-block + heavyFreed; NA if the run never blocked |
| O8 | workspace-status-contract | worktree `~/git/.agent-worktrees/<gid>/<repo>` on `<prefix>/<gid>` off correct base; env.json real copy; agent_status advanced Pending→…→Complete without skips | branch off protected ref; symlinked/missing env.json; status skipped states or stuck | `setup-task-workspace.sh`, `update-status.sh` (6 legal statuses). Status timeline: the TRANSCRIPT's update-status.sh calls + section-move stories are authoritative — Asana collapses consecutive same-actor status stories into one ("Pending to Complete"), so the story log understates the ladder |
| O10 | master-sim-integrity | every simctl/maestro device op in the transcript targets the slot's clone via `$AGENT_SIM_UDID`; the master sim is never built to, driven, erased, or resolved by device name / raw `booted` | any build/install/drive/erase against the master UDID or a by-name/`booted`-resolved sim (pollutes the golden image every future slot clones from) | build-and-test:`slot-sim-is-the-clone`; evidence: transcript simctl/maestro invocations vs the slot UDID in the manifest and the master UDID in `$XDG_STATE_HOME/agent-watcher/master-build.json` — NA if the run never touched a sim |
| O9 | concession-validation-gated | every CONCESSION from the prescribed bar went through the concession gate before it landed — BOTH kinds: (a) a formal `blocked=Yes`, and (b) a DOWNGRADE-finalize (the run reached `Complete` or opened a PR while its latest `blocking.attempt_log` result was a wall `blocked:`/`failed:`/`loss:`, i.e. it never reached the prescribed in-app success). For each, `blocking.validator_verdict` exists, its `kind` matches the concession, and it approved THIS reason | a `blocked=Yes` with no `validator_verdict`; a `Complete`/PR-open whose last attempt-log entry is a wall but no `validator_verdict` exists (the silent-downgrade bypass — the Xgram miss this gate was extended to catch); a verdict whose `reason_hash` does not match the claimed reason | `require-concession-validation.sh` PreToolUse gate + concession-validator; manifest `blocking` (`validator_verdict.kind`, `attempt_log`). NA if the run set no block AND its last attempt-log entry was `success` (no concession) (2026-06-16+) |

## Cross-cutting invariants (flag any violation as BAD on the nearest dimension)

- Guards are best-effort by design — a guard script failure that wedged a run is an infra bug, not run misbehavior; report separately.
- Operator-resume from inside an agent session (`resume-task.sh` refusal bypassed) = O1 BAD + flag for /agent-eval A6.
- `in_use` sim reclaimed out from under a live run, or live worktree pruned = infra bug; report separately from the run verdict.

## Evidence lifetime map (decide verdict vs NOT_CAPTURED honestly)

| Evidence | Lifetime | Feeds |
|---|---|---|
| Transcript JSONL | durable | O4 (revive ping), O5 hints |
| Asana story log (status transitions) | durable | O8, O7 (blocked timeline) |
| runaway-guard.log | rolling ~2000 lines | O2 |
| forensics reports (`$XDG_STATE_HOME/agent-watcher/forensics`) | persist | O2 |
| memory-monitor.log + mem-trace logs | tick log + 7 days | O3 |
| watchdog log (`/tmp/session-watchdog.out`) | until reboot/rotation | O4, O5, O6 hints |
| slots.json / pool.json | seconds after Complete | O1, O6 (live-only) |
| tmux sessions | ~3 completions (retired cap) | O5, O6 |
| worktree | ~5 completions (prune cap) | O8 |

**Policy:** never report GOOD on a dimension whose evidence is gone — that is NOT_CAPTURED. GOOD requires positive evidence. The capture hook shipped 2026-06-10 in two parts: (1) the watchdog writes a durable **release receipt** to `$XDG_STATE_HOME/agent-watcher/releases/<gid>.json` at retirement (`released:{sim,slot,metro}` + slot identity) — surfaced as `release_receipt` in the /resolve-run manifest; (2) the run-report frontmatter carries `slot_index`/`metro_port`/`sim_udid`. Use the receipt as primary O6 evidence and the frontmatter as primary O1 evidence. Runs retired before the hook (or whose receipt shows `released.slot: false` because the slot was already gone) remain NOT_CAPTURED — say so.
