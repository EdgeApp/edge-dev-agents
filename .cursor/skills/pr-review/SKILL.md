---
name: pr-review
description: Unified PR review entry point. Deep multi-agent review by default (code-review-sonnet workflow) plus an Edge-conventions lens, curated into one findings set, with configurable GitHub posting (draft-and-confirm by default). Use for ANY PR review request, including review-only orch tasks.
compatibility: Requires git, gh.
metadata:
  author: j0ntz
---

<goal>Run the one canonical review path for a PR: deep verified findings plus Edge-conventions findings, curated together, delivered as a structured GitHub review or as drafts, per the posting config.</goal>

<rules description="Non-negotiable constraints.">
<rule id="unified-entry">This skill IS the review path. Review findings reach GitHub ONLY through step 6's submit (companion script) — never ad-hoc `gh pr comment`/`gh pr review`, and never by substituting another skill's posting. Finder engines (code-review-sonnet, a manual pass) feed step 5; they do not post.</rule>
<rule id="standards-first">Read review standards BEFORE examining code. Load both `~/.cursor/rules/review-standards.mdc` and `~/.cursor/rules/typescript-standards.mdc` in parallel (skip any already in context).</rule>
<rule id="use-companion-script">Use `~/.cursor/skills/pr-review/scripts/github-pr-review.sh` for all GitHub API operations. Do not use raw `curl`, `gh`, or MCP tools inline.</rule>
<rule id="no-script-bypass">If a companion script fails, report the error and STOP. Do NOT fall back to raw `gh`, `curl`, or other workarounds.</rule>
<rule id="no-duplicate-feedback">Check existing reviews AND `inlineComments` from the context output (inline comments include resolved threads). Do not repeat feedback already given by another reviewer — this dedupe applies to workflow findings and conventions findings alike.</rule>
<rule id="posting-gate">Posting is configured, never assumed. Default (no flag): present the formatted draft comments in chat and submit only after the user approves. `--comment`: submit without the ask. `--no-comment`: never submit; findings go to chat (and the run report in orch) only. In an orchestrated hands-off session the interactive ask is unavailable, so the default degrades to `--no-comment` with drafts delivered in the run report — post only when the task text explicitly directs posting.</rule>
<rule id="review-event">Every submitted review carries a verdict. `COMMENT` is never a choice: Critical or Warning findings after curation → `REQUEST_CHANGES`; Suggestion-only or zero findings → `APPROVE`, with the nits riding inline. An approval is a merge authorization here (pr-land discovers on review state and lands on approval), so the curation in 4c is what the verdict rests on — a finding downgraded to Suggestion to avoid blocking is a finding that lands the PR. GitHub refuses a review event on your own PR; the submit script detects that and falls back to `COMMENT`, naming the fallback in its output. When depth was degraded (`--quick`, or the workflow edge case) and the verdict is `APPROVE`, the review body says so.</rule>
<rule id="curation-owns-truth">Workflow findings are candidates, not conclusions. Before delivery, judge each against your own read of the diff: reject false positives (state the evidence), downgrade findings whose failure mode pre-exists the PR (say so in the comment), and drop findings that only restate a documented intent of the PR. Rejected findings are reported in chat/report, never posted.</rule>
<rule id="batch-reads">When reviewing changed files, batch independent Read/Grep calls in a single message.</rule>
<rule id="script-timeouts">The companion script may take up to 30s. Set `block_until_ms: 60000` when invoking it.</rule>
<rule id="diagram-escalation">Comments stay concise per the formatting sub-step. EXCEPTION: when a finding explains ordering, a race, or state-machine behavior — anything where the reader would otherwise simulate event interleavings — carry the mechanism in ONE ```mermaid block inside the comment (GitHub renders mermaid natively) and keep the surrounding prose concise. Sequence diagram for cross-component ordering, flowchart for gates. Participant IDs must not be mermaid keywords; tdd's `diagrams-and-signatures` rule owns the pitfall list. Never more than one diagram per comment; a finding that does not involve ordering stays prose-only.</rule>
</rules>

<flags description="All optional.">
- `--quick` — skip the deep workflow; conventions lens only (step 4b).
- `--level <low|medium|high|xhigh|max>` — depth of the deep workflow (default `high`). The level IS the fan-out agents' reasoning effort; see the model note in step 4a.
- `angles=N` — override the workflow's correctness-angle count (1-5) independently of level; passed through verbatim.
- `--comment` / `--no-comment` — posting config per `posting-gate`.
</flags>

<step id="1" name="Gather PR context">
Run the companion script to fetch PR metadata, changed files with patches, and existing reviews:

```bash
~/.cursor/skills/pr-review/scripts/github-pr-review.sh context [--pr <number>] [--owner <owner>] [--repo <repo>]
```

If the user provides a PR URL or number, pass `--pr`. If they also specify a repo, pass `--owner` and `--repo`. If nothing is provided, the script auto-detects from the current branch.

If the script exits code 2 with `PROMPT_GH_AUTH`, prompt: "`gh` CLI is not authenticated. Run `gh auth login` first."

Save the output JSON — it contains `number`, `title`, `url`, `author`, `headRef`, `baseRef`, `headSha`, `reviews[]`, `inlineComments[]`, and `files[]` (with patches).
</step>

<step id="2" name="Checkout PR branch">
Checkout the PR branch so file reads reflect the PR's code, not the current local branch:

```bash
git fetch origin <headRef> && git checkout <headRef>
```

If checkout fails due to uncommitted changes, prompt the user to stash or commit before proceeding. (The deep workflow's scope agent fetches its own refs; this checkout serves steps 4b and 5.)
</step>

<step id="3" name="Load review standards">
Read these files in parallel (skip any already present in context):

- `~/.cursor/rules/review-standards.mdc`
- `~/.cursor/rules/typescript-standards.mdc`
</step>

<step id="4" name="Analyze">
<sub-step id="4a" name="Deep workflow (default; skipped by --quick)">
Invoke the workflow with the level and target:

```
Workflow({ name: "code-review-sonnet", args: "<level> [angles=N] <pr-url>" })
```

It runs in the background; wait for its result (TaskOutput, blocking) before step 5. Its result carries `findings[]` (each with file/line/summary/failure_scenario/category/verdict) and `refuted[]`.

Model allocation, for cost awareness: the workflow's Scope and Synthesize agents inherit the session model; its Find/Verify/Sweep fan-out is pinned to Sonnet running at the level's effort (level IS effort, mirroring the official /code-review). Everything else in this skill runs inline on the session model.
</sub-step>

<sub-step id="4b" name="Conventions lens (always)">
Review each changed file's patch against the loaded standards, reading full files for context (batch reads):
- Convention violations from review-standards.mdc and typescript-standards.mdc
- Efficient memoization where necessary (memo, useHandler, useCallback)
- Unnecessary code, unnecessary JSX fragments, missed simplifications

This lens covers what the workflow's finders do not know (Edge-specific standards); do not re-hunt correctness bugs here at deep level — the workflow owns that.
</sub-step>

<sub-step id="4c" name="Curate">
Merge 4a + 4b into one findings set, then per `curation-owns-truth` and `no-duplicate-feedback`:
1. Drop duplicates of feedback already on the PR (`reviews[]`, `inlineComments[]`).
2. Reject false positives with cited evidence; keep the rejection list for the summary.
3. Categorize survivors: **Critical** (must fix before merge), **Warning** (should address), **Suggestion** (consider).
</sub-step>
</step>

<step id="5" name="Format draft comments">
<sub-step name="Comment formatting">
- Single line: use only `line`; multi-line range: `start_line` (first) + `line` (last); `side`: `"RIGHT"` for additions
- Keep comments concise, use backtick formatting for code, bold, or italics
- Ordering/race findings: one mermaid block carries the mechanism (`diagram-escalation`)
- Convention nits cite the published ruleset (the edge-dev-agents copy), never `~/.cursor/...` paths
- 1 inline comment: leave `body` empty (`""`); 2+ inline comments: only add `body` if it provides necessary linking context
</sub-step>
</step>

<step id="6" name="Deliver">
Resolve the posting decision per `posting-gate`:

1. `--no-comment` (or orch default) → do not submit; findings and drafts go to chat / the run report. Done, go to step 7.
2. Default interactive → show the drafts (grouped per PR file/line, with category) and the verdict `review-event` yields, ask the user which to post, then submit that subset.
3. `--comment` → submit directly.

Submit via the companion script with the event per `review-event` (`REQUEST_CHANGES` when any Critical or Warning finding survived, otherwise `APPROVE`):

```bash
echo '<review-json>' | ~/.cursor/skills/pr-review/scripts/github-pr-review.sh submit \
  --pr <number> --owner <owner> --repo <repo> --sha <headSha>
