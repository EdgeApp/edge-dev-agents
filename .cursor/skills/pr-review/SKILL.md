---
name: pr-review
description: Unified PR review entry point. Deep multi-agent review by default (code-review-sonnet workflow) plus an independent parent review (general code review and Edge conventions) on the session model, curated into one findings set, with configurable GitHub posting (draft-and-confirm by default). Use for ANY PR review request, including review-only orch tasks.
compatibility: Requires git, gh.
metadata:
  author: j0ntz
---

<goal>Run the one canonical review path for a PR: deep verified findings plus the session model's own independent review, curated together, delivered as a structured GitHub review or as drafts, per the posting config.</goal>

<rules description="Non-negotiable constraints.">
<rule id="unified-entry">This skill IS the review path. Review findings reach GitHub ONLY through step 6's submit (companion script) — never ad-hoc `gh pr comment`/`gh pr review`, and never by substituting another skill's posting. Finder engines (code-review-sonnet, a manual pass) feed step 5; they do not post.</rule>
<rule id="standards-first">Read review standards BEFORE examining code. Load both `~/.cursor/rules/review-standards.mdc` and `~/.cursor/rules/typescript-standards.mdc` in parallel (skip any already in context).</rule>
<rule id="use-companion-script">Use `~/.cursor/skills/pr-review/scripts/github-pr-review.sh` for all GitHub API operations. Do not use raw `curl`, `gh`, or MCP tools inline.</rule>
<rule id="no-script-bypass">If a companion script fails, report the error and STOP. Do NOT fall back to raw `gh`, `curl`, or other workarounds.</rule>
<rule id="no-duplicate-feedback">Check existing reviews, `threads`, AND `inlineComments` from the context output (resolved threads included). Do not repeat feedback already on the PR from ANY author, your own login included: reviews you wrote by hand and reviews earlier orch runs posted share one account and count the same. This dedupe applies to workflow findings and parent-review findings alike. When a finding matches one of your own unresolved threads and is still present at the head, answer that thread through `replies` ("still present at `<sha>`") instead of opening a new comment.</rule>
<rule id="posting-gate">Posting is configured, never assumed. Default (no flag): present the formatted draft comments in chat and submit only after the user approves. `--comment`: submit without the ask. `--no-comment`: never submit; findings go to chat (and the run report in orch) only. In an orchestrated hands-off session the interactive ask is unavailable, so the default degrades to `--no-comment` with drafts delivered in the run report — post only when the task text explicitly directs posting.</rule>
<rule id="review-event-mapping">A submitted review carries a real verdict, and AUTHORSHIP decides which events are legal. Step 1 resolves it (`gh api user --jq .login` vs `author`).

ON A PR WE DO NOT AUTHOR: `REQUEST_CHANGES` when the review found something that must change before merge (a Critical or High finding: a real defect, a dropped guard, a broken caller). `APPROVE` when it found nothing, or nothing beyond nits, style preferences, and optional suggestions. Deliver the nits as inline comments on the approving review rather than withholding the verdict over them. A round where nothing survived curation still submits that `APPROVE` (step 6 gives its body).

ON OUR OWN PR: `COMMENT` only. GitHub rejects a self-review verdict, so `APPROVE` or `REQUEST_CHANGES` there fails the API call instead of posting.

YOUR STANDING VERDICT (`myStanding` in the context output) carries over between rounds, since GitHub keeps your latest verdict. When it is `CHANGES_REQUESTED`, check every `myStanding.blockingThreads` entry at the head: a confirmed fix gets a reply with `resolve: true`; one still present gets a "still present" reply and the round stays `REQUEST_CHANGES`. `submit` refuses an APPROVE that leaves any of those threads open. When every blocking thread is confirmed fixed, submit `APPROVE` with those replies even if the round found nothing new.

