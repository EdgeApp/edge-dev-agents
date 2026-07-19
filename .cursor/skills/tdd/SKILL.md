---
name: tdd
description: Write or update a technical design document (TDD) from the current session's investigation and publish it as a living gist with pinned-revision snapshots. Use when the user asks for a TDD, design doc, "write up the design", a design-doc iteration, or a post-implementation retrospective on an existing TDD.
compatibility: Requires jq, node, and gh (authenticated). Publishes public gists.
metadata:
  author: j0ntz
---

<goal>Turn a session's investigation into a decision-complete, convention-checked TDD published as a living gist.</goal>

<rules description="Non-negotiable constraints.">
<rule id="investigate-dont-defer">A published TDD contains no TBDs, open questions, or "decide later" items. Every unknown is either resolved NOW by investigation (read the code, run commands, spawn Explore agents, check PR diffs) or explicitly scoped out as a non-goal / deferred phase with a stated reason. `tdd-lint.sh` blocks placeholder markers; the deeper obligation is on you: an unverified claim gets verified before it is written down, not hedged.</rule>
<rule id="decisions-with-alternatives">Every contested choice gets its own entry in the Decisions section: what was chosen, the investigation evidence behind it, each rejected alternative with the specific reason it lost, and the trigger that would reopen it. A decision without alternatives is a description, not a decision.</rule>
<rule id="status-lifecycle">The metadata table carries a Status that moves through: Draft, In review, Implemented (qualifiers allowed), Superseded by [link]. TDDs are never deleted; a replaced doc gets one final revision flipping Status to Superseded with a pointer to its successor.</rule>
<rule id="repo-separation">When the design spans repos, each repo gets its own detailed-design section (heading names the repo) and the Design overview carries a repo table: repo, deliverable (PR link once it exists), scope pointer. Never interleave two repos' changes in one section.</rule>
<rule id="clickable-everything">The doc has a `## Contents` ToC and every in-body reference to a section, decision, or test case is a markdown anchor link, GFM slugs (lowercase, punctuation stripped, spaces to hyphens). `tdd-lint.sh` verifies ToC resolution and flags unlinked "section N"/"decision N" text.</rule>
<rule id="diagrams-and-signatures">Add a mermaid diagram wherever prose alone forces the reader to simulate ordering or interaction: sequence diagrams for cross-component call flows, flowcharts for load order and gates. Add function/interface/schema definitions at contract seams (new files, new actions, waiter helpers). Once implementation exists, every code block must match the shipped code (pull it from the PR diff) and be marked "as landed"; a TDD that quotes code the PRs do not contain is wrong.</rule>
<rule id="snapshot-and-live">Publish with `gist-doc-publish.sh`. Whenever the doc is referenced from a task, PR, or message, cite BOTH the pinned revision URL (immutable snapshot at that moment) and the live URL. This is the same convention `/asana-task-create` `notes-file` requires.</rule>
<rule id="post-impl-retro">After implementation lands, append a `## Post-implementation retrospective` section with four subsections: Estimate vs. actuals (table), Where this document was wrong or silent (numbered, each anchored to the section it corrects), What held, Verification highlights (real measurements, links to PR evidence). Body sections that reality contradicted get a pointer to the retro item; never silently rewrite the design history. Exception: code blocks update to shipped code per `diagrams-and-signatures`, since they document the contract, not the prediction.</rule>
<rule id="length-discipline">Every section earns its place; prune rather than pad. State a rationale once and anchor-link to it elsewhere. If a section restates another section, delete it.</rule>
<rule id="draft-gate">For a NEW TDD, present the section outline plus the Decisions list in chat and get the user's go-ahead before first publish. Updates to an existing TDD publish directly and report the new revision. Before updating a gist this session did not write, fetch the live content first; never clobber revisions you have not read.</rule>
<rule id="style">Plain markdown, sentence-case headings, zero em dashes, /no-slop. The lint checks em dashes; the rest is on you.</rule>
</rules>

<template description="Section skeleton for a new TDD. Keep headings numbered exactly like this; omit sections that genuinely do not apply, renumbering the rest.">
```markdown
# <Title>: <one-line outcome>

| | |
|---|---|
| Status | Draft |
| Author | <name> |
| Reviewer | <name or -> |
| Last updated | <YYYY-MM-DD> |
| Repos | <linked repo(s)> |
| Implementation | - (PR links once they exist) |
| Supersedes | <link or -> |
| Related | <links> |

<one paragraph: what file/branch references point at, where direction came from>

## Contents
<numbered list of anchor links, one per ## section>

## 1. Problem
## 2. Prior art (why existing approach X is not the answer)
## 3. Goals and non-goals
## 4. Design overview        <- repo table + overview diagram live here
## 5. Detailed design: <repo A>
## 6. Detailed design: <repo B>   <- one per additional repo
## 7. Testing                <- numbered cases; enumerable and checkable
## 8. Deferred work          <- phases and dispositions, each with a reason
## 9. Decisions              <- one ### per decision, per decisions-with-alternatives
## 10. References
## 11. Post-implementation retrospective   <- added later, per post-impl-retro
```
</template>

<step id="1" name="Assemble evidence">
Gather what the session already established (investigation results, call notes, review threads). List every gap a reader would hit, then close each one now per `investigate-dont-defer`: targeted file reads, shell commands, and parallel Explore agents in one message. If implementation PRs exist, pull their diffs for shipped symbol names and signatures.
</step>

<step id="2" name="Draft">
Write the doc to the scratchpad directory following `<template>`. Multi-repo: apply `repo-separation`. Add diagrams and definitions per `diagrams-and-signatures`. Build the ToC and anchor-link every internal reference as you write, not as a cleanup pass.
</step>

<step id="3" name="Lint">
```bash
~/.cursor/skills/tdd/scripts/tdd-lint.sh <draft.md>
```
Fix every FINDING and re-run until `LINT_OK`. Placeholder findings mean step 1 was incomplete; go investigate, do not reword.
</step>

<step id="4" name="Publish">
New doc: apply `draft-gate`, then:
```bash
~/.cursor/skills/tdd/scripts/gist-doc-publish.sh --file <draft.md> --desc "<one-line description>"
```
Existing doc: re-fetch live content first (per `draft-gate`), fold in your changes, then publish with `--gist <id>`. Report `GIST_URL` and `PINNED_URL` to the user; use `PINNED_URL` for any snapshot citation per `snapshot-and-live`.
</step>

<step id="5" name="Wire into tracking">
If the TDD leads to an implementation task, create it with `/asana-task-create` (its `notes-file` rule already carries the snapshot-and-live link convention). If this update was a post-implementation retrospective, confirm the Status row and Implementation row reflect the PRs.
</step>

<edge-cases>
<case name="No investigation to draw from">The session has conclusions but no evidence trail: do the investigation first (step 1 is mandatory, not optional). This skill documents verified findings; it does not launder guesses into a doc.</case>
<case name="Doc lives in a repo, not a gist">Same template and lint; skip `gist-doc-publish.sh` and commit the file where the user says (branch + PR per that repo's conventions). Pinned citations use commit-sha file URLs instead of gist revisions.</case>
<case name="Superseding an existing TDD">Publish the successor first, then push one final revision to the old doc flipping Status to "Superseded by [link]" per `status-lifecycle`.</case>
<case name="Reader-facing artifacts beyond markdown">If the user wants a rendered/interactive artifact, that is a separate deliverable; the gist markdown remains the source of truth.</case>
</edge-cases>
