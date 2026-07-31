---
name: agents-md
description: Write or revise an AGENTS.md agent-context file for a repo. Use when creating, editing, reviewing, or shortening an AGENTS.md (or an equivalent agent-instructions file), in any repo. A PreToolUse hook forces this skill before any AGENTS.md write.
compatibility: No dependencies. Guidance is cached in this file; never fetched at use time.
metadata:
  author: j0ntz
---

<goal>Produce an AGENTS.md that earns its per-session cost: short, deliberate, and about what the agent cannot cheaply discover on its own.</goal>

<rules description="Non-negotiable constraints.">

<rule id="size-budget">Keep the file under 300 lines, and treat anything over ~100 as needing justification. Every line enters EVERY session for that repo, so it is charged on every future task there. The measured baseline: an auto-generated context file performs ~3% WORSE than having no file at all while costing 20%+ more tokens, and a deliberate hand-written one gains only ~4%. A file only beats no file when it is short and non-obvious, so cut before you add.</rule>

<rule id="what-why-how">Cover exactly three things. WHAT: the stack and what the major components are for (highest value in a monorepo, where the apps/packages split is not obvious). WHY: the intent behind the project and its key pieces, so the agent can make judgment calls rather than only follow steps. HOW: the build, test, and verification commands, especially NON-OBVIOUS tooling (`uv` not `pip`, `bun` not `npm`, a runner needing a specific invocation). Naming a tool here is the single highest-leverage line in the file: named tools get used ~160x more often than unmentioned ones.</rule>

<rule id="exclude-list">Do NOT include: directory listings or codebase overviews (agents locate files fine, and the listing is stale on the next move); code-style rules (linters and formatters enforce style deterministically, and models follow surrounding code anyway); task-specific or non-universal instructions (a model reliably follows ~150-200 instructions and the harness already spends ~50, so anything that is not always-true crowds out something that is); auto-generated content (stale, unowned, measurably harmful); anything already stated in a doc this file could link to instead, since redundancy actively lowers performance.</rule>

<rule id="progressive-disclosure">Keep AGENTS.md an INDEX, not a manual. Push detail into separate files (`docs/…`) and list each with a one-line description of when to open it, so detail is pulled on demand instead of paid for every session.</rule>

<rule id="pointers-over-copies">Reference code by path (`src/util/foo.ts`, or `file:line`) instead of pasting snippets. Embedded code decays silently as the real code moves, and costs many times what the pointer costs.</rule>

<rule id="write-it-deliberately">Write the file yourself, line by line. Never generate it from a directory walk or a template fill. It is infrastructure: a bad line does not fail loudly, it degrades every future session in that repo.</rule>

<rule id="cached-not-fetched">This guidance is a CACHE, distilled from <https://www.philschmid.de/writing-good-agents>. Do not fetch that URL to apply the skill; the principles are stable and the hook that forces this skill must not depend on the network. Re-distill into this file only when the source materially changes.</rule>

</rules>

<step id="1" name="Read what exists">
If the repo already has an AGENTS.md, read it in full first. Also list the repo's existing docs (`ls docs/ README.md CONTRIBUTING.md` and any `.cursor/` guidance) — anything already documented there is a LINK target, never content to restate per `exclude-list`.
</step>

<step id="2" name="Find the non-obvious facts">
Gather only what an agent could not cheaply discover: the exact verification command and what it runs, tooling that differs from the ecosystem default, the component split and its intent, and any convention that fails silently when violated. Read the package manifest and the CI config for the real commands rather than guessing them.
</step>

<step id="3" name="Draft">
Write the file against `what-why-how`, `exclude-list`, `progressive-disclosure`, and `pointers-over-copies`. Lead with one short paragraph on what the project is and why. Put commands in a compact table. Close with the index of linked docs. Prefer a sentence that changes a decision over a sentence that describes a fact.
</step>

<step id="4" name="Cut">
Re-read the draft and delete every line that fails this test: would an agent that never read this line do anything differently? Verify against the checklist before saving.
</step>

<checklist name="Before saving">
- [ ] Under 300 lines, and every remaining line justifies its per-session cost.
- [ ] WHAT / WHY / HOW covered, with exact commands and non-obvious tooling named.
- [ ] No directory listing, no style rules, no task-specific instructions, nothing auto-generated.
- [ ] Detail is linked, not inlined; code is referenced by path, not pasted.
- [ ] Nothing duplicates a doc it could link to instead.
</checklist>

<edge-cases>
<case name="Repo already has thorough docs">Make AGENTS.md a thin index over them (`progressive-disclosure`). Do not summarize their content into it — the redundancy costs performance.</case>
<case name="Monorepo">Spend the WHAT budget on the apps/packages/services split and each one's purpose; that is the case where structure is genuinely not discoverable. Consider a per-package AGENTS.md instead of one large root file.</case>
<case name="Asked to expand an AGENTS.md">Push back with `size-budget`: propose linking a new doc under `docs/` and adding one index line, rather than growing the always-loaded file.</case>
<case name="Existing file is bloated">Rewriting it shorter IS the fix, not an optional cleanup. Cut the excluded categories first; they are usually most of the file.</case>
</edge-cases>
