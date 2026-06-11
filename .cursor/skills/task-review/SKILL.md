---
name: task-review
description: Fetch context from an Asana task, analyze it, present a summary, and determine the target repo. Use when the user provides an Asana task link for review.
compatibility: Requires jq. ASANA_TOKEN for Asana integration.
metadata:
  author: j0ntz
---

<goal>Fetch context from an Asana task, analyze it, present a summary, and determine the target repo. This is the **single source of truth** for Asana task understanding — both `im.md` and `pr-create.md` delegate here.</goal>

<rules description="Non-negotiable constraints.">
<rule id="summary-first">Present the task summary to the user BEFORE exploring any code. Code exploration happens after the user has seen the analysis.</rule>
<rule id="script-timeout">The `asana-get-context.sh` script can take up to 90s (PDF conversion is slow). Always set `block_until_ms: 120000` when invoking it.</rule>
</rules>

<when-this-runs>
- Automatically as the first step of `im.md` when an Asana task link is provided
- Automatically as Step 1 of `pr-create.md` when an Asana task link is provided
- Can also be invoked standalone: `/task-review https://app.asana.com/1/.../task/<task_gid>`
</when-this-runs>

<step id="1" name="Fetch task context and attachments">
Extract the `task_gid` (the final numeric ID in the URL) and run:

```bash
~/.cursor/skills/asana-get-context.sh <task_gid>
```

This fetches task metadata, comments, and **automatically downloads and processes attachments** to `/tmp/asana-task-<task_gid>/`:

- **Text files** (`.md`, `.txt`, `.json`, `.csv`, `.log`, `.yaml`, `.yml`): Downloaded directly — read them.
- **PDFs**: Text-extracted first (`PDF_TEXT:` output). If the PDF is image-based, converted to page images (`PDF_PAGES:` output).
- **ZIPs**: Unpacked recursively (`UNPACKED:` output). Extracted files (including PDFs inside) are then processed by the same handlers.
- **Images** (`.png`, `.jpg`, `.gif`, `.webp`): Downloaded directly — read them.

<sub-step name="Reading processed attachments">
After the script completes, read the processed files based on the output:

1. **`DOWNLOADED:` paths** — Read any `.txt`, `.md`, `.json`, `.csv`, `.yaml`, `.yml` files listed.
2. **`PDF_TEXT:` paths** — Read the extracted `.txt` file. This is the full text content of the PDF.
3. **`PDF_PAGES:` directories** — Read the page images (`page-01.png`, `page-02.png`, etc.) using the Read tool. For large documents (>20 pages), read the first 10 pages, then skim the rest by reading every 3rd-5th page.
4. **`UNPACKED:` directories** — List contents (`ls -R`), then read relevant files (text files, images, etc.). Skip macOS metadata (`__MACOSX/`, `.DS_Store`).
</sub-step>

<sub-step name="No attachments case">
If `ATTACHMENTS: (none)` appears in script output, do **not** probe `/tmp/asana-task-<task_gid>/`. Treat missing `/tmp` paths as expected in this case and continue to Step 2.
</sub-step>

<sub-step name="Relationship pointers">
The script reports related tasks as pointers only: `PARENT:`, `SUBTASKS:`, `DEPENDENCIES:`, `DEPENDENTS:`, each row `<gid> [open|done] <name>`. Lines are omitted when empty. Decide what to walk by priority:

1. `PARENT:` present → also run `asana-get-context.sh <parent_gid>`. Requirements for split subtasks usually live on the parent. Walk up ONE level only; ignore the parent's own pointers.
2. `SUBTASKS:` / `DEPENDENCIES:` / `DEPENDENTS:` present → list them in the Step 3 summary as-is. Fetch one ONLY when the task description or comments reference it as required context.
3. Never bulk-fetch all pointers. Related-task content is opt-in per task; pulling every linked task pollutes context.
</sub-step>
</step>

<step id="2" name="Determine target repo">
**Resolve the target repo by examining code, not task text.** Task titles, descriptions, keywords, and attachments are noisy — the same terms (e.g. "swap", "wallet", "send", "plugin") appear across multiple repos, and text hints frequently mislead. Code is the only authoritative signal for *where* a change must land. You will need to explore the code to scope the work anyway — do it up front for repo resolution.

