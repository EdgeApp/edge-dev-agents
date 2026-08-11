---
name: tdd
description: Write or update a technical design document (TDD) describing what was BUILT, published to a resolved output target (committed on the PR branch, public or secret gist, or a local file), with the body kept current and phase evolution confined to one history section. Use when the user asks for a TDD, design doc, "write up the design", a design-doc iteration, or a post-implementation retrospective on an existing TDD.
compatibility: Requires jq, node, and gh (authenticated). Publishes public or secret gists, or commits to a PR branch.
metadata:
  author: j0ntz
---

<goal>Turn a session's investigation into a decision-complete, convention-checked TDD published to the target `output-target` resolves.</goal>

<rules description="Non-negotiable constraints.">
<rule id="investigate-dont-defer">A published TDD contains no TBDs, open questions, or "decide later" items. Every unknown is either resolved NOW by investigation (read the code, run commands, spawn Explore agents, check PR diffs) or explicitly scoped out as a non-goal / deferred phase with a stated reason. `tdd-lint.sh` blocks placeholder markers; the deeper obligation is on you: an unverified claim gets verified before it is written down, not hedged.</rule>
<rule id="decisions-with-alternatives">Every contested choice gets its own entry in the Decisions section: what was chosen, the investigation evidence behind it, each rejected alternative with the specific reason it lost, and the trigger that would reopen it. A decision without alternatives is a description, not a decision.</rule>
<rule id="status-lifecycle">The metadata table carries a Status that moves through: Draft, In review, Implemented (qualifiers allowed), Superseded by [link]. TDDs are never deleted; a replaced doc gets one final revision flipping Status to Superseded with a pointer to its successor.</rule>
<rule id="repo-separation">When the design spans repos, each repo gets its own detailed-design section (heading names the repo) and the Design overview carries a repo table: repo, deliverable (PR link once it exists), scope pointer. Never interleave two repos' changes in one section; where the repos interact, each section anchor-links the other side of the seam and the cross-repo diagram (`diagrams-and-signatures`).</rule>
<rule id="clickable-everything">The doc has a `## Contents` ToC and every in-body reference to a section, decision, or test case is a markdown anchor link, GFM slugs (lowercase, punctuation stripped, spaces to hyphens). `tdd-lint.sh` verifies ToC resolution and flags unlinked "section N"/"decision N" text.</rule>
<rule id="glossary-for-jargon">The doc carries a `## Glossary` section (one `### Term` per entry, placed before References), and the FIRST use of each term in the body links to its anchor. Write for a reader who does not already know the jargon: an acronym or domain term left unexpanded is the doc failing that reader, and expanding it inline every time is the bloat the glossary exists to prevent. Each entry gives three things: the expansion, one or two plain sentences on what it is AND what it does in THIS design, and a source link for further reading. Prefer normative sources (RFC, the platform vendor's own documentation, W3C) over blog posts; a project-local term with no external source cites the code path that defines it instead. Cover what the design leans on: cryptographic constructions, platform APIs, protocol and wire terms, and any internal name a reader outside the immediate work would not recognize. Do NOT place the anchor links by hand: run `~/.cursor/skills/tdd/scripts/tdd-glossary-link.sh <file>`, which inserts them and is idempotent. It links the FIRST prose use of every term in EVERY top-level section, so a reader who jumps to section 5 from the ToC gets clickable jargon without scrolling back to wherever the term debuted, and `tdd-lint.sh` fails on any occurrence the script would have linked. Choosing which terms a reader needs, and writing the entry, stays yours; placement does not.</rule>
<rule id="diagrams-and-signatures">Add a mermaid diagram wherever prose alone forces the reader to simulate ordering or interaction: sequence diagrams for cross-component call flows, flowcharts for load order and gates. Multi-repo designs get at least one diagram illustrating the cross-repo communication, with participants grouped by repo (`box` blocks in sequence diagrams) so the boundary is visible; sections describing either side anchor-link that diagram. Name sequence participants with IDs that are not mermaid keywords (`Create`, `End`, `Note`, `Box`, `Link`, `Title`, and the rest `tdd-lint.sh` lists): an ID is lexed, so a keyword ID kills the whole diagram at the first message naming it, and the error points at that message rather than the declaration. The display label after `as` is free text, so `participant CreateScene as RampCreateScene` reads identically to the reader. Add function/interface/schema definitions at contract seams (new files, new actions, waiter helpers). Once implementation exists, every code block must match the code on the branch (pull it from the PR diff); a TDD that quotes code the PRs do not contain is wrong. Do NOT annotate blocks with "as landed" or any similar currency claim: prose cannot stay true as branches move, so the citation carries it instead. Every code block quoting a real file gets a caption line directly above it linking that path at a commit SHA, and a SHA is required because a branch URL 404s the moment the branch is deleted at merge. Do not write these captions by hand: run `~/.cursor/skills/tdd/scripts/tdd-codeblock-link.sh <file> --repo <checkout>` (one `--repo` per repo), which reads the leading `// path/to/file.ts` comment out of each fence, resolves it against that repo's tracked files, and rewrites it as a pinned caption. It is idempotent and re-pins a stale SHA on rerun, so a doc updated on a later turn cites the code it now quotes.</rule>
<rule id="outcomes-matrix">Add an outcomes matrix — rows are reachable configurations, columns are the observable surfaces the design owns — wherever shipped behavior is the PRODUCT of two or more independent inputs (a link parameter, a server config, a data shape, a user action) and each governing rule is simple but their interaction is not. The tells that one is owed, any of which suffices: someone (reviewer or author) mispredicted an outcome the prose already "covered"; the same "what happens when X while Y" question was re-derived more than once in review or chat; or a section finds itself explaining input interactions pairwise. Build it by enumerating REACHABLE configurations — collapse unreachable and equivalent combinations, never emit the full cartesian product — with one row per configuration a user or config author can actually produce, including the degenerate ones (nothing set, everything set, the input that matches nothing). The matrix is an index into the prose, not a second source of truth: each row follows from named sections/decisions, the intro cites them and states that prose wins on disagreement, and any edit to a cited rule updates the matrix in the same commit (a stale matrix misleads with more authority than stale prose). Place it directly after the last section whose rules feed it. The same judgment gates worked ASCII examples of single states (`diagrams-and-signatures` owns diagrams for ordering/interaction flows): illustrate where a reader would otherwise have to simulate, and nowhere else, per `length-discipline`.</rule>

<rule id="output-target">Where the doc lives is a resolved choice, not a default to assume. Four targets:

| Target | What it is | Publish with |
|---|---|---|
| `committed` | File on the PR branch at `src/docs/<slug>.md`, reviewed in the same diff | `lint-commit.sh`, then push |
| `secret-gist` | Unlisted gist, and the default for either gist target. NOT access-controlled: anyone with the link can read it, so it hides a doc from a profile, never protects a secret | `gist-doc-publish.sh` |
| `public-gist` | Listed gist, indexable. Only when the operator asks for it in as many words | `gist-doc-publish.sh --visibility public` |
| `local-file` | No publish at all; the doc stays at its path and only that path is reported | nothing |

Resolve in this order, first match wins:
1. ORCH-COMMISSIONED (`~/.cursor/skills/asana-field-value.sh <gid> "TDD?"` prints `tdd`): `committed`, always. The field IS the request for a doc that ships in `src/docs/` with the code, so it outranks every heuristic below, including the non-owner one. When the task's PR belongs to someone else, commit the doc to the task's own PR branch rather than theirs, and if the task has no branch of its own, open one for the doc; do not silently downgrade to a gist.
2. An explicit operator instruction ("make it a gist", "don't commit it", "keep it local", "keep it off my profile"). A live instruction outranks the heuristics, and when it contradicts a set TDD field, follow it and record the conflict as a decision.
3. The PR is NOT yours (`currentUser != prAuthor`): never commit to another author's branch, so a gist target.
4. A PR exists and you own it: `committed`, per `lives-in-the-pr`.
5. No PR yet: a gist, migrating into `src/docs/` when a PR opens (`lives-in-the-pr`).

A gist target resolves to `secret-gist` unless the operator asked for a public one; the script defaults the same way, so forgetting the flag cannot publish to a profile. State the resolved target and which rule above picked it when reporting the doc. A gist target keeps `snapshot-and-live`'s dual-URL citation; `local-file` cites the path and nothing else.</rule>
<rule id="lives-in-the-pr">When `output-target` resolves to `committed`, the TDD's HOME is a file committed on that PR's branch at `src/docs/<slug>.md` (create `src/docs/` if absent), shipping with the code it describes and reviewable in the same diff. Get every citation URL from `~/.cursor/skills/tdd/scripts/tdd-doc-links.sh <repo-dir>`, never hand-built: `TDD_BRANCH_URL` (follows the branch head) is the form for anything a reader opens later — the PR body, an Asana comment, a task; `TDD_PINNED_URL` (frozen at a commit) is for anything that must stay true to one moment, which today means the run report. When a PR opens on work whose doc is currently a gist, move it into `src/docs/` on that branch and push one final gist revision pointing at the committed file so old links resolve. Target selection lives in `output-target`. Multi-repo work puts the doc in the repo whose PR carries the primary deliverable, per `repo-separation`.</rule>
<rule id="snapshot-and-live">For a gist-hosted doc (either gist target in `output-target`), publish with `gist-doc-publish.sh` and cite BOTH the pinned revision URL (immutable snapshot at that moment) and the live URL whenever it is referenced from a task, PR, or message. This is the same convention `/asana-task-create` `notes-file` requires.</rule>
<rule id="write-after-building">A TDD is written from what was BUILT, not from what is planned. Normally: develop for at least one turn first, then write the initial doc; update it on every subsequent turn. A pre-implementation design sketch is not a TDD — it goes in the plan or the task, and the doc that would have been written from it is written after the code exists and the unknowns are resolved (which is what `investigate-dont-defer` demands anyway).</rule>
<rule id="current-state-body-phases-in-one-section">The BODY always describes the CURRENT implementation as if written fresh today: no "we first tried X, then Y", no per-phase narration threaded through the design sections. Evolution across phases and followups belongs in ONE dedicated section (`## Phase history`, placed after the design/testing sections and before Decisions): one subsection per phase: the design content as sketched, what actually shipped, and how the mechanism diverged. SUBSTANCE ONLY — no commissioning narration ("Queued <date> after the operator asked...", who requested it, which comment triggered it); provenance lives in the task's comment history, not the doc. Prefer structure over run-on prose: a diverged-in/shipped-as table or per-item bullets beats a paragraph. On every followup turn, UPDATE the body to match the new reality and APPEND that phase's entry to the history section. A body that reads as a changelog is the failure this prevents.</rule>
<rule id="post-impl-retro">After implementation lands, append a `## Post-implementation retrospective` section with four subsections: Estimate vs. actuals (table), Where this document was wrong or silent (numbered, each anchored to the section it corrects), What held, Verification highlights (real measurements, links to PR evidence). Body sections that reality contradicted get a pointer to the retro item; never silently rewrite the design history. Exception: code blocks update to shipped code per `diagrams-and-signatures`, since they document the contract, not the prediction.</rule>
<rule id="length-discipline">Every section earns its place; prune rather than pad. State a rationale once and anchor-link to it elsewhere. If a section restates another section, delete it.</rule>
<rule id="draft-gate">For a NEW TDD, present the section outline plus the Decisions list in chat and get the user's go-ahead before first publish. Updates to an existing TDD publish directly and report the new revision. Before updating a doc this session did not write, fetch the live content first (`git pull` for a committed doc, gist fetch otherwise); never clobber revisions you have not read.</rule>
<rule id="style">Plain markdown, sentence-case headings, /no-slop. IMMEDIATELY before writing or updating the doc — every session, including followup updates — Read `~/.cursor/skills/no-slop/SKILL.md` in full: a remembered summary drops the banned-vocabulary list and the counted-padding shapes ("Two defects compound: ...", "Three changes, shipped in ..."), which are banned ANYWHERE in prose, not only as line openers. The lint mechanically enforces em dashes, banned vocabulary, and the count-announcement shapes it can reach; the judgment-only patterns (promotional tone, self-grading, courtesy enders, counted padding the regex tier misses) remain yours.</rule>
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
## 8. Phase history          <- the ONLY place evolution lives: one ### per phase
                            <- (sketch, shipped, divergence — substance only, no
                            <- commissioning narration), plus deferred work with
                            <- its disposition and reason. Bullets/tables over
                            <- prose. Everything above reads as current reality.
## 9. Decisions              <- one ### per decision, per decisions-with-alternatives
## 10. Glossary             <- one ### per term: expansion, what it does HERE,
                            <- and a source link (glossary-for-jargon)
## 11. References
## 12. Post-implementation retrospective   <- added later, per post-impl-retro
```
</template>

<step id="1" name="Assemble evidence">
Gather what the session already established (investigation results, call notes, review threads). List every gap a reader would hit, then close each one now per `investigate-dont-defer`: targeted file reads, shell commands, and parallel Explore agents in one message. If implementation PRs exist, pull their diffs for shipped symbol names and signatures.
</step>

<step id="2" name="Draft">
First action: the no-slop re-read per `style`. Then write the doc to the scratchpad directory following `<template>`. Multi-repo: apply `repo-separation`. Add diagrams and definitions per `diagrams-and-signatures`. Build the ToC and anchor-link every internal reference as you write, not as a cleanup pass.
</step>

<step id="3" name="Lint">
```bash
~/.cursor/skills/tdd/scripts/tdd-glossary-link.sh <draft.md>   # inserts glossary links
~/.cursor/skills/tdd/scripts/tdd-codeblock-link.sh <draft.md> --repo <checkout> [--repo <checkout>]
~/.cursor/skills/tdd/scripts/tdd-lint.sh <draft.md>
```
Run both linkers FIRST: they compute glossary link placement and code-block captions, and the lint fails on anything they would have inserted. Pass one `--repo` per repo the doc quotes, pointing at the checkout whose branch tip the doc should cite (`diagrams-and-signatures`). Fix every FINDING and re-run until `LINT_OK`. `WARN` lines do not block, but read each one: a warned acronym with no glossary entry is usually a real omission (`glossary-for-jargon`). Placeholder findings mean step 1 was incomplete; go investigate, do not reword.
</step>

<step id="4" name="Publish">
Resolve the target per `output-target` first, then take that branch.

**`committed`:** write the doc to `src/docs/<slug>.md` in the PR's worktree (`mkdir -p src/docs`), commit it with the run's normal commit path (`~/.cursor/skills/lint-commit.sh`), and push to the PR branch. Cite the blob URL on that branch. Then link the doc from EVERY PR of the task, as the body's FIRST section so the reviewer sees the design before the description (`gh pr edit <num> --body-file` in place, existing template preserved below it):

```markdown
### Technical Design Document

[<doc filename>](<TDD_BRANCH_URL>)
```

The link label is the doc FILENAME (`ramps-deeplink-provider-priority.md`), never the H1 title. On a multi-repo task the companion repos' PRs carry the same section, since the one doc documents their changes. Orchestrated runs self-heal any missed link at the Complete gate (`~/.config/agent-watcher/hooks/ensure-tdd-pr-link.sh`); do not rely on that outside orchestration. On later turns, edit that same file in place — body updated to current reality, phase entry appended (`current-state-body-phases-in-one-section`) — and amend/commit per the run's commit discipline.

**`secret-gist` / `public-gist`:** apply `draft-gate` for a new doc, then:
```bash
~/.cursor/skills/tdd/scripts/gist-doc-publish.sh --file <draft.md> --desc "<one-line description>"
```
That publishes a secret gist. Add `--visibility public` only when the operator asked for a public one.
Existing doc: re-fetch live content first (per `draft-gate`), fold in your changes, then publish with `--gist <id>` (visibility is fixed at creation). Report `GIST_URL` and `PINNED_URL`; cite `PINNED_URL` for snapshots per `snapshot-and-live`. In an orchestrated run the script also records the pointer that makes the doc resolvable to the run report and the PR-body hook, so no extra step is needed.

**`local-file`:** publish nothing. Report the absolute path, and say plainly that the doc is unpublished so nobody cites a link that does not exist.
</step>

<step id="5" name="Wire into tracking">
If the TDD leads to an implementation task, create it with `/asana-task-create` (its `notes-file` rule already carries the snapshot-and-live link convention). If this update was a post-implementation retrospective, confirm the Status row and Implementation row reflect the PRs.
</step>

<edge-cases>
<case name="No investigation to draw from">The session has conclusions but no evidence trail: do the investigation first (step 1 is mandatory, not optional). This skill documents verified findings; it does not launder guesses into a doc.</case>
<case name="Doc placed outside src/docs">`lives-in-the-pr` is the default; when the user names a different path (a repo with an established docs location), commit there instead. Same template and lint either way; pinned citations use commit-sha file URLs instead of gist revisions.</case>
<case name="TDD flagged on already-shipped work">A `TDD?` flip after the code landed is commissioned documentation, not a design gate: write the whole doc from the implemented state in one pass (body = current reality, `## Phase history` reconstructing the phases from the run reports and PR history), commit it to the PR branch if the PR is still open, else gist it.</case>
<case name="Superseding an existing TDD">Publish the successor first, then push one final revision to the old doc flipping Status to "Superseded by [link]" per `status-lifecycle`.</case>
<case name="Reader-facing artifacts beyond markdown">If the user wants a rendered/interactive artifact, that is a separate deliverable; the gist markdown remains the source of truth.</case>
</edge-cases>
