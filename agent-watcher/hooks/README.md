# Claude Code hooks on this machine

This file is the reference for every Claude Code hook registered on this box. The registrations themselves live in `~/.claude/settings.json` under the `.hooks` key, which convention-sync projects into the edge-dev-agents repo as `claude-settings/hooks.json`; the scripts ship in the `agent-watcher/` tree of the same repo. 46 scripts are registered across 53 event/matcher rows. Hook scripts are re-read from disk on every invocation, so editing a script takes effect on the next tool call, while adding, removing, or re-matchering a registration needs a settings reload before any session sees it.

Most gates no-op unless `AGENT_TASK_GID` is set, which is what confines them to orchestrated runs. The exceptions, verified against the scripts:

- Every session, orchestrated or chat: `record-file-writes.sh`, `block-raw-asana-api.sh`, `block-raw-gh-writes.sh`, `block-raw-thread-resolve.sh`, `git-history-gate.sh`, `nudge-asana-mcp.sh`, `slack-prose-gate.sh`, `lint-md-on-write.sh`, `inject-no-slop-line.sh`, `inject-no-slop-reminder.sh`, `downscale-phone-screenshots.sh`, `record-phone-captures.sh`, `socket-guard.mjs`.
- Keyed on the session instead of the run: `mark-skill-read.sh` and `require-skill-for-file.sh` use `AGENT_TASK_GID` in a run and `sess-<session_id>` otherwise, so the all-scope rows of the file gate apply in chat too.
- Keyed on a different variable: `block-simctl-booted.sh` and `require-maestro-device.sh` gate on `AGENT_SIM_UDID` (slot sessions), `spec-read-gate.sh` and `spec-read-receipt.sh` on `ORCH_SLUG`, `compact-ground-truth.sh` on `ORCH_TASK` plus `ORCH_SLUG`.
- Stricter than the env var: `mark-agent-authored-asana.sh` and `record-own-asana-story.sh` call `orch-run-context.sh`, which requires an in-flight run (env var plus a live tmux pane), because retired and chat-fork sessions keep `AGENT_TASK_GID`.
- `inject-run-context.sh` fires for a run (`AGENT_TASK_GID`) or for a persistent anchor session, and exits silently otherwise.

## Run-lifecycle gates

| Script | Event / matcher | What it does | What it prevents |
|---|---|---|---|
| `require-completion-judgment.sh` | PreToolUse / Bash | Runs the completion judge headless outside the run and blocks with exit 2 on a failing verdict | A run declaring Complete, creating a PR, or setting `blocked=Yes` on its own self-assessment |
| `require-followup-scope-on-complete.sh` | PreToolUse / Bash | Blocks `update-status.sh Complete` unless a fresh followup-scope marker matches the live newest comment and carries zero blocking GitHub threads | Re-Completing past operator comments or open review threads a compacted session cannot remember |
| `require-plan-before-developing.sh` | PreToolUse / Bash | Blocks the Planning to Developing transition until the ingestion marker and a `plan-<gid>-*.md` exist | Planning past task attachments and skipping the plan document entirely |
| `pre-pr-gate.sh` | PreToolUse / Bash | Blocks `pr-create.sh` with exit 2 until in-app test evidence exists, and injects a duplicate-utility scan as additionalContext | Opening a PR with no proof the change ran in the app, and re-adding a helper the repo already has |
| `require-subtasks-for-multi-repo-pr.sh` | PreToolUse / Bash | Blocks a `pr-create.sh --asana-attach` execution when the worktree root holds more than one repo with commits ahead of base | Flat-attaching a multi-repo PR set onto the parent task instead of subtask-per-PR |
| `no-push-after-complete.sh` | PreToolUse / Bash | Blocks branch and PR mutations once the task is at `agent_status = Complete`, with a 30 minute operator-present carve-out | Pushing new heads past the finalize gate's snapshot, so review bots re-run with nobody watching |
| `require-force-land-rationale.sh` | PreToolUse / Bash | Blocks `gh pr merge --admin` unless a per-PR rationale marker under 6 hours old exists | An admin merge that no human approved and no PR comment explains |
| `require-tdd-current.sh` | PreToolUse / Bash | On a TDD-flagged task, blocks Complete while the committed doc fingerprint is older than HEAD's code tree | Shipping a design doc that still describes a previous phase's implementation |
| `ensure-tdd-pr-link.sh` | PreToolUse / Bash | On Complete, resolves the TDD branch URL once and appends it as the first section of every PR body that lacks it, then allows | Reviewers reading a PR with no pointer to the design doc written after the body was built |
| `require-continuation-or-block.sh` | Stop / `*` | Returns `decision:block` on a premature turn end, up to 3 times, then writes `/tmp/agent-stuck-<gid>.md` and allows | A headless run ending its turn to ask a question or hand off, stalling and squatting a slot |
| `no-interactive-prompt.sh` | PreToolUse / AskUserQuestion | Denies outright with exit 2 and a pick-the-default message | An interactive prompt hard-stalling a run with no human to answer it |
| `no-self-respawn.sh` | PreToolUse / Bash, ScheduleWakeup, CronCreate | Blocks self-wake tools and `claude --resume`/`-p`/backgrounded `claude`/`/loop` | The fork-storm vector, and backgrounding a wait so the turn ends before the work does |
| `block-upfront-conflict-probe.sh` | PreToolUse / Bash | Blocks typed `gh` commands fetching `mergeable` or `mergeStateStatus` | Discovering and narrating PR conflicts before landing, and rebasing mid-review to "fix" them |
| `guard-piped-watcher-scripts.sh` | PreToolUse / Bash | Rewrites a piped watcher-helper call by dropping pure-truncation stages, and blocks when the pipe is not droppable | A status write silently failing its setgid in a subshell while the agent burns retries |