<sub-step name="Resolution workflow">
1. **Extract concrete handles from the task text.** Pull out specific file names, function names, scene names, plugin IDs, component names, config keys, URLs/hostnames, error strings, or feature identifiers. Ignore vague domain words.
2. **Grep the candidate repos** for those handles. Start broad across all four repos; narrow to the repo where the matching code actually lives:
   - `edge-react-gui` — app UI, scenes, redux, navigation, plugin orchestration
   - `edge-exchange-plugins` — swap/exchange plugins
   - `edge-currency-accountbased` — account-based currency drivers (EVM, Cosmos, Solana, etc.)
   - `edge-core-js` — EdgeAccount, login, core SDK APIs
3. **Confirm by reading the matched code.** A name collision across repos is possible; verify the matching code actually corresponds to the behavior the task describes.
4. **If code examination is inconclusive** (no grep hit, or hits span multiple repos), ASK the user before proceeding. Do not guess from text alone.

State the resolved repo and cite the files/symbols that pinned it in the Step 3 summary.
</sub-step>

<sub-step name="Prefix shortcut (when present)">
If the task title starts with one of these prefixes, the prefix is a deterministic shortcut that skips grep-based resolution. Prefixes are the exception, not the norm:

| Prefix | Repository | Branch from |
|--------|------|-------------|
| `gui:` | `edge-react-gui` | `develop` |
| `exch:` | `edge-exchange-plugins` | `master` |
| `accb:` | `edge-currency-accountbased` | `master` |
| `core:` | `edge-core-js` | `master` |

Treat prefix absence as normal. A prefix only skips Step 2's grep work — the Step 3 summary should still cite the specific files/symbols affected (you'll need them for the implementation plan).
</sub-step>

<sub-step name="Linked PRs short-circuit resolution">
If the task has an attached or linked GitHub PR, the PR's repo is the authoritative target — no grep needed.
</sub-step>

<sub-step name="Branch-from defaults">
Always create feature branches from the "Branch from" column: `edge-react-gui` branches from `develop`; `edge-exchange-plugins`, `edge-currency-accountbased`, and `edge-core-js` branch from `master`.
</sub-step>

<sub-step name="Cross-repo work — split into Asana subtasks">
If grep shows the work genuinely spans more than one repo (e.g. a GUI change depending on a new core-js API), a single PR cannot cover it. Before implementing:

1. **Stop and flag the split to the user.** Name each repo and cite the files/symbols that belong in each.
2. **Create one Asana subtask per repo under the parent**, titled with that repo's prefix (e.g. `gui: ...`, `core: ...`). Subtasks allow multiple PRs to attach to the same parent task.
3. Wait for user confirmation before creating subtasks or proceeding.
4. After the split, treat each subtask as its own task-review target — re-run Step 2 per subtask.

Do not attempt to satisfy a multi-repo task with a single PR.
</sub-step>
</step>

<step id="3" name="Summarize understanding">
Present a concise summary to the user covering:

1. **What**: One-sentence description of the task/bug in your own words (not just parroting the title)
2. **Why**: The motivation — what problem does this solve or what value does it add?
3. **Target repo**: Which repo (determined in Step 2)
4. **Scope**: What files/areas of the codebase are likely involved? Use the task description, comments, and your knowledge of the repo to estimate.
5. **Approach**: A brief proposed approach (1-3 bullets). If multiple approaches exist, list them with tradeoffs.
6. **Priority**: Note the priority level if set.

<sub-step name="Surfacing questions">
After the summary, list any:
- **Ambiguities**: Requirements that are unclear or could be interpreted multiple ways
- **Missing info**: Information needed that isn't in the task
- **Contradictions**: Conflicting statements between the description and comments
- **Decisions needed**: Choices that the user should weigh in on before implementation begins

If there are no questions, say so explicitly — don't fabricate them.
</sub-step>

<sub-step name="Using comments and attachments">
- **Comments**: Read for updated requirements, decisions, or clarifications that may override the original description. Call out any that change scope.
- **Text attachments**: Read downloaded text files for additional context (specs, requirements, analysis). Reference relevant content in the summary.
- **PDF attachments**: Summarize key content from extracted text or page images. For brand guidelines, note colors, logos, naming, and other visual details.
- **ZIP attachments**: Note the contents and any relevant files found inside. For asset packages (logos, icons), describe the available formats and variants.
- **Image attachments**: View and describe the content. Note any UI mockups, designs, or reference screenshots.
</sub-step>
</step>

<step id="4" name="Wait for confirmation (im.md and standalone only)">
When invoked from `im.md` or standalone, end with a clear prompt:

> Does this match your understanding? Any adjustments before I start?

**Do NOT begin implementation until the user confirms.**

When invoked from `pr-create.md`, skip this step — the task context is used for repo/branch resolution and PR enrichment, not for implementation planning.
</step>
