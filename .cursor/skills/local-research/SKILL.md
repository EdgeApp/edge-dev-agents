<goal>Run a deep, multi-agent research pass over the LOCAL filesystem/codebase and produce a citation-backed report, by orchestrating the `local-research` workflow.</goal>

<rules description="Non-negotiable constraints.">
<rule id="local-not-web">This is the LOCAL counterpart to the built-in web `/deep-research`. The sources are files on disk (code, configs, skills, rules, logs), NOT the internet. Never substitute WebSearch/WebFetch — if the question is actually about the public web, tell the user to use `/deep-research` instead.</rule>
<rule id="workflow-does-the-work">The deterministic fan-out (scope → investigate → adversarially verify → synthesize) lives in the companion workflow `~/.cursor/skills/local-research/local-research.workflow.js`. Invoke it via the Workflow tool with `scriptPath` (do NOT reimplement the phases inline, and do NOT rely on `name:` registry discovery). This skill only scopes the request and relays the result.</rule>
<rule id="scope-before-fanout">If the request is underspecified — no clear question, or no idea WHERE to look — ask at most 2-3 clarifying questions FIRST (the research question, the root path(s) to search, desired output shape). Do not launch a fan-out over an ambiguous target; a wrong scope wastes a multi-agent run. If the roots are obvious from context (the user named a dir, or the cwd is clearly the subject), proceed without asking.</rule>
<rule id="citations-are-the-product">Every claim in the final report must carry a `path:line` (or `path:rule-id`) citation that a reader can open. A finding without a checkable local citation is not a finding. The workflow already enforces this via adversarial re-opening of each citation; surface that the report is citation-backed when you relay it.</rule>
<rule id="write-the-report-out">The workflow RETURNS the report markdown (it does not write files). After it completes, WRITE the report to a file (default `~/local-research-<short-slug>.md`) and deliver it with SendUserFile, plus a tight chat summary. Do not dump the full multi-KB report inline.</rule>
</rules>

<step id="1" name="Parse the request and pick scope">
From the user's args, determine:
- **question** (required): the thing to research. If absent/vague, apply `scope-before-fanout`.
- **roots** (where to look): the dir(s)/file(s) to search. Default to the current working directory if the subject clearly IS the cwd; otherwise infer from the question (e.g. "the orchestration system" → `~/.cursor`, `~/.config/agent-watcher`, `~/Library/LaunchAgents/com.jontz.*`). When unsure, ask.
- **breadth**: `medium` (default, 5 angles, single adversarial verifier) or `thorough` (7 angles, 3-vote adversarial verify) — choose `thorough` when the user says "comprehensive/exhaustive/audit" or the surface is large.
- **style**: `report` (default), `rubric` (evaluation criteria tables), or `map` (structure outline). Match the user's stated intent.
</step>

<step id="2" name="Launch the workflow">
Call the Workflow tool with the companion script and the parsed args object:

```
Workflow({
  scriptPath: "/Users/eddy/.cursor/skills/local-research/local-research.workflow.js",
  args: { question: "<question>", roots: ["<path>", ...], breadth: "medium"|"thorough", style: "report"|"rubric"|"map", hint: "<optional key files/gotchas>" }
})
```

Pass `args` as a real JSON object (not a stringified one). The workflow runs in the background and notifies on completion; tell the user they can watch with `/workflows`.
</step>

<step id="3" name="Deliver the result">
When the workflow completes, its result has `{ report, question, roots, breadth, style, angles, survivingCount }` (the full report is in the task output file if truncated in the notification). Then:
1. Write `report` to `~/local-research-<short-slug>.md`.
2. Deliver it via SendUserFile with a one-line caption (`<survivingCount> verified findings across <N> angles`).
3. In chat, give a tight summary: the angles covered, the headline findings, and any open questions the report flagged. Do not paste the whole report.
</step>

<edge-cases>
<case name="Question is really about the public web">Stop and point the user to `/deep-research` — this skill only reads local files.</case>
<case name="No findings survived verification">The workflow returns a short report saying so. Relay it and suggest narrowing the question or widening/correcting the roots — the scope likely missed the answer.</case>
<case name="Very large surface + a token budget directive">If the user attached a `+Nk` budget, prefer `breadth: "thorough"`; the workflow's per-angle 3-vote verify already scales the depth.</case>
<case name="Want it scored/reused later">Offer to fold a `rubric`-style output into the repo (e.g. for a `/task-review`-style evaluator) via `/convention-sync`.</case>
</edge-cases>