`APPROVE` asserts that the review RAN and found no blocking defect. It is never a way to say "I did not look": a review that could not examine the diff, or whose workflow failed, submits nothing and says so. The mapping applies to every submission, whether `--comment` posted it directly or the user approved the draft first.</rule>
<rule id="curation-owns-truth">Workflow findings are candidates, not conclusions. Before delivery, judge each against your own read of the diff: reject false positives (state the evidence), downgrade findings whose failure mode pre-exists the PR (say so in the comment), and drop findings that only restate a documented intent of the PR. Rejected findings reach the PR only per `self-review-rejections`; everywhere else they go to chat/report. Parent-review findings (step 4b) get no independent verifier, so hold them to the same bar: each carries a concrete `failure_scenario` grounded in code you read, and curation re-judges them as strictly as workflow candidates.</rule>
<rule id="self-review-rejections">Findings curation rejected reach the PR only as the curation-record block (step 5) in the review BODY, never as inline comments: an inline thread is an unresolved conversation that pr-address and one-shot's followup routing treat as work owed. The block goes on every review this skill submits on a PR we author (`author == me`), and on every `APPROVE` on a PR we do not author. On our own PR, a round whose findings were ALL rejected still submits, as a `COMMENT` review carrying only that block, and a round left with nothing new submits nothing. Before listing a rejected finding, check your own earlier review bodies in `reviews[]`; one already listed there (same location, same claim) is not listed again. A `REQUEST_CHANGES` on a PR we do not author leaves rejected findings in chat and the run report. `posting-gate` still decides whether any review submits at all.</rule>
<rule id="finding-tags">Every inline finding names what produced it, so acceptance can be counted per rule. Each comment in the Review JSON carries `tag`; `submit` appends it to the comment body as a hidden last line, `<!-- pr-review:tag=<tag> -->` (an HTML comment, which GitHub does not render), and `render` prints the same payload without posting. Pick the tag in this order:
1. `rule:<id>` when the finding is a violation of review-standards.mdc or typescript-standards.mdc: the `id` of its `<rule>`, `<standard>` or `<pattern>` element. A workflow finding that turns out to be a standards violation takes the rule, not its lens.
2. `lens:<name>` for a workflow finding that cites no rule: the finding's `lens` from 4a. Correctness lenses are `line-by-line`, `removed-behavior`, `cross-file`, `language-pitfall`, `wrapper-proxy` and `gap-sweep`; cleanup lenses are `reuse`, `simplification`, `efficiency`, `altitude` and `conventions`.
3. `general` for everything else: parent-review general code review findings, and a workflow finding with no `lens`.
A finding both passes raised takes the more specific tag. Never write the marker into a body yourself. `submit` and `render` refuse a comment whose tag is missing, malformed, or names an unknown rule id or lens. Replies and the review body carry no tag.</rule>
<rule id="independent-parent-review">The parent review (step 4b) runs WHILE the workflow runs and is finished before you read the workflow's result. Reading the workflow's candidates first anchors your pass on them and forfeits the independent second look that is the reason the pass exists.</rule>
<rule id="batch-reads">When reviewing changed files, batch independent Read/Grep calls in a single message.</rule>
<rule id="script-timeouts">The companion script may take up to 30s. Set `block_until_ms: 60000` when invoking it.</rule>
<rule id="diagram-escalation">Comments stay concise per the formatting sub-step. EXCEPTION: when a finding explains ordering, a race, or state-machine behavior — anything where the reader would otherwise simulate event interleavings — carry the mechanism in ONE ```mermaid block inside the comment (GitHub renders mermaid natively) and keep the surrounding prose concise. Sequence diagram for cross-component ordering, flowchart for gates. Participant IDs must not be mermaid keywords; tdd's `diagrams-and-signatures` rule owns the pitfall list. Never more than one diagram per comment; a finding that does not involve ordering stays prose-only.</rule>
</rules>

<flags description="All optional.">
- `--quick` — skip the deep workflow; parent review only (step 4b).
- `--level <low|medium|high|xhigh|max>` — depth of the deep workflow (default `high`). The level IS the fan-out agents' reasoning effort; see the model note in step 4a.
- `angles=N` — override the workflow's correctness-angle count (1-5) independently of level; passed through verbatim.
- `model=sonnet|opus|haiku|inherit` — the workflow's fan-out model (default `sonnet`); passed through verbatim.
- `effort=low|medium|high|xhigh|max|inherit` — the workflow's fan-out reasoning effort (default: the level's own); passed through verbatim.
- Convention: dashed flags (`--quick`, `--level`, `--comment`) are this skill's; `key=value` tokens are the workflow's and reach it unchanged in step 4a's `args`.
- `--comment` / `--no-comment` — posting config per `posting-gate`.
</flags>

<step id="1" name="Gather PR context">
Run the companion script to fetch PR metadata, changed files with patches, and existing reviews:

```bash
~/.cursor/skills/pr-review/scripts/github-pr-review.sh context [--pr <number>] [--owner <owner>] [--repo <repo>]
```

If the user provides a PR URL or number, pass `--pr`. If they also specify a repo, pass `--owner` and `--repo`. If nothing is provided, the script auto-detects from the current branch.

If the script exits code 2 with `PROMPT_GH_AUTH`, prompt: "`gh` CLI is not authenticated. Run `gh auth login` first."

Save the output JSON — it contains `number`, `title`, `url`, `author`, `me`, `headRef`, `baseRef`, `headSha`, `reviews[]` (with `commit`), `threads[]` (node `id`, `isResolved`, `isOutdated`, root author and review), `myStanding`, `myPendingReview`, `inlineComments[]`, and `files[]` (with patches). `author == me` means our own PR, which decides the `review-event-mapping` rule.
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
Workflow({ name: "code-review-sonnet", args: "<level> [angles=N] [model=X] [effort=X] <pr-url>" })
```

