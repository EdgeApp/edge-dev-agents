---
name: asana-task-update
description: Update Asana tasks via one reusable workflow (attach PRs, assign/unassign, set status, and update task fields). Use when any skill needs to modify Asana task state.
compatibility: Requires jq. ASANA_TOKEN for Asana API updates. ASANA_GITHUB_SECRET is OPTIONAL — only used by `--attach-pr`. When unset or when the Asana ↔ GitHub widget integration is disabled at the workspace level, `--attach-pr` warns and skips gracefully (exit 0) rather than failing.
metadata:
  author: j0ntz
---

<goal>Perform Asana task mutations through one shared command and one shared script, so all callers use the same field mappings and prompts.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">Use `~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh` for all Asana task mutations. Do not call raw Asana APIs directly from skills that can delegate here.</rule>
<rule id="task-required">Every operation requires `--task <task_gid>`.</rule>
<rule id="attach-graceful-without-secret">`--attach-pr` uses the Asana ↔ GitHub widget integration. The secret is resolved from `$ASANA_GITHUB_SECRET`, else falls back to `credentials.json` (`.asana_github_secret`) — so it works in spawned agent shells that lack the env var. If it's still unset, or if the integration endpoint returns 401/403/404 (integration disabled at the workspace level), the script warns once and skips the widget call with exit 0 — it does NOT fail the workflow. `ASANA_TOKEN` is resolved the same way (env, else `credentials.json` `.asana_token`).</rule>
<rule id="create-subtask">`--create-subtask --subtask-name "<name>"` creates a subtask under `--task` and re-points the rest of the invocation at the new subtask, so a SINGLE call can create the per-PR subtask AND `--attach-pr` its PR. Prints `>> subtask created: <gid>`. Used by `/one-shot`'s `multi-repo-subtasks` to give each repo's PR its own subtask under the umbrella task.</rule>
<rule id="prompt-codes">If the script exits code 2 with `PROMPT_REVIEWER` or `PROMPT_IMPLEMENTOR`, ask the user and re-run with explicit `--reviewer` or `--implementor`. Hands-off callers may instead pass `--skip-assign-if-missing` to convert missing-reviewer assignment into a non-blocking skip.</rule>
<rule id="script-timeouts">Asana updates can take time. Use `block_until_ms: 120000` for script calls.</rule>
</rules>

<usage>
```bash
# Attach only
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-pr --pr-url <url> --pr-title "<title>" --pr-number <num>

# Attach + assign reviewer + set review-needed status + estimate review hours
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-pr --pr-url <url> --pr-title "<title>" --pr-number <num> \
  --assign --set-status "Review Needed" --auto-est-review-hrs

# Hands-off attach + best-effort assign (skip if reviewer missing)
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-pr --pr-url <url> --pr-title "<title>" --pr-number <num> \
  --assign --skip-assign-if-missing --set-status "Review Needed" --auto-est-review-hrs

# Post-merge: set Board State to QA Verification and unassign
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --set-board-state "QA Verification" --unassign

# Attach a run-report markdown file to the task
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-file /tmp/agent-run-report.md --attach-name agent-run-report.md

# Multi-repo: create a per-PR SUBTASK under the main task AND attach its PR (one call).
# --create-subtask makes the subtask under --task, then re-points the attach at it.
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <main_task_gid> \
  --create-subtask --subtask-name "<repo> #<num>: <title>" \
  --attach-pr --pr-url <url> --pr-title "<title>" --pr-number <num>
```
</usage>

<step id="1" name="Build operation flags">
Determine which updates are needed by the caller and build one command with all flags:

- `--attach-pr --pr-url --pr-title --pr-number`
- `--attach-file <path> [--attach-name <name>]` (upload a local file, e.g. a run-report `.md`, as a native task attachment; distinct from `--attach-pr`)
- `--assign` or `--assign <user_gid>`
- `--skip-assign-if-missing`
- `--unassign`
- `--set-status "Review Needed|Publish Needed|Verification Needed"` (legacy Status field)
- `--set-board-state "Incoming Requests|Refinement|Ready to Pull|In Progress|PR Review|QA Verification|Blocked|Done|Icebox"` (new Board State 🤖 field)
- `--set-reviewer <user_gid>`
- `--set-implementor <user_gid>`
- `--set-priority <enum_gid>`
- `--set-planned <enum_gid>`
- `--auto-est-review-hrs`
</step>

<step id="2" name="Run update script">
Run `asana-task-update.sh` with the built flags. Prefer one call with combined operations over multiple calls.
</step>

<step id="3" name="Handle prompts">
If exit code is 2:

- `PROMPT_REVIEWER`: ask who to assign, then re-run with `--reviewer <gid>` and `--assign`
- `PROMPT_IMPLEMENTOR`: ask who to set as implementor, then re-run with `--implementor <gid>`

If the caller used `--skip-assign-if-missing`, do not ask about `PROMPT_REVIEWER` because the script will not emit it for missing-reviewer cases.
</step>

<step id="4" name="Report result">
Summarize one line per action from script output (attach result, assignment, status change, field updates).
</step>

<team-roster description="Asana user GIDs. Use numbered lists when prompting users.">
1. Jon Tzeng — `1200972350160586`
2. William Swanson — `10128869002320`
3. Paul Puey — `9976421903322`
4. Sam Holmes — `1198904591136142`
5. Matthew Piche — `522823585857811`
</team-roster>

<exit-codes>
- `0`: success
- `1`: error
- `2`: needs user input (`PROMPT_REVIEWER`, `PROMPT_IMPLEMENTOR`)
</exit-codes>
