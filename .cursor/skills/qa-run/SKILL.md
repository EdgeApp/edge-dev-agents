---
name: qa-run
description: Orchestrated QA pass on a finished dev run (agent_status=Complete, agent_qa=Pending). Plans the corner cases the dev run did not reach, gets the plan judged, drives only the approved cases with /build-and-test on the pinned PR head, and posts one verdict (Passed, Skipped, Blocked, Failed). The watcher invokes it as `/qa-run --yolo <asana-url>` in tmux session `qa-asana-<gid>` with AGENT_MODE=qa; never invoked by hand.
compatibility: Requires jq, gh, ASANA_TOKEN and AGENT_MODE=qa (exported by spawn-test-session.sh --qa), plus AGENT_SIM_UDID and AGENT_METRO_PORT (the pool sim and slot the watcher spawns every QA session with).
metadata:
  author: j0ntz
---

<goal>Test what the dev run did not, on the exact PR head it left, and post one judged verdict without touching the dev deliverable.</goal>

<rules description="Non-negotiable constraints. The run-wide rules in `~/.cursor/skills/one-shot/references/run-rules.md` (`yolo-execution`, `never-self-respawn`, `no-script-bypass`, `usage-pause`, `claude-calls-on-subscription`) bind here as written there.">
<rule id="read-only-session">This session changes nothing it did not create: no commits, pushes, PR edits or PR comments, no `update-status.sh`, no `agent_status` or `blocked` write, no install step (`npm ci`, `yarn`, `pod install`), no checkout. The only Asana writes are the ones `qa-start.sh`, `qa-gate.sh` and `qa-verdict.sh` make.</rule>
<rule id="phase-from-script">`qa-start.sh` decides the phase. Run it first, every time, and do only that phase: `plan` reads `references/planning.md`, `run` reads `references/running.md`, `done` ends the turn. One session runs the whole pass: after the plan gate allows a cases plan, run `qa-start.sh` again and continue with `PHASE=run`. Exit 3 prints `REASON=`: end the pass with `qa-verdict.sh --gid <gid> --abandon "<REASON text>"` and end the turn.</rule>
<rule id="beyond-dev-never-repeat">A case exists only when the dev run did not prove it, it is reachable from the diff, a real user can be in that state, and it needs no tracked-file edit. No such case means a skip plan. Rerunning the happy path, re-checking dev screenshots or sweeping every asset is never a case.</rule>
<rule id="approved-cases-only">The Running phase drives exactly the cases in the approved plan (`APPROVED_PLAN`), in order, and nothing else. A new idea mid-drive goes in the report's not-covered list.</rule>
<rule id="no-product-fixes">QA reports app defects; it never fixes them. A reproduced defect is a Failed verdict, and the watcher re-arms the dev run with it.</rule>
<rule id="verdict-script-only">Every verdict posts through `~/.cursor/skills/qa-run/scripts/qa-verdict.sh` (or `qa-gate.sh` for a skip). Never post the comment or attach the report another way. Formats live in `references/verdict.md`.</rule>
<rule id="end-turn-after-gate-or-verdict">When `qa-verdict.sh` prints `POSTED` (directly, or through `qa-gate.sh` on a skip plan), end the turn at once. The script kills this session shortly after. A gate allow on a cases plan is not an end: continue to step 3.</rule>
</rules>

<step id="1" name="Start">
```bash
~/.cursor/skills/qa-run/scripts/qa-start.sh
```
Act on `PHASE` per `phase-from-script`. `REPO_DIR` is the dev worktree: every read, drive and build happens there.
</step>

<step id="2" name="Plan (PHASE=plan)">
Read `~/.cursor/skills/qa-run/references/planning.md` and follow it to write `PLAN_FILE`, then run `~/.cursor/skills/qa-run/scripts/qa-gate.sh`.
1. Exit 0 on a cases plan → run `qa-start.sh` again (`PHASE=run`) and go to step 3. Exit 0 on a skip plan prints `POSTED` → end the turn (`end-turn-after-gate-or-verdict`).
2. Exit 1 → revise the plan per each failed item, rerun. A third deny → `qa-verdict.sh --gid <gid> --abandon "plan gate denied three times: <last summary>"`.
3. Exit 3 → rerun once; a second 3 → `--abandon "QA judge unavailable"`.
4. Exit 4 → fix the shape error it names, rerun.
</step>

<step id="3" name="Run (PHASE=run)">
Read `~/.cursor/skills/qa-run/references/running.md` and drive the approved cases, then post per `~/.cursor/skills/qa-run/references/verdict.md`.
</step>

<edge-cases>
<case name="Pool sim missing">`qa-start.sh` exits 3 in the run phase; abandon with its reason. Never allocate a sim yourself.</case>
<case name="Snapshot or pinned-sha refusal at verdict">Exit 4. A config switch left on → revert it in `REPO_DIR` and rerun. The PR head moved → `--abandon "dev branch moved during QA"`.</case>
<case name="Judge unavailable at verdict">Rerun once; a second exit 3 → `--abandon "QA judge unavailable at verdict"`.</case>
</edge-cases>
