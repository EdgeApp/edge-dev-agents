---
name: bugbot
description: Address Cursor Bugbot PR review findings until the PR is actually clean. Runs one scan cycle (check bugbot's check-run status on HEAD, classify each unresolved bugbot thread, fix valid ones with fixup commits, push, reply+resolve) and — on Claude Code — self-schedules a 5-minute recurring cycle that stops automatically when bugbot reports the PR clean. On Cursor/Codex the recurring schedule is set up once via Automations and the skill's cycle runs identically on each fire. Only handles `cursor[bot]` feedback — leaves human and other-bot threads for /pr-address. Use when the user says "address bugbot", "handle bugbot comments", or pastes a PR URL and asks about bugbot status.
compatibility: Requires git, gh. Composes with pr-address, lint-commit.sh, git-branch-ops.sh. Self-schedules on Claude Code via CronList/CronCreate/CronDelete tools when available.
metadata:
  author: j0ntz
---

<goal>Get a PR to bugbot-clean state end-to-end: run one scan cycle now, self-arm a recurring schedule when bugbot hasn't yet signed off, and self-disarm when it has.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-scripts">Do NOT call `gh` directly. Use `~/.cursor/skills/bugbot/scripts/bugbot.sh` for bugbot check-run queries, `~/.cursor/skills/pr-address/scripts/pr-address.sh` for all thread operations (fetch, fetch-thread, reply, resolve-thread, ensure-branch), and `~/.cursor/skills/pr-finalize-fixups.sh` for the post-fixup autosquash decision (SHARED with /pr-address — policy lives there, not here).</rule>
<rule id="no-script-bypass">If a companion script fails, report the error and STOP. Do NOT fall back to raw `gh`, `curl`, or other workarounds.</rule>
<rule id="cursor-bot-only">Only process threads whose first comment's author login is `cursor[bot]` (the literal `[bot]` suffix is required). Skip human threads, other-bot threads, and reviewer threads — those belong to `/pr-address`.</rule>
<rule id="conclusion-is-not-clean">`check-run.conclusion: neutral` does NOT mean the PR is clean. `neutral` means bugbot posted findings that are non-blocking. ALWAYS combine check-run `status == "completed"` with "0 unresolved `cursor[bot]` threads" before declaring clean.</rule>
<rule id="require-paginate">When the companion scripts query bot comments, they already pass `--paginate` — PRs with >30 bot comments miss newest without it. Do not implement your own comment queries; delegate.</rule>
<rule id="reply-before-resolve">ALWAYS reply explaining how a thread was addressed (fix SHA for valid, invalidity class for invalid) BEFORE calling `resolve-thread`. No silent resolutions.</rule>
<rule id="commit-via-script">Fixups MUST use `~/.cursor/skills/lint-commit.sh --no-reorder -m "fixup! {target-headline}" [files...]`. Do not run `git commit` directly and do not manually run eslint — the commit script handles it.</rule>
<rule id="fixup-target-headline">Before each fixup, run `git log --oneline -- <changed-file>` to find the commit that introduced the behavior being fixed and use its exact headline (not a generic one). The fixup must target a real commit on the branch so the later autosquash resolves correctly.</rule>
<rule id="no-summary-comment">Do NOT post a top-level PR summary comment. Reply inline on each thread only. The scheduler consumes per-cycle status from stdout; extra body comments add noise on recurring runs.</rule>
<rule id="self-schedule-on-claude-code">When `CronList`, `CronCreate`, and `CronDelete` tools are available (Claude Code), the skill MUST manage its own recurring schedule per Step 5: arm a 5-minute cron on any non-clean outcome if one isn't already armed; delete any matching cron on clean/skipped. On tools without those APIs (Cursor/Codex), skip Step 5 — the user configures their tool's Automation manually per `<scheduling>`.</rule>
<rule id="one-cron-per-pr">Never arm a second cron for a `(owner, repo, pr)` tuple that already has one. Always `CronList` first and match by the prompt substring; only `CronCreate` if no existing cron matches.</rule>
<rule id="script-timeouts">Set `block_until_ms: 60000` when invoking `bugbot.sh` or `pr-address.sh` — GitHub API calls can take up to 30s and bugbot's `--paginate` query may take longer on busy PRs.</rule>
<rule id="this-file-wins">If any other instruction conflicts with this file, **this file wins** for `bugbot`.</rule>
</rules>

<arguments>
Accepts either form:
- `owner/repo#pr` (e.g. `EdgeApp/edge-reports-server#207`)
- Discrete flags: `--owner <o> --repo <r> --pr <n>`

Required. Parse and assign to `<OWNER>`, `<REPO>`, `<NUMBER>` for the steps below.
</arguments>

<step id="0" name="Ensure correct branch">
Before any other work, ensure the PR's branch is checked out and up to date. Delegate to pr-address:

```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh ensure-branch \
  --owner <OWNER> --repo <REPO> --pr <NUMBER>
```

Output includes `BRANCH_READY`, `STASHED`, and (if switched) `PREVIOUS_BRANCH`. If `STASHED=true`, inform the user that changes were stashed on the previous branch.
</step>

<step id="1" name="Fetch HEAD SHA">
Resolve the full 40-char SHA for the PR's head branch:

```bash
HEAD_SHA=$(git rev-parse origin/<BRANCH>)
HEAD_SHORT=${HEAD_SHA:0:10}
```

If you don't already know `<BRANCH>`, derive it from pr-address's ensure-branch output or:

```bash
BRANCH=$(gh pr view <NUMBER> --repo <OWNER>/<REPO> --json headRefName --jq '.headRefName')
```
</step>

<step id="2" name="Query bugbot check-run">
Get bugbot's authoritative state on the current HEAD:

```bash
~/.cursor/skills/bugbot/scripts/bugbot.sh check-run-status \
  --owner <OWNER> --repo <REPO> --sha "$HEAD_SHA"
```

Returns compact JSON: `{"status":"<s>","conclusion":"<c>","sha":"<short>"}`.

- `status` ∈ { `queued`, `in_progress`, `completed`, `none` }
- `conclusion` ∈ { `success`, `neutral`, `failure`, `skipped`, `null` }
- `status: "none"` means no `Cursor Bugbot` check-run exists for this SHA (scan not yet triggered).

If the script exits 2 with `PROMPT_GH_AUTH`, prompt the user: "`gh` CLI is not authenticated. Please run: `gh auth login`". Then STOP.
</step>

<step id="3" name="Interpret — priority-ordered decision table">
Pick the FIRST matching row. Set an internal `OUTCOME` variable to one of `waiting` | `no-check-run` | `skipped` | `clean` | `findings`. Then run Step 4 if `OUTCOME == findings`, and ALWAYS run Step 5 last to manage the recurring schedule.

1. **`status == "queued"` OR `status == "in_progress"`** → `OUTCOME = waiting`.
   Status line: `waiting for bugbot to finish scanning <HEAD_SHORT>`.
   Do NOT fetch threads, commit, push, reply, or resolve anything.

2. **`status == "none"`** → `OUTCOME = no-check-run`.
   Status line: `no bugbot check-run on <HEAD_SHORT> yet`.
   Do NOT act. (Bugbot may start scanning shortly.)

3. **`status == "completed"` AND `conclusion == "skipped"`** → `OUTCOME = skipped`.
   Status line: `bugbot skipped <HEAD_SHORT>`.
   Treat as clean for this SHA — bugbot explicitly declined to scan (often because the diff only changed docs/config).

4. **`status == "completed"` (any other conclusion) AND 0 unresolved `cursor[bot]` threads** → `OUTCOME = clean`.
   Verify unresolved count with `pr-address.sh fetch` (see Step 4a).
   Status line: `bugbot clean on <HEAD_SHORT>`.

5. **`status == "completed"` AND >0 unresolved `cursor[bot]` threads** → `OUTCOME = findings`.
   Proceed to Step 4 to address them.

**Critical**: Row 4 MUST combine the `completed` status with a live thread-count check. `conclusion: neutral` alone can mean "posted findings, non-blocking" — declaring clean on conclusion-only would silently skip real issues.
</step>

<step id="4" name="Address unresolved bugbot findings">

<sub-step id="4a" name="Fetch unresolved threads">
```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh fetch \
  --owner <OWNER> --repo <REPO> --pr <NUMBER>
```

The JSON output includes a `threads` array. Filter to threads whose first comment's author is `cursor[bot]` — that filter is the bot-only scope this skill owns. For each such thread, continue below.
</sub-step>

<sub-step id="4b" name="Per-thread: fetch body and classify">
For each cursor[bot] thread, fetch the full body:

```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh fetch-thread \
  --owner <OWNER> --repo <REPO> --pr <NUMBER> \
  --thread-id "<threadId>"
```

Inside the `<!-- DESCRIPTION START -->...<!-- DESCRIPTION END -->` markers is the finding. Classify it by running through the `<classification-heuristics>` block (below) in order. The DEFAULT is "valid" — invalidity requires a cited heuristic match.
</sub-step>

<sub-step id="4c" name="Valid: apply fixups (serialized, no push yet)">
For each thread classified valid, in order:

1. Read the affected file and apply the fix via Edit/Write.
2. Locate the fixup target:
   ```bash
   git log --oneline -- <path>
   ```
   Pick the commit that introduced the behavior being fixed. Use its exact headline.
3. Typecheck first if the repo has one (`yarn build.types`, `yarn tsc`, `tsc`). Skip if unavailable.
4. Commit as a fixup:
   ```bash
   ~/.cursor/skills/lint-commit.sh --no-reorder -m "fixup! <target-headline>" <files...>
   ```
5. Capture the new fixup SHA: `git rev-parse --short HEAD`. Record a `{threadId, commentId, fixupSha}` entry so Step 4e can reply with the correct SHA per thread.

Do NOT push inside this loop — Step 4d pushes once after all fixups land.
</sub-step>

<sub-step id="4d" name="Push all fixups once">
After every valid thread has been committed:

```bash
~/.cursor/skills/git-branch-ops.sh push
```

One non-force push makes all fixup SHAs visible to GitHub so Step 4e's reply bodies render as commit links. Skip this sub-step if Step 4c produced zero fixups (all threads were invalid).
</sub-step>

<sub-step id="4e" name="Reply and resolve every thread (valid and invalid)">
For each processed thread, post one reply then resolve. Replies and resolves for independent threads are safe to parallelize (multiple Bash tool calls in one message).

Valid threads — reply body cites the fixup SHA from Step 4c's record:
```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh reply \
  --owner <OWNER> --repo <REPO> --pr <NUMBER> \
  --comment-id <numeric_id> \
  --body "Valid — fixed in <fixup_sha>. <one-sentence description of the fix and file:line>."
```

Invalid threads — reply body cites the matched heuristic:
```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh reply \
  --owner <OWNER> --repo <REPO> --pr <NUMBER> \
  --comment-id <numeric_id> \
  --body "<one-sentence explanation naming the heuristic: self-invalidating / pre-existing intentional / already-addressed / duplicate / wrong about the API>. <brief evidence citing code paths, author comments, or sibling threads>."
```

Then resolve:
```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh resolve-thread --thread-id "<threadId>"
```
</sub-step>

<sub-step id="4f" name="Finalize: autosquash if no external human reviewers">
Delegate to the shared finalize helper. Identical call site as `/pr-address` Step 4 — policy lives in the script so the two skills never drift:

```bash
~/.cursor/skills/pr-finalize-fixups.sh --owner <OWNER> --repo <REPO> --pr <NUMBER>
```

Output is one line of JSON:
- `{"autosquashed": true, "newHead": "<sha>"}` — history rewritten, force-pushed. Use `newHead` in the Step 4g status line.
- `{"autosquashed": false, "reason": "has external human reviewers", "reviewers": [...]}` — fixups preserved; use the Step 4d push's HEAD for Step 4g.

If the script exits non-zero, the autosquash hit a conflict. Do NOT emit a status line or run Step 5 — report the error and STOP so the user can resolve manually. An armed cron (from a previous cycle) will keep firing; the next cycle with a clean tree will retry.

Skip this sub-step entirely if Step 4c produced zero fixups.
</sub-step>

<sub-step id="4g" name="Status line for the findings outcome">
Set the final status line based on what happened in 4c–4f:

- `bugbot addressed <N> thread(s) on <HEAD_SHORT>; autosquashed to <NEW_HEAD>` — fixups pushed and squashed.
- `bugbot addressed <N> thread(s) on <HEAD_SHORT>; new HEAD <NEW_HEAD>` — fixups pushed, autosquash skipped (human reviewers present).
- `bugbot addressed <N> thread(s) on <HEAD_SHORT>; no fixups` — all threads were invalid.

The new HEAD needs a fresh bugbot scan. Step 5 keeps the cron armed so the next cycle handles it.
</sub-step>
</step>

<step id="5" name="Manage recurring schedule (Claude Code only)">
This step runs AFTER every other step, on every outcome. Its job: arm a 5-minute recurring cycle on non-clean outcomes and tear it down on clean outcomes, so interactive `/bugbot` invocations Just Work without the user composing with `/loop`.

**If `CronList`, `CronCreate`, and `CronDelete` tools are NOT available** (Cursor, Codex, agent harnesses without Claude Code scheduling): skip this step entirely. Emit the status line from Step 3/4f and exit. The user's Cursor/Codex Automation (configured per `<scheduling>`) keeps firing until they disable it when they see the clean status.

**If those tools ARE available** (Claude Code):

1. Build the cron prompt string: `/bugbot <owner>/<repo>#<pr>` (matching exactly what the user invoked). This string is the unique key for finding/removing this PR's cron.

2. Query existing crons:
   ```
   CronList()
   ```
   Find entries whose `prompt` contains the cron prompt string from (1). Save any matching job IDs into `EXISTING_IDS`.

3. Act on `OUTCOME`:

   - `OUTCOME == clean` OR `OUTCOME == skipped`:
     For each id in `EXISTING_IDS`: `CronDelete(id)`.
     Append ` · monitor stopped` to the status line if any were deleted, or ` · no monitor was armed` if not.

   - `OUTCOME == waiting` OR `OUTCOME == no-check-run` OR `OUTCOME == findings`:
     If `EXISTING_IDS` is empty:
     ```
     CronCreate(cron: "*/5 * * * *", prompt: "<cron prompt from step 1>", recurring: true)
     ```
     Append ` · monitoring every 5m (job <new_id>)` to the status line.

     If `EXISTING_IDS` is non-empty: do NOT CronCreate. Append ` · continuing monitor (job <existing_id>)` to the status line.

4. Emit the final status line as the last stdout line of the cycle.

**Why this design**:
- Interactive `/bugbot owner/repo#N` invocation arms a monitor and returns.
- Subsequent cron fires find the existing cron and skip re-arming.
- Clean cycle deletes the cron cleanly; user sees `bugbot clean on <SHA> · monitor stopped`.
- No piling-up of crons; no orphan schedules on clean.
- Matching by prompt-substring (not job id) means the skill can tear down crons even when the current invocation came from the cron itself.
</step>

<classification-heuristics description="Invalidity patterns observed in real bugbot runs. A finding is VALID by default; match one of these with cited evidence to mark it INVALID.">

<pattern id="self-invalidating" name="Self-invalidating">
The bot's own description contains language like "Actually the code looks correct on closer inspection", "appears consistent", "Upon closer inspection, this appears consistent", or "This is not the main issue though". The bot's own analysis has concluded no real bug — cite the exact sentence in your reply.
</pattern>

<pattern id="pre-existing-intentional" name="Pre-existing intentional code">
The flagged code:
1. Has a source-code comment documenting the author's intent (e.g. `// Only EVM-style addresses are contracts`), AND
2. Was NOT introduced by any fixup in this session (`git log -- <file>` shows the hunk pre-dates the current branch work).

Reply citing the author comment and the commit that introduced it.
</pattern>

<pattern id="already-addressed" name="Already-addressed stance">
A reply on this same thread, or on a sibling thread about the same concern, has already documented the position (e.g. "keeping per-tx async for backfill-script reuse", "throw-on-unknown is intentional to force mapping updates"). Reference the earlier reply's thread ID or comment ID in the new reply so the reviewer can trace the rationale.
</pattern>

<pattern id="duplicate" name="Duplicate">
Same file and same concern as a `cursor[bot]` thread resolved earlier in this or an immediately prior cycle. Cite the resolved thread's ID and the fixup SHA (if any) that addressed it.
</pattern>

<pattern id="wrong-about-api" name="Wrong about the API">
The finding asserts an API shape or data-model behavior that contradicts what earlier commits on the branch demonstrate (e.g. "baseCurrency on Moonpay sell is fiat" when the original sell implementation shows it is crypto). Verify by reading the commit that introduced the handling and cite that commit in the reply. Do NOT accept a finding that rewrites author intent without evidence.
</pattern>

</classification-heuristics>

<scheduling description="How the recurring schedule is set up per tool. On Claude Code the skill self-arms; on Cursor/Codex the user configures their Automations panel once.">

<tool name="Claude Code (default — self-armed)">
Just invoke the skill — it arms its own schedule on non-clean outcomes and tears it down on clean outcomes (see Step 5).

```
/bugbot <owner>/<repo>#<pr>
```

First cycle runs immediately. If bugbot hasn't finished / has findings, a session-scoped cron is armed automatically (`*/5 * * * *`). Each cron fire is another `/bugbot` cycle. The cycle that reaches clean deletes its own cron and reports `bugbot clean on <SHA> · monitor stopped`.

Manual cadence override: `/loop 15m /bugbot ...` still works — Step 5 skips arming a new cron when it finds the existing `/loop`-created one, so the two don't fight.
</tool>

<tool name="Claude Code (durable cloud schedule)">
For survive-across-sessions monitoring (e.g. you want bugbot polling overnight while you're logged off):

```
/schedule every 5 minutes: /bugbot <owner>/<repo>#<pr>
```

Each fire re-runs the skill. Step 5's self-teardown logic uses `CronDelete` which only covers session-scoped crons — for `/schedule`-created ones, cancel from `/schedule list` when you see the clean status.
</tool>

<tool name="Cursor (Automations)">
In the Automations panel, create a recurring Automation:
- Schedule: cron `*/5 * * * *`
- Prompt: `/bugbot <owner>/<repo>#<pr>`

The skill's Step 5 is a no-op in Cursor (no CronList API to the agent), so the Automation keeps firing until you disable it. Each cycle's status line tells you when it's safe to disable.
</tool>

<tool name="Codex (Automations)">
Ask Codex: "Create a standalone automation that runs every 5 minutes with prompt `/bugbot <owner>/<repo>#<pr>`." Same caveat as Cursor — the skill doesn't self-teardown; disable the automation when the clean status appears.
</tool>

</scheduling>

<edge-cases>
<case name="Branch has uncommitted changes">Rely on `pr-address.sh ensure-branch` — it stashes automatically and reports `STASHED=true`. Surface that to the user so they know where their changes are.</case>
<case name="Check-run is failure">Same handling as `neutral` with threads — bugbot just marked the findings blocking-severity rather than informational. Proceed through Step 4.</case>
<case name="Bugbot re-ran and posted on an older SHA">After a push, the previous HEAD's check-run no longer matters — always query the LATEST HEAD SHA. The script's `sort_by(.started_at) | last` logic handles cases where bugbot posts multiple runs on the same SHA.</case>
<case name="Thread from a non-cursor[bot] author">Skip. This skill is scoped to bugbot. For mixed human/bot reviews, run `/pr-address` separately.</case>
<case name="Empty PR / no check-runs ever">Step 2 returns `status: "none"`. Step 3 row 2 applies — report and wait. Bugbot has up to ~1 minute before it enqueues a scan.</case>
<case name="Script exit 2 (PROMPT_GH_AUTH / PROMPT_GH_INSTALL)">Prompt the user to install/authenticate `gh`, STOP. Do not fall back to curl or manual API calls.</case>
<case name="Cron tools are deferred / not loaded in the agent context">On Claude Code with `CronList`, `CronCreate`, `CronDelete` deferred, load them via `ToolSearch` with `query: "select:CronCreate,CronList,CronDelete"` before running Step 5. If loading fails, fall back to the Cursor/Codex path: emit the status line without scheduling and let the caller manage the Automation manually.</case>
<case name="PR branch was deleted (PR merged/closed)">`ensure-branch` will fail. If Step 5 has already armed a cron, CronDelete it before exiting. Report the error and STOP — the scheduler no longer has anything useful to do.</case>
</edge-cases>
