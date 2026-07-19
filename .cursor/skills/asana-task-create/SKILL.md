---
name: asana-task-create
description: Create an Edge dev task on the standard boards (Master Kanban, Engineering, jon-claude Refinement) with Engineering fields filled, options auto-created for Release/Repo, and files attached. Use when the user asks to create/file an Asana task for dev work (e.g. "create a 4.53 task for X", "make a task for this TDD").
compatibility: Requires jq and curl. ASANA_TOKEN env or credentials.json (.asana_token). No MCP.
metadata:
  author: j0ntz
---

<goal>Create a fully filled-out Edge dev Asana task on the standard boards with one script call, without MCP tools.</goal>

<rules description="Non-negotiable constraints.">
<rule id="no-mcp">Use the companion script `~/.cursor/skills/asana-task-create/scripts/asana-task-create.sh` and the shared Asana scripts. Never use mcp__*Asana* tools for this workflow: they cannot upload attachments and their field handling drifts from the shared scripts' mappings.</rule>
<rule id="standard-homes">Every task created here lands on all three boards: Edge 4.x Kanban (Master) and Engineering Board in their default incoming sections, and the jon-claude board in Refinement (override only with an explicit `--jon-claude-section` from the user). The script enforces this; do not create partial-home tasks.</rule>
<rule id="release-optional">Release (4.x.x) is the ONLY optional field concern: pass `--release` when the user names a target release, omit it otherwise. The script normalizes app-version spellings to the field's option naming (`4.53`, `4.53.0`, `53`, and `53.0` all mean option "53.0"); pass the user's spelling as-is. A missing Release option (e.g. a new "54.0") is auto-created by the script; so are missing Repo options. All other enum fields reject unknown values and list the valid ones; never force-create options on them.</rule>
<rule id="fill-eng-fields">Fill every Engineering-board field you can justify from the task content: Repo, Priority, LOE, Category, and (when inferable) Release Notes, Severity, Estimate (hrs). Leave a field unset rather than guessing; an empty field is recoverable, a wrong one misroutes automations.</rule>
<rule id="automation-fields-off-limits">Never set automation- or orchestration-owned fields at creation: anything with 🤖 in the name (Board State 🤖, Departments 🤖, 🤖 - Developer), agent_* fields, blocked, tested, Force Land, Build (staging/cheese), Status, Proposal Status. Board automations and the orchestrator own these. The script blocklists them.</rule>
<rule id="notes-file">Pass the description via `--notes-file`, never inline. Write it with the Write tool first. Plaintext, no em dashes, /no-slop. When the task references a living document (gist, doc), include BOTH a pinned immutable revision link (the snapshot at task creation) and the live URL.</rule>
<rule id="delegate-mutations">Post-creation mutations (attach PRs, assign, set status/board-state) belong to `/asana-task-update`, not this skill. The script already delegates `--attach-file` there.</rule>
<rule id="script-timeouts">Asana calls can be slow. Use `block_until_ms: 120000` for script calls.</rule>
</rules>

<field-reference description="Board and field constants baked into the script. Option GIDs are resolved by NAME at runtime; never hardcode option GIDs.">
- Workspace: 9976422036640 (airbitz.co)
- Boards: Master Kanban 1213843652804305; Engineering 1213880789473005; jon-claude 1215088146871429 (sections resolved by name; phases: Refinement, Pending, Planning, Developing, Testing, Reviewing, Complete, Archived)
- Enum fields settable here, by name via `--set "Field=Value"`: Priority (Low/Medium/High), LOE (XS/S/M/L/XL; prefix match works), Category (Feature, Bugfix/Tweak, Investigation/Research, Dependency, Support Request, Spec/Refine, Visual Design, Bug Bounty, Marketing), Release Notes (Added / N/A / Needs To Be Added), Severity (1 - $50 ... 6 - $10,000)
- Dedicated flags: `--release <n.n>` (Release (4.x.x), option auto-created if missing), `--repo <csv>` (Repo multi-enum: GUI, Core, Exch, Accb, Currp, LoginUi; options auto-created if missing)
- Number fields via `--set`: Estimate (hrs)
- Not settable via script (people/date/reference types): Collaborators, Reference; set manually in Asana if needed
</field-reference>

<step id="1" name="Gather context">
Collect from the user request: task name, target release (optional), repos touched, and the description content. If field choices are unclear, fetch how recent Engineering tasks are filled (read-only) and mirror their conventions:

```bash
~/.cursor/skills/asana-task-create/scripts/asana-task-create.sh --show-field-context
```

Choose Priority/LOE/Category/Severity/Estimate the way comparable peer tasks do. Ask the user only when the content genuinely supports conflicting choices (per `fill-eng-fields`, no guessing).
</step>

<step id="2" name="Write the notes file">
Write the description to a temp file (Write tool, `/tmp/asana-task-notes.txt`). Structure: one-line target/goal, links (pinned snapshot + live per `notes-file`), scope bullets, process requirements, context/prior-task links.
</step>

<step id="3" name="Dry-run, then create">
Preview first, then create with the same flags minus `--dry-run`:

```bash
~/.cursor/skills/asana-task-create/scripts/asana-task-create.sh \
  --name "<name>" --notes-file /tmp/asana-task-notes.txt \
  --release <n.n> --repo <core,gui> \
  --set "Priority=<v>" --set "LOE=<v>" --set "Category=<v>" \
  --attach-file <path> \
  --dry-run
```

Review the dry-run payload (fields resolved, sections found, `CREATED_OPTION` lines flag options that will be created). Then re-run without `--dry-run`. Report `TASK_URL`, the `FIELD:`/`CREATED_OPTION:`/`ATTACHED:` lines, and anything left unset with the reason.
</step>

<edge-cases>
<case name="Unknown enum value">The script exits 1 listing valid options (except Release/Repo, which auto-create). Pick the right option from the list or ask the user; do not retry with a forced create.</case>
<case name="Subtask instead of board task">If the user wants a subtask under an existing task, this skill does not apply; use `/asana-task-update` `--create-subtask`.</case>
<case name="Different boards requested">If the user explicitly names different projects/sections, confirm the deviation, then create via this script and move memberships with the Asana UI or extend the script; do not silently skip the standard homes (per `standard-homes`).</case>
<case name="Attachment upload fails">The attach step delegates to asana-task-update.sh; on failure the task still exists. Report the TASK_URL and the failed file rather than re-creating the task.</case>
</edge-cases>
