---
name: orch-eval
description: Evaluate one orchestrated agent run's infrastructure health (fork-storm, memory pressure, liveness/revive, resource release, slot citizenship, workspace/status contract) against the agent-watcher guardrails. Consumes a /resolve-run manifest, grades against references/rubric.md, returns cited findings. Read-only. Use per-run, or via /eval-run for batches.
---

<goal>Grade a single agent run's footprint in the orchestration substrate (dimensions O1-O9), honestly distinguishing verdicts from NOT_CAPTURED where evidence has been pruned.</goal>

<rules description="Non-negotiable constraints.">
<rule id="read-only">Never mutate infra state: no tmux kills/renames, no slot/pool/worktree changes, no Asana writes. Inspect only.</rule>
<rule id="rubric-is-the-contract">Load `~/.cursor/skills/orch-eval/references/rubric.md` BEFORE grading. Its evidence-lifetime map decides verdict vs NOT_CAPTURED; follow it exactly.</rule>
<rule id="no-good-without-evidence">GOOD requires positive evidence (a log line, a story entry, a live observation). Pruned evidence = NOT_CAPTURED, never GOOD. O1/O6 default to NOT_CAPTURED post-hoc unless run-report capture fields exist or the check is running live shortly after Complete.</rule>
<rule id="run-vs-infra-bugs">Separate the run's behavior from infrastructure bugs. A guard that misfired, a sim reclaimed from under a live run, or a watchdog defect penalizes the INFRA (report under `infra_issues`), not the run's verdict.</rule>
<rule id="skip-in-flight">If the manifest says `in_flight: true`, stop and report the run as not evaluable yet.</rule>
<rule id="targeted-reads">Logs are large/rolling. Grep within the manifest `window` only; never read whole logs into context.</rule>
<rule id="use-probe-index">The manifest's `probe_index.update_status.ladder` is the pre-computed status timeline for O8 (verify at those lines, do not re-grep), and `auto_na` entries (e.g. O7 never-blocked) are accepted unless evidence contradicts. Every emitted finding carries BOTH the dimension id and its rubric name (`O6` + `resource-release`); human-facing output never shows a bare code without its name.</rule>
</rules>

<step id="1" name="Get the manifest">
If not handed one, run `~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid <gid>` (60000ms+ timeout). Honor `skip-in-flight`.
</step>

<step id="2" name="Gather window-scoped evidence (parallel greps)">
Using `window.start..window.end` from the manifest, in parallel:
- O2: `grep -n "RECORD\|KILL" <logs.runaway_guard>` filtered to window; list `logs.forensics_dir` files in window (a forensics report's seed-ancestor trace attributes the chain to a session).
- O3: window slice of `/tmp/memory-monitor.log` level transitions; `logs.mem_trace_dir` daily file for the run date (cliCount trend).
- O4: manifest `signals.revive_pings_in_transcript` (already counted; >0 = BAD with the transcript as citation).
- O5/O6 hints: `grep -n "<gid>" <logs.watchdog>` (retire/death/shed lines for this gid).
- O8: Asana story log for the status timeline; `git -C <worktree> ...` for branch/base when the worktree survives.
</step>

<step id="3" name="Grade O1-O9">
Apply the rubric's GOOD/BAD anchors per dimension. Specifics:
- **O6:** manifest `slot`/`pool_entry` non-null on a Complete run = BAD (leak, citable live observation). Null = NOT_CAPTURED unless run-report capture fields (`released:{sim,slot,metro}`) exist.
- **O7:** NA if the Asana story log shows blocked never went Yes during the window.
- **O3:** a warn/critical transition in the window is attributable to the run only with corroboration (run's build/test activity at that timestamp, or top-consumer line naming its processes); otherwise MINOR with "concurrent-run ambiguity" noted — up to 5 runs share the box.
</step>

<step id="4" name="Emit findings">
Return per-dimension `{id, verdict, evidence, citation}`, `gates: {O2, O3}`, `infra_issues` (substrate bugs found incidentally, e.g. the rubric's known doc-drift items are already filed — only NEW ones), and `notes`. When invoked standalone, also write `~/agent-evals/<YYYY-MM-DD>/<gid>-orch-eval.md` and summarize in chat: gates first, then BAD/MINOR, then coverage gaps.
</step>

<edge-cases>
<case name="Logs rotated past the window">runaway-guard.log self-rotates at ~2MB and mem-trace keeps 7 days: an empty grep on a rotated range is NOT_CAPTURED for that dimension, not GOOD. Say which log was rotated.</case>
<case name="Shared-box attribution">O2/O3 events in the window may belong to a concurrent run. Attribute via forensics seed-ancestor trace (O2) or process names in top-consumers (O3); unattributable events go to `infra_issues` as box-level observations, not this run's BAD.</case>
</edge-cases>