```

Review JSON format:
```json
{
  "event": "REQUEST_CHANGES",
  "body": "",
  "comments": [
    { "path": "src/file.ts", "line": 42, "side": "RIGHT", "body": "Comment text" }
  ]
}
```

The script prints `{id, state, url}`, plus `event_fallback` when GitHub refused the requested event. A run with zero findings still submits: an `APPROVE` whose body states what was reviewed and at what depth.
</step>

<step id="7" name="Summarize">
Provide a summary in the chat response:
- Number of files reviewed, depth used (level or quick)
- Findings by category (critical, warning, suggestion), plus the rejected-false-positive list with one-line reasons
- What was posted: the verdict submitted, a link to the review, and the `event_fallback` when the script reported one. Otherwise, that drafts await the user's go-ahead or that posting was off
- PR link as `[PR title](url)`
</step>

<edge-cases>
<case name="No PR found">Script exits with an error. Ask the user for a PR number or URL.</case>
<case name="No changed files">Report that the PR has no file changes.</case>
<case name="Large PR (>20 files)">The deep workflow scopes itself; for the conventions lens, prioritize files with the most additions and note any files skipped due to size (lockfile churn is always skippable).</case>
<case name="Server repo">If the repository name ends in `-server` or context indicates a server project, also review against the Server Conventions section in review-standards.mdc.</case>
<case name="Workflow unavailable or fails">If the Workflow tool is unavailable or the run errors, report it and continue with the conventions lens plus a manual correctness pass over the diff — say in the summary that depth was degraded. Do not silently claim deep coverage.</case>
<case name="Multiple PRs named">Run steps 1-4 per PR (workflows may run in parallel); curate and deliver per PR. One approval ask covers all drafts.</case>
</edge-cases>

<reference>
The path diagram (also synced to edge-dev-agents): `~/.cursor/skills/pr-review/review-path.md`.
</reference>