## Raw-API gates

| Script | Event / matcher | What it does | What it prevents |
|---|---|---|---|
| `block-raw-asana-api.sh` | PreToolUse / Bash | Blocks HTTP-client invocations against `app.asana.com/api`, exempting companion scripts by path and attachment binaries | A hand-rolled task fetch that never walks attachments or subtasks and plans past the evidence |
| `block-raw-gh-writes.sh` | PreToolUse / Bash | Blocks non-draft `gh pr create`, `gh pr comment`/`review`, prose-bearing `gh pr edit`, and `gh api` writes to comment and review endpoints | Bypassing the test-evidence gate, the prose lint, and the addressed-marker arithmetic in one typed command |
| `block-raw-thread-resolve.sh` | PreToolUse / Bash | Blocks raw `resolveReviewThread` GraphQL mutations outside the sanctioned script directories | Resolving a review thread with no in-thread reply, which leaves the record audit-silent |
| `git-history-gate.sh` | PreToolUse / Bash | Routes commits to `lint-commit.sh`, gates pushes and autosquashes on the review-mode oracle, and honors an operator rewrite note with a `Targets:` line | Raw commits skipping lint, mid-review squashes destroying the reviewer's delta, and per-push bot review billing |
| `nudge-asana-mcp.sh` | PreToolUse / `mcp__.*__(get_task\|search_tasks\|...)` | Denies unscoped Asana MCP reads and attaches a pointer to scoped re-calls and local scripts | Oversized payloads blowing the tool-result token cap, and hand-rolled task-to-PR walks that miss attachment-linked PRs |
| `socket-guard.mjs` | PreToolUse / Bash | Denies a bare `npm`/`npx`/`pnpm`/`yarn` in command position via `permissionDecision: deny` | Package-manager commands running outside the `sfw` network sandbox wrapper |

## Authoring and file gates

