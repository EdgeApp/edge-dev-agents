Governs steps 9, 9b and 10 of `/pr-land` (staging cherry-pick, late bot findings sweep, Asana QA handoff); the core step map points here.

<rules description="Non-negotiable constraints, binding exactly as if written in the core SKILL.md.">
<rule id="qa-subtasks-before-handoff">The QA handoff carries its own checklist: before `--set-board-state "QA Verification"`, each landed task gets one subtask per MANUAL verification item, titled `QA: <what a human verifies>`. Nothing to verify by hand is stated with `--no-manual-qa "<reason>"`, never by skipping. `asana-task-update.sh` enforces the gate (exit 2 `QA_SUBTASKS_REQUIRED`) and refuses developer detail in a `QA:` title or body (exit 1 `QA_NOT_PLAIN`, offending lines on stderr); `asana-get-context.sh` hides `QA:` subtasks from every run, so an orchestrated run never treats them as scope.</rule>
<rule id="qa-writeups-by-opus-subagent">The `QA:` items are WRITTEN by a subagent on Opus, never by the landing session: one Agent call per task with `model: "opus"`. Deciding what a human must verify takes reading what actually landed, and the landing session has only driven scripts. The subagent's whole contract (what to read, what counts as an item, the tester voice, the body shape, the output format) lives in `references/qa-writeup.md`: the subagent reads that file; the landing session does NOT, and passes only the task gid and the landed PRs. The landing session creates the subtasks from the subagent's files unedited; it does not draft, trim or add items. A result whose `READ:` line misses a landed PR has not done the job: re-run the subagent.</rule>
</rules>

<scripts description="This phase's companion scripts and their exit codes. Any exit code not listed here or in the core table = STOP and report (`unexpected-exit`).">

| Script | Purpose |
|--------|---------|
| `staging-cherry-pick.sh` | Cherry-pick merged PR commits onto staging (see `/staging-cherry-pick` skill) |
| `pr-bot-findings-sweep.sh` | After merges: wait (bounded, `--wait 600` shared across PRs) for reviewer bots still running, then list unresolved bot threads per PR as JSON (`unreviewed`, `botThreads[].url`) |
| `asana-task-update.sh` | Update linked Asana tasks after merge |

| Script | Exit 0 | Exit 1 | Exit 2 | Exit 3 | Exit 4 |
|--------|--------|--------|--------|--------|--------|
| `staging-cherry-pick.sh` | All cherry-picked | Error | Auth needed | CHANGELOG conflict | - |
| `pr-bot-findings-sweep.sh` | No findings, all reviewed | GitHub read failed | Usage | Findings or unreviewed PRs (act per step 9b) | - |
| `asana-task-update.sh` | Success | Error | Needs user input | - | - |
</scripts>

<step id="9" name="Staging Cherry-Pick">
**Trigger:** `edge-react-gui` commits qualify on EITHER signal (per `build-field-routing`): (a) the linked Asana task's Build field is `staging` — the primary, field-driven signal — or (b) the commit's CHANGELOG entry targets the `## X.Y.Z (staging)` section (the backstop for PRs with no linked task). This includes both merged PR commits and GUI dependency upgrade commits from step 7.

Qualification is mechanical: the task's Build field from discovery, OR any `prepared[i].newEntrySections` entry (from the step 3 or step 8 prepare output for that PR) containing `(staging)`. Do not re-derive it by reading the CHANGELOG; the prepare output is the record. A GUI PR that qualifies on either signal and is not cherry-picked is an unfinished land, whatever its Asana state. On disagreement (field `staging`, entry under `## Unreleased`), the placement question was already surfaced in step 3 — the field wins for routing.

**Skip** this step entirely only when NO commit qualifies on either signal.

For qualifying PRs/commits, invoke the `/staging-cherry-pick` skill:

```bash
echo '[{"repo":"edge-react-gui","prNumber":123,"mergeSha":"abc123"}]' | ~/.cursor/skills/staging-cherry-pick/scripts/staging-cherry-pick.sh
```

Pass the `mergeSha` recorded from the `ALL_MERGED <repo#num>=<mergeSha>` line (step 5.3 / step 8), or from `pr-land-merge.sh`'s JSON output on the fallback path. For dep upgrade commits, pass the commit SHA from step 7 (the script handles single-parent commits by cherry-picking the sha itself). Staging takes cherry-picks ONLY — never run `upgrade-dep.sh` on staging or commit natively there (staging-cherry-pick `cherry-picks-only`).

**On exit 3 (CHANGELOG conflict):** Run `changelog-union-merge.sh <repoDir> --continue` (it detects the in-progress cherry-pick). Resolve by hand (existing staging entries first, then the new entry) only if it exits non-zero. Re-run for remaining PRs.

**On exit 1 (code conflict):** STOP and report to user.

After cherry-picks succeed, ask user to confirm push:
```bash
git push origin staging
```

Then restore the previous branch.
</step>

<step id="9b" name="Late Bot Findings Sweep">
**Runs after every PR this run merged (steps 5 and 8) has merged, before step 10.** ONE call over all of them:

```bash
~/.cursor/skills/pr-land/scripts/pr-bot-findings-sweep.sh <repo#num> [more...] --wait 600 > /tmp/pr-land-bot-sweep.json
```

