---
name: author
description: Create, edit, revise, or debug Cursor skills (~/.cursor/skills/*/SKILL.md). Use when the user wants to make a new skill, update an existing skill, fix a skill, or asks about .cursor/skills/ files. Also use when the user says "new command", "create command", "create skill", "edit command", "new skill", "update skill", "update command", or references SKILL.md. NOT for general markdown editing (READMEs, CHANGELOGs, docs, AGENTS.md).
---

<goal>Write or revise Cursor commands and skills with maximum agent compliance.</goal>

<commands-vs-skills>
Skills (`~/.cursor/skills/*/SKILL.md`): The standard unit. Can be invoked explicitly via `/skill-name` or agent-triggered based on task matching against the description. Companion scripts live in `<skill>/scripts/`. Shared scripts live at `~/.cursor/skills/` top-level.
</commands-vs-skills>

<authoring-principles>

<group name="Voice and shape" purpose="How a rule reads, and where it sits.">

<principle id="prescriptive">Be prescriptive, not descriptive. Commands tell the agent what to DO, not what things ARE.</principle>

<principle id="rules-first">Hard rules at the top. Non-negotiable constraints go right after the Goal so they're read before any steps.</principle>

<principle id="ordering">Order of operations matters. The agent reads top-to-bottom: context-setting steps before action steps.</principle>

<principle id="escape-hatches">Escape hatches over assumptions. When ambiguity exists, tell the agent to ask — don't let it guess.</principle>

<principle id="brief-examples">Examples are brief and hypothetical, 3-5 lines max. Never real data from conversations.</principle>

</group>

<group name="Keep it lean" purpose="Every line an agent must read costs context and dilutes the rest. These are the anti-bloat rules.">

<principle id="no-prose-for-mechanical">If a hook or script ALREADY makes the behavior deterministic, write NO agent-facing prose for it.
A rule exists to change what an agent decides. When the outcome cannot vary — a PreToolUse hook rewrites the payload, a script wraps the text, a gate blocks the call — there is no decision left to instruct, so the rule is pure bloat and one more thing to drift out of date.
- Explanation goes in the HOOK or SCRIPT header, where whoever changes the mechanism will read it.
- Rewriting (idempotent, `updatedInput`) beats blocking beats prose. Prefer the mechanism the agent cannot even notice.
- `rubric-drift.sh --ack <skill>:<rule> --reason "mechanically enforced by <path>"` when a rule is deliberately mechanism-only.
- Prose IS still needed when the agent must supply judgment the mechanism can't: which flag to pass, when the step applies, what a non-obvious verdict means.
Test: "if the agent read nothing about this, would the outcome differ?" No → no prose.</principle>

<principle id="no-incident-narration">Rules carry the imperative, never the incident that motivated it. No audit statistics, no dated incident tags ("the FooProvider run, 2031-01-05"), no history of how a behavior used to work. The evidence trail lives in eval reports and git history; a rule that narrates its origin grows on every incident and buries its own imperative. When patching a rule after an incident, write the counter-imperative the incident taught — not the incident.</principle>

<principle id="rationale-once">A rationale is stated ONCE, in the rule that owns it; dependent rules cross-reference the id without restating the why. Restated rationale is the main way related rules balloon in lockstep.</principle>

<principle id="dry">DRY across commands. If two commands share logic, extract it into a shared file and have both reference it.</principle>

<principle id="no-duplicate-automation">Don't restate in prose what a companion script already automates. Reference the script instead — duplication risks the agent running a step twice or fighting the script's output.</principle>

<principle id="minimize-context">Scripts return structured, filtered summaries — never raw API responses or whole files. Extract the fields the command needs and discard the rest; instruct targeted reads (grep, line ranges) over full reads for large files. Every token of script output costs context.</principle>

</group>

<group name="Determinism" purpose="Push work out of the agent's reasoning and into code, which cannot forget.">

<principle id="scripts-over-reasoning">Offload all deterministic logic to companion scripts. A known, repeatable sequence (API calls, git commands, file parsing, linting, data fetching) belongs in a `.sh` script — not inline in the `.md` as shell blocks the agent must reason about. The `.md` handles semantic decisions, user interaction, and interpreting script output.</principle>

<principle id="enforcement-over-prose">Prose documents; hooks enforce. When a rule constrains in-the-moment tool behavior (a "never do X mid-flow": raw commits, coordinate taps, PR creation without test evidence), do not stop at prose — under mid-flow momentum agents violate rules they have read. Pair the rule with a PreToolUse hook whenever the violation is mechanically detectable from tool inputs (command string, file path/content, tool name). Hook conventions:
- Scripts live in `~/.config/agent-watcher/hooks/` (existing ones are the exemplars); no-op unless `AGENT_TASK_GID` is set.
- Block via exit 2, with stderr naming the violated rule id AND the compliant path.
- Give an auditable escape hatch (`/tmp/agent-<concern>-<gid>.md`, audited by /eval-run — an unjustified note is a finding).
- Pipe-test EVERY vector with synthetic stdin payloads before wiring.
- Register in `~/.claude/settings.json` under matcher group(s) covering ALL vectors that can express the action (a Bash heredoc can author what Write/Edit can — cover both).
Rules governing judgment, sequencing, or report content stay prose-only; hooks are for mechanically checkable actions. Once a hook fully determines the outcome, drop the prose per `no-prose-for-mechanical`.</principle>

<principle id="batch-tool-calls">Minimize round-trips. When a step needs several independent facts (git status + log + diff), instruct parallel tool calls in ONE message — sequence only when one call depends on another's output.</principle>

</group>

<group name="Script craft" purpose="Conventions for the companion scripts the principles above keep sending work to.">

<principle id="gh-cli-over-curl">For GitHub API work use `gh api` / `gh api graphql`, never raw `curl` + `$GITHUB_TOKEN` — `gh` handles auth, pagination (`--paginate`), and versioning. Prefer GraphQL to fetch only the needed fields in one request; fall back to REST when GraphQL lacks the data (e.g. file patches).</principle>

<principle id="node-over-python">Need more than bash (JSON manipulation, complex regex, structured data, async I/O)? Embed Node inline via `exec node -e '...'` rather than adding a Python dependency — Node is already required. Avoid single quotes inside the inline code (bash string boundary); use `\x27` to match a literal quote in regex.</principle>

<principle id="mechanism-over-adverbs">In specs, contracts, and gate/report claims, name the mechanism and the audience — "exits 1 with the error on stderr", "blocked by the gate", "surfaced in the report's Remaining section" — never intensity adverbs ("fails loudly", "surfaces prominently"). Litmus: delete the adverb; if the sentence says the same thing, it was filler; if it stops distinguishing crash-and-report from continue-silently, replace it with the actual mechanism. Loud/loudly is acceptable only in a narrative comment that states the silent alternative in the same sentence (enforced mechanically by no-slop-lint.sh at every artifact boundary).</principle>
<principle id="owning-rules-before-shared-script-edits">Before editing a shared companion script, re-read the OWNING skill's rules for that script's domain (ordering contracts, auth/relay contracts, exit-code semantics) — the rationale for the current shape usually lives there, and an edit made from local reasoning can invert a deliberately-resolved design. The tell that this applies: the script lives under another skill's `scripts/` dir, or a rule elsewhere cites it by name. When the invariant you almost broke is not written down where you looked for it, add it as a rule to the skill that owns it in the same change.</principle>

<principle id="name-tracks-scope">A skill's or script's NAME must keep describing what it actually does. Names drift as responsibilities accrete — a thing named for one purpose quietly grows three. When an edit broadens, narrows, or shifts scope, treat the name as part of the diff: if it no longer fits, the rename belongs in THIS change. Never rename silently (renames ripple through callers, launchd jobs, docs) — propose the clearer name and get confirmation. Operationalized in `<revision-checklist>`; see also `<companion-scripts>`.</principle>

</group>

</authoring-principles>

<formatting>
Use XML tags to structure commands and skills. XML outperforms markdown for LLM instruction-following:

- Anthropic, OpenAI, and Google all recommend XML tags for structuring prompts.
- Claude is specifically tuned to attend to XML tag boundaries.
- Empirical tests show up to 40% performance variance based on prompt format alone, with XML consistently outperforming markdown.

Source: https://docs.claude.com/en/docs/use-xml-tags

<rules>
- Use semantic tag names that describe their content (e.g., `<rules>`, `<step>`, `<edge-cases>`).
- Use attributes for metadata: `id`, `name`, `description`.
- Nest tags for hierarchy: `<step><sub-step>...</sub-step></step>`.
- Be consistent — use the same tag names throughout a command.
- Markdown is still fine for inline formatting within XML tags (bold, code, lists).
</rules>

<template>
```xml
<goal>One sentence. What does this command accomplish?</goal>

<rules description="Non-negotiable constraints.">
<rule id="constraint-1">...</rule>
<rule id="constraint-2">...</rule>
</rules>

<step id="1" name="Step name">
Instructions for this step.
</step>

<step id="2" name="Step name">
Instructions for this step.
</step>

<edge-cases>
<case name="Case name">How to handle it.</case>
</edge-cases>
```
</template>
</formatting>

<small-model-conventions description="Apply these when the command will run on smaller/faster models (e.g., the user says 'for smaller models', 'optimize for lite/fast', or the command is high-frequency and must be cheap). These patterns compensate for weaker instruction-following and shorter reasoning chains.">

<convention id="verbatim-bash">Give exact shell commands to copy-paste, not descriptions of what to run. Smaller models copy verbatim; they struggle to construct commands from prose. Include placeholders like `<upstream-ref>` only where the agent must substitute a value.</convention>

<convention id="file-over-args">Pass multi-line content (PR bodies, commit messages, JSON payloads) via temp files, not shell arguments. Write content using the Write tool, then pass `--body-file /tmp/foo.md` to the script. This avoids shell escaping failures that smaller models cannot debug.</convention>

<convention id="exact-output-templates">When the command produces formatted output (markdown, JSON, reports), show the exact template line-by-line with placeholders. Include blank lines and heading levels explicitly. Example: show `## Accomplishments {day_label}` not "add a heading for accomplishments."</convention>

<convention id="explicit-parallel">Spell out parallel tool calls: "Run both scripts **in parallel** (two Shell tool calls in one message)." Smaller models default to sequential unless explicitly told otherwise.</convention>

<convention id="priority-ordered-decisions">When the agent must categorize or choose between options, use a numbered priority list — not prose. Example: "1. If X → do A. 2. If Y → do B. 3. Otherwise → do C." Smaller models follow numbered sequences reliably; they lose track of nested if/else prose.</convention>

<convention id="inline-guardrails">Duplicate critical rules from cross-referenced files as top-level `<rule>` tags. Smaller models skip "Read file X now" instructions despite explicit language. One-liner guardrails (e.g., `commit-script`, `changelog-required`) catch the failure mode where the cross-read is skipped entirely.</convention>

<convention id="no-implicit-steps">Every action needs an explicit instruction. Never rely on "follow best practices" or "use appropriate patterns." If the agent should run `git push -u origin HEAD`, write that exact command — don't say "push the branch."</convention>

<convention id="single-tool-per-step">Where possible, design steps so each step is ONE tool call. Smaller models lose track of multi-tool steps. If a step requires multiple calls, break it into sub-steps with explicit sequencing ("After step 2a completes, run step 2b").</convention>
</small-model-conventions>

<revision-checklist>
When revising an existing command, **every item below is mandatory** — not a suggestion. Older commands may predate current best practices; touching a command is an opportunity to bring it up to spec.

1. Read the full file before making changes
2. Check for duplicated logic across other commands — consolidate if found
2b. **Delete prose a mechanism already determines** (`no-prose-for-mechanical`): for each rule you touch, ask whether a hook/script now fully decides the outcome. If so, remove the rule, move the explanation into the mechanism's header, and `--ack` it in rubric-drift. Adding a mechanism WITHOUT deleting the prose it replaces is how skills accrete dead weight.
3. **Check behavioral dependencies**: Search for other commands, skills, and rules that perform similar operations or share domain overlap with the one being edited. If command A has a step that is a lightweight version of command B's core behavior (e.g., `/pr-land` addressing comments vs `/pr-address`), verify that A's step is consistent with B's rules — missing rules in A are likely bugs.
   - Extract domain-specific verbs and nouns from the step being edited (e.g., a step about handling PR comments yields: `comment`, `reply`, `resolve`, `address`, `fixup`, `thread`)
   - Search each term across commands, skills, and rules:
   ```bash
   rg -l "<term>" ~/.cursor/skills/*/SKILL.md ~/.cursor/rules/*.mdc
   ```
   - Read any hits that share domain overlap and check for consistency
   - If overlap is found, evaluate whether to consolidate per the `dry` principle: can A reference B's rules or a shared file instead of reimplementing? Propose consolidation to the user when the shared logic is non-trivial.
4. **Check dependent callers before any script/command change**: Before adding, updating, renaming, or removing any command, skill, script, step ID, flag, or output contract, search for direct callers/references and update them in the same change.
   - Search by skill name, script filename, flag names, and any removed/renamed identifiers:
   ```bash
   rg -n "<identifier>" ~/.cursor/skills ~/.cursor/rules
   ```
   - Do not add/update/remove script behavior until caller impacts are audited and required updates are planned.
   - Do not delete or rename a referenced target until all callers are updated.
   - In the final response, list which callers were updated.
5. Verify step ordering matches the agent's decision flow
6. Ensure examples are brief and generic (no real repo names, PR numbers, or user data)
7. Check that escape hatches exist for ambiguous cases
8. Confirm companion scripts match the `.md` expectations
9. Convert markdown-structured commands to XML format (this is the most commonly skipped item — `##` headers and bullet lists must become `<goal>`, `<rules>`, `<step>` tags)
10. Apply all current authoring principles (rules-first, scripts-over-reasoning, batch-tool-calls, etc.) even if the original command predates them
11. If the command may run on smaller/faster models, apply `<small-model-conventions>` — especially `file-over-args`, `inline-guardrails`, and `verbatim-bash`
12. **Re-check name accuracy after scope changes — and prompt before renaming**: After editing, assess whether the change expanded or shifted the skill's/script's responsibilities so its name no longer accurately and clearly describes what it does (per the `name-tracks-scope` principle). The tell: you can no longer state what it does in one phrase that matches its name, or its summary needs "and also…". If the name has drifted:
    - **Propose** a clearer, scope-accurate name (and a one-line reason it's clearer).
    - **Ask the user to confirm the rename before doing it.** NEVER rename silently. If the user declines, leave the name as-is and note the name/scope mismatch in your final response so it's not lost.
    - **On confirmation, rename safely** following item 4's dependent-caller discipline. Cover every surface: the file itself; every textual reference (`rg -n "<old-name>" ~/.cursor ~/.config/agent-watcher`); any launchd registration (the plist filename, its `Label`, `ProgramArguments` path, and `Standard{Out,Error}Path`, plus `launchctl bootout <old>` then `bootstrap`/`kickstart <new>`); docs/READMEs; and the distribution copy in the synced repo (use `git mv` to preserve history). List every surface updated in your final response.
</revision-checklist>

<post-authoring-actions>
When the change touched any `<rule>` block (SKILL.md or .mdc) or any `~/.config/agent-watcher` script, run the rubric drift check BEFORE offering convention-sync:

```bash
~/.cursor/skills/rubric-drift.sh
```

The eval rubrics (agent-eval, orch-eval) anchor their dimensions to rule ids and orch scripts; this detects when an edit moved an anchored expectation or introduced an uncovered rule. Triage every finding line — never leave one unhandled:
- `CHANGED <anchor>` — read the rule/file diff; if the eval expectation moved, update the citing dimension's wording in the rubric, then `--reconcile <anchor>`. If the change doesn't affect what an eval should check, `--reconcile` directly.
- `MISSING <anchor>` — the dimension cites a deleted/renamed rule; fix the rubric grounding (and wording if needed), then re-run.
- `UNCOVERED <skill:rule-id>` — FIRST ask: is this skill an ORCH DEPENDENT (invoked inside orchestrated runs — one-shot and everything it delegates to, the watcher hooks/scripts)? Rubrics grade orch dependents ONLY. A non-orch skill (operator/discussion tooling, the eval layer itself) gets `--exclude-skill <name> --reason "<why non-orch>"` ONCE — never per-rule acks, never a proposed dimension. For a genuine orch dependent: PROPOSE a dimension to the user (the rubric is curated; never auto-write dimensions), or `--ack <skill:rule-id> --reason "<why not eval-relevant>"`.
- `UNCOVERED-CHANGED <skill:rule-id>` — a previously-acked rule's content changed (acks are per-version): re-judge it fresh — propose a dimension or re-`--ack` at the new version.

The lock file (`~/.cursor/skills/rubric-drift.lock.json`) is state; commit it with the sync so other machines share the reconcile point.

After any authoring change (skills/scripts/rules), ask:

> Run `/convention-sync` to sync files and update PR conventions/description?

When `.cursor/rules/*.mdc` files changed, run:

```bash
~/.cursor/skills/convention-sync/scripts/generate-claude-md.sh
```

This keeps `~/.claude/CLAUDE.md` aligned with always-apply rules via the existing convention-sync flow.
</post-authoring-actions>

<companion-scripts>
Skill-specific scripts go in `<skill>/scripts/`. Shared scripts go in `~/.cursor/skills/` top-level. Conventions:

- `set -euo pipefail` at the top
- Parse args with a `while/case` loop
- Output structured, one-line-per-action summaries the agent can parse
- Exit code 0 = success, 1 = error, 2 = needs user input
- **Naming**: Name scripts by what they DO, not which command they serve. Scripts will likely be reused by multiple commands. Prefer descriptive, domain-scoped names over command-coupled names:
  - `lint-commit.sh` — good (describes the operation)
  - `asana-task-update.sh` — good (describes the operation)
  - `github-pr-comments.sh` — good (describes the domain + operation)
  - `pr-address.sh` — bad (coupled to the `/pr-address` command name)
- Before creating a new script, check if an existing script already covers the operation. Extend it with a new subcommand rather than creating a duplicate.
- **GitHub API**: Default to `gh api` and `gh api graphql` — never raw `curl`. See `gh-cli-over-curl` principle.
</companion-scripts>
