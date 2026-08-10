---
name: kanban-categorize
description: Sweep an Asana kanban board's incomplete tasks for one department, populate/amend the Category field, tag trivial copy/visual tasks "UI (Minor)", and additively set the Departments field on named tasks. Use when the user asks to categorize, groom, or triage board tasks' Category field, UI tags, or department coverage.
compatibility: Requires jq and ASANA_TOKEN (or ~/.config/agent-watcher/credentials.json).
metadata:
  author: j0ntz
---

<goal>Ensure every incomplete task on the board for the given department has a correct Category value, and that purely-copy or trivial-visual tasks carry the "UI (Minor)" tag.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">All board reads and writes go through `~/.cursor/skills/kanban-categorize/scripts/kanban-category.sh`. Never use the Asana MCP tools for board sweeps and never hand-roll curl loops — the script's header explains why and it resolves field/option/tag GIDs by name at runtime.</rule>
<rule id="populate-vs-amend">Populating BLANK Category values is always in scope. AMENDING a value someone already set requires the user's explicit authorization — a person chose that value deliberately. Without authorization, list proposed amendments (task, current, proposed, one-line reason) in the final response and stop there.</rule>
<rule id="category-semantics">Category is a WORK-TYPE field, not a repo-location field. Classify by what the work IS:
1. Bugfix/Tweak — fixing broken behavior or small adjustments to existing behavior. The board's catch-all; when torn between this and Feature, new capability wins.
2. Feature — new user-facing or system capability that didn't exist before (new integrations, new chains/assets/pairs, new APIs, new screens).
3. Investigation/Research — the deliverable is a diagnosis, evaluation, or feasibility answer, including bug investigations ("Investigate X" with no committed fix).
4. Dependency — upgrading an EXTERNAL or partner-provided dependency (SDK upgrades, partner contract upgrades, network hard-forks). NOT "work that lands in a non-GUI repo"; a `core:`/`reports:`/`login-server:` title prefix is not a Dependency signal.
5. Spec/Refine — the deliverable is a plan, spec, or refined task breakdown that spawns other tasks.
6. Bug Bounty — external vulnerability reports. Support Request — a partner/support-originated ask. Visual Design — design work producing mockups, not code. Marketing — content deliverables.</rule>
<rule id="ui-minor-criteria">Tag "UI (Minor)" ONLY for tasks that are purely copy changes (labels, warnings, wording) or trivial visual fixes (text cutoff/overlap, decimal display, icon assets, renames shown in UI). Anything needing flow, logic, or API changes does not qualify, however small.</rule>
<rule id="verify-after-write">After `apply`, always run `verify` on the same TSV. Report the mismatch count; nonzero means investigate before reporting success.</rule>
</rules>

<step id="1" name="Fetch">
```bash
~/.cursor/skills/kanban-categorize/scripts/kanban-category.sh fetch --out <scratchpad>/kanban.json
```
Scope comes from the user's request: add `--department <Department>` when they name one, omit it for a whole-board sweep. Default board is the Edge 4.x Master Kanban; pass `--board <gid>` only if the user names another board. The output prints task counts, the current Category and Departments distributions, and the board's live option names — use ONLY option names from that list. The JSON carries notes truncated to 1000 chars; that plus name/state/tags is the working set for classification.
</step>

<step id="2" name="Classify">
Read the uncategorized tasks from the JSON (gid, name, notes). Judge each against `category-semantics`, using the already-categorized tasks in the same JSON as calibration for house style. When the truncated notes leave a task genuinely unjudgeable (or the call hinges on subtasks/comments), run `detail --task <gid>` for that ONE task — never re-fetch the board at higher fidelity. For a task with an empty description and uninformative detail, classify by the closest precedent on the board and flag it as a guess in the final response rather than asking mid-flow.
</step>

<step id="3" name="Apply and verify">
Write `assign.tsv` (`<gid>\t<Category name>` per line, tab-separated) covering every blank task, then:
```bash
~/.cursor/skills/kanban-categorize/scripts/kanban-category.sh apply --file assign.tsv
~/.cursor/skills/kanban-categorize/scripts/kanban-category.sh verify --file assign.tsv
```
Before applying, sanity-check the TSV: every target gid must be in the fetched JSON, and (when only populating) must have `category: null` in it.
</step>

<step id="4" name="Tag UI (Minor)">
Select qualifying tasks per `ui-minor-criteria` from the WHOLE fetched set (not just the blanks — already-categorized copy tasks qualify too). Skip tasks already tagged. Write their gids one per line and:
```bash
~/.cursor/skills/kanban-categorize/scripts/kanban-category.sh tag --tag-name "UI (Minor)" --file uiminor.txt
```
</step>

<step id="5" name="Set Departments (only when asked)">
Runs only when the user asks for department coverage. Select candidates from the sweep JSON's `departments` arrays (in a department-scoped sweep the gids come from the user instead — a task missing that department is invisible to the filter). Add Engineering to any task whose deliverable requires code, flow, or API work but whose `departments` lacks it, regardless of what other departments are set; pure design mockups, marketing content, and support-conversation tasks do not qualify. Write the gids one per line and:
```bash
~/.cursor/skills/kanban-categorize/scripts/kanban-category.sh set-department --department <Department> --file depts.txt
```
Additive only: the script PUTs the union with existing values and has no removal path. Never attempt to remove a department by other means; if the user asks for removal, tell them to do it in the Asana UI.
</step>

<step id="6" name="Report">
Final response contains: before/after Category distribution table, count of tags added, the `set-department` ok/already/fail counts when step 5 ran, any flagged guesses (empty-description tasks), and — if amendments were not authorized — the proposed-amendments list per `populate-vs-amend`.
</step>

<edge-cases>
<case name="Board drift mid-run">The board is live (automations add tasks continuously). If verify reports a task as missing/completed, it changed under you — refetch and reconcile rather than retrying the write.</case>
<case name="Ambiguous category definitions">If a task genuinely fits two categories and board precedent is contradictory, pick per the priority order in `category-semantics` and note the call in the final response — don't stop to ask.</case>
</edge-cases>