It runs in the background. Do NOT wait on it yet: go straight to 4b, and read its result (TaskOutput, blocking) only once 4b's findings are written down, per `independent-parent-review`. Its result carries `findings[]` (each with file/line/summary/failure_scenario/category/verdict/lens, where `lens` names the finder lens that raised it, per `finding-tags`) and `refuted[]`.

Model allocation, for cost awareness: the workflow's Scope and Synthesize agents inherit the session model; its Find/Verify/Sweep fan-out defaults to Sonnet running at the level's effort (level IS effort, mirroring the official /code-review). Depth, model, and effort are separate dials: pass `model=sonnet|opus|haiku|inherit` and/or `effort=low|medium|high|xhigh|max|inherit` alongside the level, where `inherit` on either drops that key so the fan-out takes the session's own value. Everything else in this skill runs inline on the session model.
</sub-step>

<sub-step id="4b" name="Parent review (always, every level)">
Your own review of the diff, on the session model, independent of the workflow. Read each changed file's patch and the full file for context (batch reads), then review through these lenses:
- **General code review**: anything a strong reviewer would catch. Correctness on paths the diff touches, whether the change does what the PR title/body (and linked task) say, design and altitude (a special case bolted onto shared code, logic at the wrong layer), cross-cutting effects that span files, and missing handling for realistic states (error path, empty/cold state, concurrent calls).
- **Edge conventions**: violations of review-standards.mdc and typescript-standards.mdc; efficient memoization where necessary (memo, useHandler, useCallback); unnecessary code, unnecessary JSX fragments, missed simplifications.

Record each finding with file, line, summary, a concrete `failure_scenario`, and its tag (`rule:<id>` for an Edge-conventions finding, `general` otherwise, per `finding-tags`) before moving to 4c. Overlap with the workflow is expected and resolved in curation, so do not narrow this pass to avoid it.

This sub-step is the extension point for Edge-specific review machinery (for example a catalog of known review dimensions fanned out to cheaper checkers): add such lenses here, feeding the same findings shape.
</sub-step>

<sub-step id="4c" name="Curate">
Merge 4a + 4b into one findings set (a finding both passes raised counts once, and independent agreement raises confidence in it), then per `curation-owns-truth` and `no-duplicate-feedback`:
1. Drop duplicates of feedback already on the PR (`reviews[]`, `inlineComments[]`).
2. Reject false positives with cited evidence; keep the rejection list for the summary and for the curation-record block wherever `self-review-rejections` puts it.
3. Categorize survivors: **Critical** (must fix before merge), **Warning** (should address), **Suggestion** (consider).
4. Give each survivor its final tag per `finding-tags`.
</sub-step>
</step>

<step id="5" name="Format draft comments">
<sub-step name="Comment formatting">
- Single line: use only `line`; multi-line range: `start_line` (first) + `line` (last); `side`: `"RIGHT"` for additions
- Every anchor (`line`, and `start_line` when set) must sit inside a diff hunk: an added or context line on `RIGHT`, a removed or context line on `LEFT`. For a finding about unchanged code, anchor on the nearest hunk line and cite the real line in the text. `submit` refuses an out-of-diff anchor and names the nearest valid line, since GitHub would otherwise reject the whole review with a 422
- Keep comments concise, use backtick formatting for code, bold, or italics
- Ordering/race findings: one mermaid block carries the mechanism (`diagram-escalation`)
- Convention nits cite the published ruleset (the edge-dev-agents copy), never `~/.cursor/...` paths
- 1 inline comment: leave `body` empty (`""`); 2+ inline comments: only add `body` if it provides necessary linking context. The curation-record block below is the exception and goes in `body` wherever `self-review-rejections` puts it
</sub-step>
<sub-step name="Curation record">
Appended to `body` per `self-review-rejections`. One line per finding, `path:line` as of the reviewed head:

```markdown
<details><summary>Rejected in curation (2)</summary>

- `src/foo.ts:42`: <the finding's claim>. Rejected: <the evidence>.
- `src/bar.ts:7`: <claim>. Rejected: <evidence>.
</details>
```

