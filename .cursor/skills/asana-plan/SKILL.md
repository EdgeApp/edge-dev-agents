---
name: asana-plan
description: Create an implementation plan from either an Asana task URL or ad-hoc text/file requirements, then wait for user confirmation before implementation.
compatibility: Requires jq. ASANA_TOKEN for Asana context when task URLs are provided.
metadata:
  author: j0ntz
---

<goal>Produce a plan document via Cursor planning flow from Asana or text requirements, and hand off approved context to implementation skills.</goal>

<rules description="Non-negotiable constraints.">
<rule id="task-review-for-asana">If input is an Asana task URL, read and follow `~/.cursor/skills/task-review/SKILL.md` steps 1-3 before planning.</rule>
<rule id="no-impl-before-confirm">Do not start implementation while in this skill. End by asking for confirmation.</rule>
<rule id="create-plan-required">Output the plan document to the normal planning location. Name the plan file with BOTH the Asana task GID and a short kebab-case title (e.g. `plan-<gid>-<short-title>.md`), never the GID alone — opaque names are hard to scan. Stamp the orchestration session into the plan: when `$AGENT_SESSION_UUID` is set, record it in the plan's header (e.g. an `agent_session_uuid:` frontmatter line), so the plan is traceable to the session that produced it. In Cursor, use the plan tool; in headless/orchestration runs, write the plan to that named file.</rule>
</rules>

<step id="1" name="Resolve input mode">
Accept two input forms:

1. **Asana URL mode**: Task URL is provided
2. **Text/file mode**: Ad-hoc text requirement or file reference is provided

If input is ambiguous, ask the user to clarify which mode applies.
</step>

<step id="2" name="Gather requirements">
<sub-step name="Asana URL mode">
Read `~/.cursor/skills/task-review/SKILL.md` and run its steps 1-3 to fetch and summarize task context.
</sub-step>

<sub-step name="Text/file mode">
Read the provided description and any referenced file(s), then summarize scope, target areas, and assumptions.
</sub-step>
</step>

<step id="3" name="Generate plan">
Create a concise actionable implementation plan using Cursor's plan flow. Include:

- Summary
- Goal / Definition of Done
- Likely relevant files
- Findings so far
- Numbered implementation steps
- Constraints
</step>

<step id="4" name="Handoff and confirmation">
Return:

1. Plan file path
2. Short execution summary (what will be changed)

Then ask for confirmation before implementation:

> Does this match your understanding? Any adjustments before I start?
</step>

<handoff-contract>
`/im` consumes this output and starts only after user confirmation. `/im` should not re-run a second independent confirmation flow for the same plan.
</handoff-contract>
