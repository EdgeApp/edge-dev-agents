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
<rule id="create-subtask">`--create-subtask --subtask-name "<name>"` creates a subtask under `--task` and re-points the rest of the invocation at the new subtask, so a SINGLE call can create the per-PR subtask AND `--attach-pr` its PR. Prints `>> subtask created: <gid>`. Used by `/one-shot`'s `multi-repo-subtasks` to give each repo's PR its own subtask under the umbrella task. `--subtask-notes <file>` sets the new subtask's body verbatim (plain notes; the script refuses a file carrying a CURRENT STATE section, that section is the parent task's).</rule>
<rule id="qa-subtasks">A subtask titled `QA: <what a human verifies>` is a manual verification item for the QA handoff (pr-land `qa-subtasks-before-handoff`), never scope: `asana-get-context.sh` hides them from every run's ingestion. `--set-board-state "QA Verification"` exits 2 (`QA_SUBTASKS_REQUIRED`) when the task has no open `QA:` subtask; write the items first, or pass `--no-manual-qa "<why nothing needs a human>"`, which the script posts as a comment.</rule>
<rule id="current-state-owns-the-tail">`--set-current-state <file>` is the ONLY sanctioned way to write a task description. It rewrites the agent-maintained tail and preserves operator prose above the delimiter; the delimiter literal, the strip-and-replace, and the authorship marking all live in the script, so callers supply bullets only. Never assemble a `notes` PUT by hand — raw Asana API calls are hook-blocked in agent sessions, and a hand-rolled write drops the marking and risks clobbering the operator half. The section's content contract (when it is owed, what the bullets say) belongs to one-shot `description-current-state`.</rule>
<rule id="prompt-codes">If the script exits code 2 with `PROMPT_REVIEWER`, ask the user who to assign and re-run with `--assign <user_gid>`. Hands-off callers may instead pass `--skip-assign-if-missing` to convert missing-reviewer assignment into a non-blocking skip.</rule>
<rule id="script-timeouts">Asana updates can take time. Use `block_until_ms: 120000` for script calls.</rule>
</rules>

<usage>
```bash
# Attach only
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-pr --pr-url <url> --pr-title "<title>" --pr-number <num>

# Attach + assign reviewer + move the card to PR Review
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-pr --pr-url <url> --pr-title "<title>" --pr-number <num> \
  --assign <user_gid> --set-board-state "PR Review"

# Hands-off attach + best-effort assign (skip if reviewer missing)
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-pr --pr-url <url> --pr-title "<title>" --pr-number <num> \
  --assign --skip-assign-if-missing --set-board-state "PR Review"

# Post-merge: write the manual QA items (one subtask each), then hand off
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --create-subtask --subtask-name "QA: <what a human verifies>" --subtask-notes /tmp/qa-1.md
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --set-board-state "QA Verification" --unassign
# (or, when nothing needs a human: --no-manual-qa "server-only change, covered by CI")

# Attach a run-report markdown file to the task. Orch doc names are numbered per
# task: the run-report attach gate renames reports to <N>-agent-run-report.md, and
# the script renames plan-<title>.md to <N>-plan-<title>.md (lib/attach-names.sh).
# Re-attaching a corrected report under the same name REPLACES this segment's copy
# (upload, then delete the older one); plans and other files dedupe instead.
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-file /tmp/agent-run-report.md --attach-name agent-run-report.md

# Post a task comment from a file (marked as agent-authored; posts before any
# --attach-file in the same call, so the report stays the newest story).
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> --comment-file /tmp/comment-<task_gid>.md

# Rewrite or retire a comment already posted (ours only, and only a real comment:
# the script refuses another author's story and any system story). --edit-comment
# keeps the story gid, so followers see the correction in place rather than a
# second comment; --delete-comment runs before a post in the same call, which
# retires a wrong comment and leaves the replacement as the newest story.
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> --edit-comment <story_gid> --comment-file /tmp/comment-<task_gid>.md
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> --delete-comment <story_gid>

# Refresh the agent-maintained CURRENT STATE tail of a task description.
# Body file holds the bullets ONLY: the script adds the delimiter, preserves the
# operator prose above it, replaces any previous section, and applies the markers.
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> --set-current-state /tmp/current-state-<task_gid>.md

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
- `--comment-file <path>` (post the file's text as a task comment, marked as agent-authored)
- `--edit-comment <story_gid> --comment-file <path>` (replace that comment's body in place; the gid survives, so use it to correct a comment rather than posting a second one)
- `--delete-comment <story_gid>` (remove that comment; pair it with `--comment-file` in one call to replace a comment with a fresh story). Both refuse a story that is not a comment, belongs to another task, or was written by another user, so a gid typo cannot erase the task's audit trail.
- `--assign` or `--assign <user_gid>` (sets the task assignee, e.g. a roster member below; with no gid there is no field to read one from, so it prompts or skips)
- `--skip-assign-if-missing`
- `--unassign`
- `--set-board-state "<option name>"` (Board State 🤖), `--set-priority "<option name>"` (Priority), `--set-release "<option name>"` (Release (4.x.x)). Only Engineering Board and jon-claude fields are writable here; other boards' fields that show on a task (the old Status, Reviewer, Implementor, Planned) are not. Each resolves the name against the FIELD'S OWN options on the task at call time, so this file never lists them: the operator adds and renames options in Asana and any list here would go stale. Matching ignores case, surrounding whitespace, and a leading emoji. An option gid is accepted too (for callers copying a field between tasks) and is validated the same way. An unrecognized value exits 1 naming every real option, so ask the script rather than guessing:
  ```bash
  ~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task <gid> --set-board-state "?"
  ```
- `--set-developer <user_gid>` (🤖 - Developer people field)
- `--set-current-state <file>` (rewrite the description's agent-maintained tail; body file carries the bullets only)
</step>

<step id="2" name="Run update script">
Run `asana-task-update.sh` with the built flags. Prefer one call with combined operations over multiple calls.
</step>

<step id="3" name="Handle prompts">
If exit code is 2:

- `PROMPT_REVIEWER`: ask who to assign, then re-run with `--assign <gid>`

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
- `2`: needs user input (`PROMPT_REVIEWER`)
</exit-codes>