| Script | Event / matcher | What it does | What it prevents |
|---|---|---|---|
| `require-skill-for-file.sh` | PreToolUse / Bash and Write, Edit | Matches the target path against a glob-to-skill table and denies with the skill body inlined | Editing an AGENTS.md, CHANGELOG.md, skill, rule, companion script, hook (site-orch's included) or `~/.claude/settings.json` without the owning contract in context |
| `require-skill-read-for-scripts.sh` | PreToolUse / Bash | Requires the owning skill's read marker (or a one-shot phase slice) before a `skills/<name>/scripts/*.sh` execution, delivering the body on deny | Running one step of a skill's contract bare, without the contract around it |
| `spec-read-gate.sh` | PreToolUse / Bash | Denies reading a site-orch task spec through command stdout (`gh issue view`, unredirected `gh pr diff`, `cat`/`head`/`sed` on the spec files) | Reasoning from an issue or diff silently truncated at the shell tool's ~20 KB output cap |

## Prose and output gates

| Script | Event / matcher | What it does | What it prevents |
|---|---|---|---|
| `lint-md-on-write.sh` | PreToolUse / Bash and Write, Edit | Runs the shared no-slop lint on markdown writes outside the internal allowlist, full-file for new files and fragment-only for edits, plus locale strings files in `--strings` mode | Prose reaching `gh --body-file` unlinted, since the posting boundary sees only `$(cat file)` |
| `slack-prose-gate.sh` | PreToolUse / Slack MCP send, draft, schedule, canvas | Denies on HARD lint findings and attaches a brevity nudge as additionalContext above the length threshold | Em dashes, banned vocabulary, and Claude session links leaving the team on Slack |
| `require-clean-run-report.sh` | PreToolUse / Bash | Lints the report file at the `--attach-file` boundary against the live template: reversibility annotations, em dashes, missing sections, unlabeled hack-forced frames, a second report doc per segment | Report form reverting to remembered shape after compaction, and one segment splintering into parallel report docs |
| `mark-agent-authored-asana.sh` | PreToolUse / `mcp__claude_ai_Asana__.*` | Rewrites comment and notes fields of an in-flight run to carry the authorship markers, idempotently | Agent-written Asana prose being read by the next run as operator instruction |

## Device and simulator gates

| Script | Event / matcher | What it does | What it prevents |
|---|---|---|---|
| `block-simctl-booted.sh` | PreToolUse / Bash | Blocks `simctl ... booted` when `AGENT_SIM_UDID` is set | Installing, launching, or logging against another concurrent slot's simulator |
| `require-maestro-device.sh` | PreToolUse / Bash, `mcp__maestro__.*`, Write, Edit | Classifies the target platform per call, then requires an iOS `--device $AGENT_SIM_UDID` on a booted sim plus `--driver-host-port`, or an attached adb serial on Android | Driving the wrong device on a cross-slot re-latch, and blocking an Android drive over an unbooted iOS sim |
| `block-coordinate-taps.sh` | PreToolUse / Bash, Write, Edit, `mcp__maestro__.*` | Blocks maestro `tapOn` with `point:` in flows, inline yaml, and heredocs, with a `/tmp/agent-coordtap-<gid>.md` escape hatch | Grinding coordinates instead of adding a testID, which is a JS-only change |
| `require-playbook-before-drive.sh` | PreToolUse / Bash, `mcp__maestro__.*` | Blocks every maestro drive path until the sim-testing playbook marker exists, and carries the flow-library index in the deny | Driving the sim without the flow library, then re-implementing flows that already exist |
| `block-sim-wipe.sh` | PreToolUse / Bash | Blocks `simctl uninstall` and `simctl erase` invocations in command position | Deleting the app data container and the logged-in test account, which needs a manual login to restore |
| `require-bundle-triage.sh` | PreToolUse / Bash | Denies hand-written `RCT_jsLocation` pins, and requires a `bundle-ownership.sh` triage under 15 minutes old before a `--reset-cache` or metro-cache nuke | Wedging the packager by hand-pinning mid-debug, and nuking caches for what is actually a wrong-port fetch |
| `downscale-phone-screenshots.sh` | PreToolUse / Read | Rewrites the Read to a cached half-size copy when the capture ledger or a phone glob proves the frame came from a simulator or device | ~2,500 tokens per phone screenshot re-sent on every model call until the next compaction |

## Context injection and receipts

| Script | Event / matcher | What it does | What it prevents |
|---|---|---|---|
| `inject-run-context.sh` | SessionStart / `*` | Injects live ground truth per session kind: Asana state, comments past the followup watermark, attempt log, PR state, slot env, or an anchor's open-threads ledger | Acting on summary-flattened beliefs in the first turns after a compaction or resume |
| `compact-ground-truth.sh` | SessionStart / compact | Re-reads task number, PR, branch, and stage live from the board and repo for site-orch runs, reporting "unavailable" on any failed lookup | A compaction summary dropping identifiers, negative instructions, and whether a fact was verified |
| `inject-no-slop-reminder.sh` | SessionStart / `*` | Prints the full no-slop rule block into session context | Chat prose drifting after compaction drops the skill from context |
| `inject-no-slop-line.sh` | UserPromptSubmit / `*` | Prints a one-line no-slop reminder at the recency end of context, about 30 tokens per turn | Instruction decay over a long session, where the SessionStart block ages toward the buried end |
| `mark-skill-read.sh` | PostToolUse / Read, Bash, Skill | Records line ranges per SKILL.md or reference slice and writes the marker only once every line is covered | A partial read crediting a skill and suppressing the gate's deny-with-body delivery |
| `mark-playbook-read.sh` | PostToolUse / Read, Bash | Touches `/tmp/agent-playbook-read-<gid>` when a Read or Bash command touches the sim-testing playbook | The drive gate having no way to tell a real read from a quoted mention |
| `mark-operator-present.sh` | UserPromptSubmit / `*` | Stamps `/tmp/agent-operator-present-<gid>` on human prompts, skipping spawn prompts, watchdog pings, and headless children | The post-Complete push block treating human-directed work in a live session as a headless resume |
| `record-own-asana-story.sh` | PostToolUse / `mcp__claude_ai_Asana__add_comment` | Appends the story gid of a run's own comment on its own task to `/tmp/agent-own-stories-<gid>` | The Complete gate mistaking the run's own completion comment for new operator scope |
| `record-phone-captures.sh` | PostToolUse / Bash | Writes where a `simctl io ... screenshot` or `adb exec-out screencap` landed into the capture ledger | The Read rewrite missing ad-hoc captures that no filename glob can cover |
| `record-file-writes.sh` | PreToolUse / Bash (stamp) and PostToolUse / Write, Edit, NotebookEdit, Bash | Appends `{ts, session, agent, path, via}` to `~/.local/state/agent-watcher/write-ledger.jsonl` as each write happens; `via` is `tool`, `bash` (changed during the call and named by the command) or `bash-window` (changed, never named). Format and roots live in `lib/write-ledger.sh` | convention-sync shipping a file without knowing which session wrote it, which transcripts cannot answer (a Read names a path as much as an Edit does, and an interpreter write names none) |
| `spec-read-receipt.sh` | PostToolUse / Read | Appends one JSON receipt per Read under the site-orch task spec dir to `.reads.jsonl` | Routing a task before the issue, comments, and diff were read in full |

## Operator hold

| Script | Event / matcher | What it does | What it prevents |
|---|---|---|---|
| `operator-hold-prompt.sh` | UserPromptSubmit / `*` | Classifies a human prompt as stop, release, hold, or steer, sets or clears the hold, prints one context line, and writes a one-shot judge waiver on a completion or stop order | A typed question being read as a steer and the run rolling past it |
| `operator-hold-gate.sh` | PreToolUse / Bash | While a hold is active, blocks status transitions, pushes, PR creation, and landing, and allows reads, edits, commits, builds, and drives | Run momentum overtaking the human who just interrupted it |

## Registered but living outside the synced trees

Four registrations point at paths that convention-sync does not mirror. A fresh machine bootstrapped from the edge-dev-agents repo gets the registration but not the script, and a missing hook script is silently a no-op.

| Path | Registration | Source |
|---|---|---|
| `~/git/site-orch/hooks/spec-read-gate.sh` | PreToolUse / Bash | site-orch repo, cloned separately |
| `~/git/site-orch/hooks/spec-read-receipt.sh` | PostToolUse / Read | site-orch repo, cloned separately |
| `~/git/site-orch/hooks/compact-ground-truth.sh` | SessionStart / compact | site-orch repo, cloned separately |
| `~/.agent-tools/socket-guard.mjs` | PreToolUse / Bash | `~/.agent-tools`, not a synced tree |

The three site-orch hooks no-op without `ORCH_SLUG`, so their absence costs nothing outside site-orch runs. `socket-guard.mjs` fires in every session, so on a machine missing it, bare `npm`/`npx`/`pnpm`/`yarn` runs unsandboxed with no signal.

## On disk but not registered

Four files under `~/.config/agent-watcher/hooks/` appear in no registration row.

| File | Verdict |
|---|---|
| `cmd-executes.sh` | Shared library. A Node helper answering "does this command EXECUTE the named script", called by `operator-hold-gate.sh`, `block-raw-asana-api.sh`, `block-raw-thread-resolve.sh`, `block-raw-gh-writes.sh`, `require-completion-judgment.sh`, `require-subtasks-for-multi-repo-pr.sh`, and `git-history-gate.sh`. Never a hook. |
| `strip-cmd-mentions.sh` | Shared library. Blanks heredoc bodies and quoted spans while preserving byte length, so trigger matching sees only real invocations. Called by 30 hooks plus `lib/shell-word-resolve.sh` and `lib/phone-capture-ledger.sh`. Never a hook. |
| `require-concession-validation.sh` | Live compatibility shim, 6 lines, `exec`s `require-completion-judgment.sh`. Sessions spawned before the 2026-09-10 settings change still carry the old path in their startup snapshot, so it must stay until those sessions are gone. The original is preserved at `hooks/retired/require-concession-validation.sh`. |
| `retired/require-block-validation.sh` | Retired, never registered. A PreToolUse gate on `update-status.sh --blocked yes` against a `/tmp/agent-blocker-verdict-<gid>.json` verdict. The block path it guarded is the completion judge's `block` event (`require-completion-judgment.sh`). Kept for history only. |