1. Exit `0` → nothing to do; go to step 10.
2. Exit `1` → a GitHub read failed: re-run once; if it fails again, report it in step 11 under "Late bot findings" as "sweep failed" and go to step 10.
3. Exit `3` → for each `repo` with any entry whose `botThreads` or `unreviewed` is non-empty:
   1. Write `/tmp/pr-land-bot-followup-<repo>.txt` with the Write tool (plain text, no em dashes):
      ```
      Reviewer-bot findings that arrived after these PRs merged. Evaluate each one: fix valid findings in a new PR; for invalid ones, reply on the thread with the reason.

      <prUrl>
      - <path>: <first sentence of body> <url>

      Not reviewed before the sweep deadline: <prUrl> (<unreviewed names>)
      ```
   2. Create the follow-up task: run once with `--dry-run`, check the payload, then the same command without it:
      ```bash
      ~/.cursor/skills/asana-task-create/scripts/asana-task-create.sh --name "Address post-merge bot findings: <repo>" --notes-file /tmp/pr-land-bot-followup-<repo>.txt --release <release.selected> --repo <Repo option> --set "Category=Bugfix/Tweak" --dry-run
      ```
      Repo option: `jq -r --arg r <repo> '.custom_fields.repo.github_repo_options[$r] // empty' ~/.config/agent-watcher/asana-config.json` (the one copy of the map); an empty result omits `--repo`. Omit `--release` when discovery returned no `release`. Keep the printed `TASK_URL`.
   3. For EVERY thread in that repo's `botThreads`, reply with the task link, then resolve (an unresolved thread fails one-shot's finalize-gate):
      ```bash
      ~/.cursor/skills/pr-address/scripts/pr-address.sh reply --owner EdgeApp --repo <repo> --pr <prNumber> --comment-id <commentId> --body "Arrived after merge; tracked in <TASK_URL>"
      ~/.cursor/skills/pr-address/scripts/pr-address.sh resolve-thread --thread-id <threadId>
      ```
</step>

<step id="10" name="Update Asana Tasks">
**Runs ONLY after ALL merges, cherry-picks, publishes, and GUI dep upgrades are complete.**

Only update for fully landed PRs:
- GUI PRs: merged
- GUI-dep repos (per step 6's GUI-dep check): merged AND published AND GUI deps updated
- Non-dep repos (fail the GUI-dep check, e.g. deployed servers): merged

Do NOT update for: skipped PRs, addressed-but-not-re-reviewed PRs, or GUI-dep repos not published.

<sub-step name="env.json gate (before any update)">
A task whose landed diff requires a build-server config change is NOT done when it merges — the new config value must exist on the build server before QA can verify. For each landed GUI PR, check its diff for ADDITIONS to the config schema: `src/configKeysSchema.ts` on develop-based PRs (`config.json`/`keys.json`, plus new plugin-map entries such as a `corePlugins`/`swapPlugins` key the code now reads), `src/envConfig.ts` on staging/master-based PRs (legacy `env.json` `*_INIT`). `gh pr diff <n> --repo EdgeApp/edge-react-gui --name-only` shows whether either file changed; read the `+` lines of those files in `gh pr diff <n> --repo EdgeApp/edge-react-gui`. If a PR adds config keys:
- Do NOT move that task's Board State.
- Surface it in the final report (and as an Asana comment on the task in orchestrated runs): name the exact key path(s) and file needed, e.g. `keys.json` `swapPlugins.nymswap.apiKey`.
Removals are fine (cleaners strip unknown fields); only additions gate.
</sub-step>

<sub-step name="Extract Asana task GIDs">
Pipe the PR metadata through the new helper so you only consume the Asana link once per PR:

```bash
printf '[{"repo":"edge-react-gui","prNumber":123}]' | ~/.cursor/skills/pr-land/scripts/pr-land-extract-asana-task.sh > /tmp/asana.json
```

The helper outputs JSON like `{ "tasks": [{ "taskGid": "...", "label": "repo#123" }], "missing": [{ "label": "...", "reason": "..." }] }`.

**Parent-walking:** `taskGid` is the PR's linked task's PARENT when a parent exists (the feature-level task that represents the unit of work across repos). Standalone tasks (no parent) return themselves. Only updates the parent — leave subtasks alone; they have their own state that is managed separately. Sibling subtasks of the same parent dedupe to one entry; `label` lists all contributing PRs (e.g. `"edge-react-gui#123, edge-core-js#456"`).

Review the `missing` array, report any entries lacking an Asana link, and skip those PRs for Asana updates.
</sub-step>

<sub-step name="Manual QA subtasks">
For each task in `.tasks`, per `qa-writeups-by-opus-subagent`, spawn one Agent call with `model: "opus"` and this prompt, filled in:

```
Read ~/.cursor/skills/pr-land/references/qa-writeup.md and follow it exactly; it is your full brief.
Task gid: <task_gid>
Landed PRs (repo#number | merge sha | local checkout):
- <repo>#<n> | <merge-sha> | ~/git/<repo>
```

It returns one `<n> | QA: <title>` line per item (bodies in `/tmp/qa-<task_gid>-<n>.md`) and a `READ:` line. Create each subtask from those (one call per item):

```bash
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --create-subtask --subtask-name "QA: <title>" --subtask-notes /tmp/qa-<task_gid>-<n>.md
```

Exit 1 `QA_NOT_PLAIN` → send the offending lines back to the SAME subagent (SendMessage) to rewrite the file, then re-run the call. `NO_MANUAL_QA: <reason>` → pass `--no-manual-qa "<reason>"` on the handoff call below instead. Put each task's `READ:` line in the step 11 summary.
</sub-step>

<sub-step name="Update tasks">
For each task in `.tasks`, run:

```bash
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --set-board-state "QA Verification" \
  --unassign
```

Writes to the Board State 🤖 field. The legacy Status field is not updated.

**Exit codes per call:**
- `0` = success
- `1` = error
- `2` = needs user input
</sub-step>
</step>
