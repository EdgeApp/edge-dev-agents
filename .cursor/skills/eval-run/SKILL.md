---
name: eval-run
description: Orchestrate a full evaluation of orchestrated agent runs — resolve run context, fan out /agent-eval + /orch-eval per run, adversarially verify findings, and synthesize gates+graded verdicts into a cohort report. Use when the user wants to evaluate/score agent runs (e.g. "eval everything since yesterday", "score run <gid>", "run the evals").
---

<goal>Produce a verified, citation-backed verdict (GOLD | PASS_WITH_FINDINGS | FAIL) for each completed agent run in scope, plus a cohort report that surfaces recurring patterns and an Actions checklist of ready-to-execute remediation drafts (field corrections, re-run followups, playbook proposals, skill gaps) for operator approval.</goal>

<rules description="Non-negotiable constraints.">
<rule id="orchestrate-existing-skills">This skill only resolves scope, launches the companion workflow, and delivers results. The evaluation logic lives in /agent-eval and /orch-eval (invoked as workflow subagents); resolution lives in /resolve-run's script. Do not re-implement any of it inline.</rule>
<rule id="workflow-does-the-work">Launch via the Workflow tool with `scriptPath: ~/.cursor/skills/eval-run/eval-run.workflow.js` (not name-registry discovery). Pass `args` as a real JSON object: `{manifests: [...], runDate: "YYYY-MM-DD"}`.</rule>
<rule id="verdict-policy">Gates hard-fail a run: completion-honesty (A3), halt-discipline (A16), no-fork-storm (O2), no-memory-critical (O3). GOLD = all gates green AND zero confirmed BAD across all dimensions. NOT_CAPTURED never blocks GOLD but is always listed as a coverage gap. This policy is ours (the source skills define no thresholds) — do not invent numeric point scores.</rule>
<rule id="completed-runs-only">Runs with `in_flight: true` or no transcript are skipped and listed as such, never silently dropped.</rule>
<rule id="read-only">The entire eval set mutates nothing it evaluates. Output goes only to `~/agent-evals/<date>/` and chat.</rule>
<rule id="actions-are-drafts">The cohort report's `## Actions` section contains typed remediation DRAFTS, never executed work — the eval surfaces, the operator approves, the main session executes with existing primitives (set-tested.sh, update-status.sh + the followup template, playbook promotion, /author). Present the Actions as a checklist the user can approve row-by-row; execute ONLY approved rows. Re-run followup comments are stamped from `references/followup-comment-template.md` (gap + bar per the action item; the standing-policy block comes from the template, do not hand-write it).</rule>
</rules>

<step id="1" name="Resolve scope (inline scout)">
Parse the request into `--since <ISO-date>` or explicit gid(s), then run (90000ms+ timeout):

```bash
~/.cursor/skills/resolve-run/scripts/resolve-run.sh --since <date>   # or --gid <gid> per run
```

Show the user the target list (gid, task name, status, evaluable-or-skipped + reason) before launching. If zero runs are evaluable, stop and say why.
</step>

<step id="2" name="Launch the workflow">
```
Workflow({
  scriptPath: "/Users/eddy/.cursor/skills/eval-run/eval-run.workflow.js",
  args: { manifests: <resolved array>, runDate: "<today YYYY-MM-DD>" }
})
```

It runs in the background (watch with /workflows): per run, /agent-eval and /orch-eval execute concurrently, every BAD finding is adversarially re-verified (refuted findings are demoted to MINOR with the refutation noted, not silently dropped), then verdicts are computed per `verdict-policy` and a cohort report is synthesized.
</step>

<step id="3" name="Deliver">
On completion, from the workflow result:
1. Write `~/agent-evals/<runDate>/cohort-report.md` (the `cohortReport` field), `~/agent-evals/<runDate>/results.json` (the workflow's `runs` array verbatim — the machine-readable verdict history that trend analysis and GATE-promotion decisions read), and one `~/agent-evals/<runDate>/<gid>.md` per run (its `runs[i]` entry rendered: verdict, gates, confirmed findings with citations, full dimension table, coverage gaps). In every rendered surface (reports AND chat), dimensions appear as id + name (`A14 review-response`), never a bare code — a reader who has never opened the rubric must be able to follow. Then make the mentions clickable: run `~/.cursor/skills/eval-run/scripts/annotate-report.sh <cohort-report.md> <each gid.md>` (one call, all files) — it linkifies every dimension mention to an appended `## Dimension glossary` whose entries carry the local rubric row (`path:line`) and a SHA-pinned GitHub permalink. In the CHAT summary, cite each dimension's rubric row as `path:line` on first mention (the harness renders it clickable); get the line numbers from `~/.cursor/skills/rubric-drift.sh --map`. Then run `~/.cursor/skills/rubric-drift.sh`; if it reports findings, append a `## Rubric Drift` section to the cohort report (the finding lines verbatim) and mirror each as an `## Actions` row (type: rubric-maintenance) — a CHANGED/MISSING anchor means the named dimensions may have graded against stale expectations; an UNCOVERED rule is behavior this cohort was not graded on. Triage/reconcile happens via /author per its post-authoring-actions, not here.
2. SendUserFile the cohort report.
3. Chat summary: verdict table first, then recurring patterns, then coverage gaps. Lead with how many runs hit GOLD.
4. Present the report's `## Actions` section as an approval checklist (type, task, evidence, the draft). For each row the user approves, execute it per `actions-are-drafts`: run the drafted set-tested.sh / update-status.sh commands, post followup comments stamped from `references/followup-comment-template.md`, apply approved playbook promotions, route skill-gap items to /author. Unapproved rows stay in the report untouched.
</step>

<edge-cases>
<case name="First-ever eval of historical runs">Expect O1/O6 NOT_CAPTURED everywhere (capture hook not yet shipped) and A18 NA (runs predate the Testing-section feature). These are coverage gaps, not findings — say so explicitly in the summary.</case>
<case name="A finding implicates a skill definition">A confirmed BAD that traces to a skill gap (not agent misbehavior) feeds /author per fix-workflow-first; list it under recommended fixes — do not edit skills mid-eval.</case>
<case name="Re-running after a workflow edit">Use `resumeFromRunId` with the same args to reuse completed evaluator agents.</case>
</edge-cases>