A caller that also fixed findings before posting (one-shot's self-review) adds a `Fixed before review (N)` block in the same shape, each line ending with where the fix went instead of `Rejected:`.
</sub-step>
</step>

<step id="6" name="Deliver">
Resolve the posting decision per `posting-gate`:

1. `--no-comment` (or orch default) → do not submit. Build the same Review JSON a submit would send and print it through `render`, which shows every draft comment ending in its tag marker; that output goes to chat / the run report. Done, go to step 7.
   ```bash
   echo '<review-json>' | ~/.cursor/skills/pr-review/scripts/github-pr-review.sh render
   ```
2. Default interactive → show the drafts (grouped per PR file/line, with category), ask for approval, then submit the approved subset.
3. `--comment` → submit directly.

Submit via the companion script with the event per the event-mapping rule (`review-event-mapping`): on a PR we do not author, `REQUEST_CHANGES` when something must change before merge and `APPROVE` when only nits or nothing remain; on our own PR, `COMMENT`:

```bash
echo '<review-json>' | ~/.cursor/skills/pr-review/scripts/github-pr-review.sh submit \
  --pr <number> --owner <owner> --repo <repo> --sha <headSha>
```

Review JSON format:
```json
{
  "event": "COMMENT",
  "body": "",
  "comments": [
    { "path": "src/file.ts", "line": 42, "side": "RIGHT", "body": "Comment text", "tag": "rule:<id>" }
  ],
  "replies": [
    { "thread_id": "<threads[].id>", "body": "Fixed at `abc1234`.", "resolve": true }
  ]
}
```

`replies` answer existing threads inside the same review; omit the key when there are none.

0 findings after curation:
1. On a PR we do not author → submit `APPROVE`. Its body is the coverage line, then the curation-record block when curation rejected anything:
   ```markdown
   Reviewed at `<short-sha>` (<level or quick>): nothing blocking.
   ```
   Pass the confirmed-fix `replies` (`review-event-mapping`) in the same payload. `submit` refuses a review with no body, comments, or replies, so this body is never left empty.
2. On our own PR → the rejected-only `COMMENT` under `self-review-rejections`, or nothing.

Drafts that wait for approval, or go into a run report for later posting, are pre-checked with the same payload plus `submit --check-only`: it runs every submit check (structure, tags, anchors, prose lint) and posts nothing, so the approved draft is the one that posts.
</step>

<step id="7" name="Summarize">
Provide a summary in the chat response:
- Number of files reviewed, depth used (level or quick)
- Findings by category (critical, warning, suggestion), plus the rejected-false-positive list with one-line reasons (say whether they were posted in the review body)
- What was posted (link to the submitted review) or that drafts await approval / posting was off
- PR link as `[PR title](url)`
</step>

<edge-cases>
<case name="No PR found">Script exits with an error. Ask the user for a PR number or URL.</case>
<case name="No changed files">Report that the PR has no file changes.</case>
<case name="Large PR (>20 files)">The deep workflow scopes itself; for the parent review, prioritize files with the most additions and note any files skipped due to size (lockfile churn is always skippable).</case>
<case name="Server repo">If the repository name ends in `-server` or context indicates a server project, also review against the Server Conventions section in review-standards.mdc.</case>
<case name="Workflow unavailable or fails">If the Workflow tool is unavailable or the run errors, report it and continue with the parent review alone and say in the summary that depth was degraded. Do not silently claim deep coverage.</case>
<case name="Your pending draft on the PR" id="pending-draft-adopted">`myPendingReview` set means the operator left an unsubmitted draft. Do not copy its comments into the payload and do not delete it: `submit` takes it over, publishing it with this review (or ahead of it when it is pinned to an older commit), and prints the draft action, which `--check-only` also shows. Dedupe findings against the draft's comments, and name the draft action in the summary and run report.</case>
<case name="Multiple PRs named">Run steps 1-4 per PR (workflows may run in parallel); curate and deliver per PR. One approval ask covers all drafts.</case>
</edge-cases>

<reference>
The path diagram (also synced to edge-dev-agents): `~/.cursor/skills/pr-review/review-path.md`.
Review-comment mining (not part of the review path): `scripts/mine-review-comments.py` exports every review thread on an org's PRs merged in a date window as JSONL (one row per thread, root plus replies, each comment tagged human, operator or bot) with a counts summary, for rule-gap and acceptance-rate analysis. Read-only GraphQL through `gh`; per-PR responses cache under `<out>/cache/`. Author logins come from `~/.config/pr-review/mining/accounts.json` (machine-local, never synced); `scripts/mining-accounts.example.json` is the template. Defaults: EdgeApp, 2025-10-23 to 2026-10-23, output `~/.config/pr-review/mining/`.
Replay comparator (not part of the review path): `scripts/replay-compare.js --findings <file|dir>` scores replayed findings against the human comments in that export (inline threads, review-summary points, conversation comments) with a Sonnet judge through `claude -p`, and writes recall, precision, signal-to-noise and per-tag counts per PR and per label to `~/.config/pr-review/replay-compare/runs/<ts>/`. No GitHub calls; held-out PRs (number mod 3 == 2) need `--allow-held-out`. Usage and input shapes are in the script header.
</reference>
