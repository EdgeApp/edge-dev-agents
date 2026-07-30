---
name: eval-run
description: Orchestrate evaluation of orchestrated agent runs. DEFAULT is the cheap report-eval (grade each run's report against live GitHub/Asana state, transcripts never opened); the heavy transcript-eval (full process pass over session transcripts + orch-eval) is a one-off on named gids or ones a report-eval escalated. Use when the user wants to evaluate/score agent runs (e.g. "eval everything since yesterday", "score run <gid>", "run the evals").
---

<goal>Produce a verified, citation-backed verdict for each run in scope — report-eval by default (ceiling REPORT_CLEAN | PASS_WITH_FINDINGS | FAIL, plus transcript-eval escalation suggestions), transcript-eval on request (GOLD | PASS_WITH_FINDINGS | FAIL) — plus a cohort report with recurring patterns and an Actions checklist of remediation drafts for operator approval.</goal>

<rules description="Non-negotiable constraints.">
<rule id="two-eval-types">Always name which type ran; never conflate them. REPORT-EVAL (default): grades what the run CLAIMED — run-report vs live GitHub/Asana APIs — via agent-eval's `report` profile; transcripts are NEVER opened; a clean result is REPORT_CLEAN, never GOLD; every run emits transcript-eval escalation suggestions per that profile's heuristics. TRANSCRIPT-EVAL (one-off, heavy): the full process pass over the session transcript plus /orch-eval; the only path to GOLD; run it ONLY on explicitly named gids or on report-eval escalation candidates the operator approved. Ledger naming keeps the types distinct: report-evals write `<gid>-report-eval.md`, transcript-evals write `<gid>.md` (every pre-2026-07-29 eval file is a transcript-eval); `eval-coverage.sh` reads both lenses.</rule>
<rule id="orchestrate-existing-skills">This skill only resolves scope, launches the companion workflow, and delivers results. The evaluation logic lives in /agent-eval and /orch-eval (invoked as workflow subagents); resolution lives in /resolve-run's script. Do not re-implement any of it inline.</rule>
<rule id="workflow-does-the-work">Launch via the Workflow tool with `scriptPath: ~/.cursor/skills/eval-run/eval-run.workflow.js` (not name-registry discovery). Pass `args` as a real JSON object: `{manifests: [...], runDate: "YYYY-MM-DD", mode: "report"|"transcript"}` — mode defaults to `report`.</rule>
<rule id="verdict-policy">Gates hard-fail a run: completion-honesty (A3), halt-discipline (A16), no-fork-storm (O2), no-memory-critical (O3). GOLD = all gates green AND zero confirmed BAD across all dimensions. NOT_CAPTURED never blocks GOLD but is always listed as a coverage gap. This policy is ours (the source skills define no thresholds) — do not invent numeric point scores.</rule>
<rule id="completed-runs-only">Runs with `in_flight: true` or no transcript are skipped and listed as such, never silently dropped.</rule>
<rule id="read-only">The entire eval set mutates nothing it evaluates. Output goes only to `~/agent-evals/<date>/` and chat.</rule>
<rule id="actions-are-drafts">The cohort report's `## Actions` section contains typed remediation DRAFTS, never executed work — the eval surfaces, the operator approves, the main session executes with existing primitives (set-tested.sh, update-status.sh + the followup template, playbook promotion, /author). Present the Actions as a checklist the user can approve row-by-row; execute ONLY approved rows. Re-run followup comments are stamped from `references/followup-comment-template.md` (gap + bar per the action item; the standing-policy block comes from the template, do not hand-write it).</rule>
</rules>

<step id="1" name="Resolve scope (inline scout)">
Decide the type first per `two-eval-types`: explicit gids named for a deep dive, "transcript", "deep", "friction", or approved escalation rows → transcript-eval; everything else → report-eval (the default).

Default report-eval scope comes from the coverage ledger, not a date guess:

```bash
~/.cursor/skills/eval-run/scripts/eval-coverage.sh --queue report   # STALE/NEVER rows = the work list
```

Then resolve manifests (90000ms+ timeout): `~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid <gid>` per target (or `--since <date>` when the user scoped by date).

Show the user the target list (gid, task name, eval type, evaluable-or-skipped + reason) before launching. Report-evals need a run report, not a transcript; a run missing its report is skipped AND flagged as a transcript-eval candidate. If zero runs are evaluable, stop and say why.
</step>

<step id="2" name="Launch the workflow">
```
Workflow({
  scriptPath: "/Users/eddy/.cursor/skills/eval-run/eval-run.workflow.js",
  args: { manifests: <resolved array>, runDate: "<today YYYY-MM-DD>", mode: "report" | "transcript", profile: "<name, only for targeted transcript evals>" }
})
```

Omitted mode = `report` (the workflow forces agent-eval's `report` profile, one light agent per run, no orch-eval, no transcript reads). `mode: "transcript"` = the full pass; only use it for the named/escalated one-offs per `two-eval-types`.

FLOW CONSOLIDATION (manual trigger ONLY — never part of a normal cohort run, and never concurrent with another eval session: it is the single writer that may touch the flow library, which is what keeps parallel sessions from stomping it): when the operator explicitly asks (`--consolidate-flows`), run the curation pass INSTEAD of a cohort eval. This pass runs INLINE in the invoking session — deliberately NOT through the companion workflow (`workflow-does-the-work` applies to cohort evals only): consolidation is single-writer curation, and a multi-agent fan-out is precisely what it must never be. There is no consolidateFlows branch in eval-run.workflow.js by design. Inputs: the harvested corpus at `~/maestro-flow-corpus/` (`flows/` + `index.tsv`; re-harvest recent transcripts first if stale) plus every `flow_proposals` array from recent eval outputs / run reports. Work: cluster flows by sequence overlap, identify (a) sequences re-derived across sessions that a parameterized library flow would cover, (b) `[flow-update]` refactors, (c) existing library flows that should be split into composable subflows. Emit the result as typed `## Actions` rows (per `actions-are-drafts`: promote-flow / update-flow / split-flow, each with the proposed yaml, params, and for updates the caller-grep result). Only APPROVED rows get applied: edits to `~/.cursor/skills/build-and-test/maestro/common/` plus the playbook's Flow library index table, in the same pass.

TARGETED MODE: when the user asks a focused question ("is sim testing churn OK?") or passes `--profile <name>`, set `profile` to a name from agent-eval's `<profiles>` (e.g. `sim-testing`). The workflow then grades only that dimension subset and SKIPS orch-eval entirely — that is what makes it cheap. Additionally run `~/.cursor/skills/resolve-run/scripts/friction-scorecard.sh --since <window>` (zero-LLM) and embed its TSV in the report. Targeted verdicts: only gates inside the profile apply; GOLD is never awarded from a targeted run (it cannot see the other dimensions) — the report header says `targeted: <profile>`. KNOWN METRIC CAVEAT for sim-testing: the scorecard's `testing_to_drive_min` spans SEGMENTS, so multi-day re-armed tasks show huge values that are watermark artifacts, not churn — read it per-segment or ignore it for re-armed tasks.

It runs in the background (watch with /workflows): per run, /agent-eval and /orch-eval execute concurrently, every BAD finding is adversarially re-verified (refuted findings are demoted to MINOR with the refutation noted, not silently dropped), then verdicts are computed per `verdict-policy` and a cohort report is synthesized.
</step>

<step id="3" name="Deliver">
On completion, from the workflow result:
1. Write `~/agent-evals/<runDate>/cohort-report.md` (the `cohortReport` field), `~/agent-evals/<runDate>/results.json` (the workflow's `runs` array verbatim — each entry carries `eval_type`; the machine-readable verdict history that trend analysis and GATE-promotion decisions read), and one per-run file — `~/agent-evals/<runDate>/<gid>-report-eval.md` for report-evals, `<gid>.md` for transcript-evals, per `two-eval-types` (its `runs[i]` entry rendered: verdict, gates, confirmed findings with citations, dimension table, coverage gaps, and for report-evals the escalation verdict + reasons). In every rendered surface (reports AND chat), dimensions appear as id + name (`A14 review-response`), never a bare code — a reader who has never opened the rubric must be able to follow. Then make the mentions clickable: run `~/.cursor/skills/eval-run/scripts/annotate-report.sh <cohort-report.md> <each gid.md>` (one call, all files) — it linkifies every dimension mention to an appended `## Dimension glossary` whose entries carry the local rubric row (`path:line`) and a SHA-pinned GitHub permalink. In the CHAT summary, cite each dimension's rubric row as `path:line` on first mention (the harness renders it clickable); get the line numbers from `~/.cursor/skills/rubric-drift.sh --map`. Then run `~/.cursor/skills/rubric-drift.sh`; if it reports findings, append a `## Rubric Drift` section to the cohort report (the finding lines verbatim) and mirror each as an `## Actions` row (type: rubric-maintenance) — a CHANGED/MISSING anchor means the named dimensions may have graded against stale expectations; an UNCOVERED rule is behavior this cohort was not graded on. Triage/reconcile happens via /author per its post-authoring-actions, not here.
2. SendUserFile the cohort report.
3. Chat summary: verdict table first, then recurring patterns, then coverage gaps. Lead with how many runs hit GOLD.
4. Present the report's `## Actions` section as an approval checklist (type, task, evidence, the draft). For each row the user approves, execute it per `actions-are-drafts`: run the drafted set-tested.sh / update-status.sh commands, post followup comments stamped from `references/followup-comment-template.md`, apply approved playbook promotions, route skill-gap items to /author. `[transcript-eval]` rows (report-eval escalations) launch a follow-on transcript-eval workflow on the approved gids — that is the intended path to the deep dive, so surface them prominently. Unapproved rows stay in the report untouched.
</step>

<edge-cases>
<case name="First-ever eval of historical runs">Expect O1/O6 NOT_CAPTURED everywhere (capture hook not yet shipped) and A18 NA (runs predate the Testing-section feature). These are coverage gaps, not findings — say so explicitly in the summary.</case>
<case name="A finding implicates a skill definition">A confirmed BAD that traces to a skill gap (not agent misbehavior) feeds /author per fix-workflow-first; list it under recommended fixes — do not edit skills mid-eval.</case>
<case name="Re-running after a workflow edit">Use `resumeFromRunId` with the same args to reuse completed evaluator agents.</case>
</edge-cases>
