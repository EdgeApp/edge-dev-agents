---
name: bugbot
description: Address Cursor Bugbot PR review findings for one scan cycle. Checks bugbot's check-run status on HEAD, classifies each unresolved bugbot thread as valid or invalid, fixes valid ones with fixup commits, pushes, and replies+resolves each thread. Reports a single grep-able status line so the caller's scheduler (Cursor Automations, Codex Automations, Claude Code /loop or /schedule) can decide whether to run again. Use when the user says "address bugbot", "handle bugbot comments", or pastes a PR URL and asks about bugbot status. Only handles `cursor[bot]` feedback — leaves human and other-bot threads for /pr-address.
compatibility: Requires git, gh. Composes with pr-address, lint-commit.sh, git-branch-ops.sh.
metadata:
  author: j0ntz
---

<goal>Run one Cursor Bugbot scan cycle on a PR: read the check-run, address valid findings as fixup commits, and report status so the caller's scheduler can decide whether to loop.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-scripts">Do NOT call `gh` directly. Use `~/.cursor/skills/bugbot/scripts/bugbot.sh` for bugbot check-run queries and `~/.cursor/skills/pr-address/scripts/pr-address.sh` for all thread operations (fetch, fetch-thread, reply, resolve-thread, ensure-branch).</rule>
<rule id="no-script-bypass">If a companion script fails, report the error and STOP. Do NOT fall back to raw `gh`, `curl`, or other workarounds.</rule>
<rule id="cursor-bot-only">Only process threads whose first comment's author login is `cursor[bot]` (the literal `[bot]` suffix is required). Skip human threads, other-bot threads, and reviewer threads — those belong to `/pr-address`.</rule>
<rule id="conclusion-is-not-clean">`check-run.conclusion: neutral` does NOT mean the PR is clean. `neutral` means bugbot posted findings that are non-blocking. ALWAYS combine check-run `status == "completed"` with "0 unresolved `cursor[bot]` threads" before declaring clean.</rule>
<rule id="require-paginate">When the companion scripts query bot comments, they already pass `--paginate` — PRs with >30 bot comments miss newest without it. Do not implement your own comment queries; delegate.</rule>
<rule id="reply-before-resolve">ALWAYS reply explaining how a thread was addressed (fix SHA for valid, invalidity class for invalid) BEFORE calling `resolve-thread`. No silent resolutions.</rule>
<rule id="commit-via-script">Fixups MUST use `~/.cursor/skills/lint-commit.sh --no-reorder -m "fixup! {target-headline}" [files...]`. Do not run `git commit` directly and do not manually run eslint — the commit script handles it.</rule>
<rule id="fixup-target-headline">Before each fixup, run `git log --oneline -- <changed-file>` to find the commit that introduced the behavior being fixed and use its exact headline (not a generic one). The fixup must target a real commit on the branch so the later autosquash resolves correctly.</rule>
<rule id="no-summary-comment">Do NOT post a top-level PR summary comment. Reply inline on each thread only. The scheduler consumes per-cycle status from stdout; extra body comments add noise on recurring runs.</rule>
<rule id="no-scheduling-from-skill">Do NOT call `CronCreate`, `/loop`, or any tool-specific scheduling API from within the skill. The caller owns scheduling; this skill is a single cycle only. See `<scheduling>` at the bottom for per-tool setup.</rule>
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

<step id="3" name="Interpret and act — priority-ordered decision table">
Pick the FIRST matching row and follow its action. Do not evaluate later rows.

1. **`status == "queued"` OR `status == "in_progress"`** →
   Output exactly: `waiting for bugbot to finish scanning <HEAD_SHORT>`.
   Do NOT fetch threads, commit, push, reply, or resolve anything. STOP.

2. **`status == "none"`** →
   Output exactly: `no bugbot check-run on <HEAD_SHORT> yet`.
   Do NOT act. STOP. (The scheduler will try again next cycle; bugbot may start scanning shortly.)

3. **`status == "completed"` AND `conclusion == "skipped"`** →
   Output exactly: `bugbot skipped <HEAD_SHORT>`.
   Treat as clean for this SHA — bugbot explicitly declined to scan (often because the diff only changed docs/config). STOP and advise the caller it is safe to disable the scheduler.

4. **`status == "completed"` (any other conclusion) AND 0 unresolved `cursor[bot]` threads** →
   Verify unresolved count with `pr-address.sh fetch` (see Step 4a).
   Output exactly: `bugbot clean on <HEAD_SHORT>`.
   STOP and advise the caller it is safe to disable the scheduler.

5. **`status == "completed"` AND >0 unresolved `cursor[bot]` threads** →
   Proceed to Step 4 to address findings.

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

<sub-step id="4c" name="Valid: apply fixup, push, reply, resolve">
For valid findings:

1. Read the affected file and determine the fix. Apply via Edit/Write.
2. Locate the fixup target:
   ```bash
   git log --oneline -- <path>
   ```
   Pick the commit that introduced the behavior being fixed. Grab its headline (everything after the SHA).
3. Run the typecheck first:
   ```bash
   # For the repo's usual build/type command (e.g. `yarn build.types`, `yarn tsc`, `tsc`). Skip if not available.
   ```
4. Commit as a fixup:
   ```bash
   ~/.cursor/skills/lint-commit.sh --no-reorder -m "fixup! <target-headline>" <files...>
   ```
5. Capture the new fixup SHA (returned by lint-commit.sh or via `git rev-parse --short HEAD`).
6. Push:
   ```bash
   ~/.cursor/skills/git-branch-ops.sh push
   ```
7. Reply on the thread. Use the thread's first-comment numeric id (the `id` field in `fetch-thread`'s `comments[0]`):
   ```bash
   ~/.cursor/skills/pr-address/scripts/pr-address.sh reply \
     --owner <OWNER> --repo <REPO> --pr <NUMBER> \
     --comment-id <numeric_id> \
     --body "Valid — fixed in <fixup_sha>. <one-sentence description of the fix and file:line if relevant>."
   ```
8. Resolve:
   ```bash
   ~/.cursor/skills/pr-address/scripts/pr-address.sh resolve-thread \
     --thread-id "<threadId>"
   ```
</sub-step>

<sub-step id="4d" name="Invalid: reply citing heuristic, resolve">
For invalid findings, NO commit and NO push. Reply citing the specific heuristic:

```bash
~/.cursor/skills/pr-address/scripts/pr-address.sh reply \
  --owner <OWNER> --repo <REPO> --pr <NUMBER> \
  --comment-id <numeric_id> \
  --body "<one-sentence explanation naming the heuristic: self-invalidating / pre-existing intentional / already-addressed / duplicate / wrong about the API>. <brief evidence citing code paths, author comments, or sibling threads>."
```

Then `resolve-thread` as in 4c step 8.
</sub-step>

<sub-step id="4e" name="Batch tool calls within a cycle">
Replies and resolves for independent threads are safe to parallelize (multiple Bash tool calls in one message). Fixup commits must be serialized because they share the working tree and branch state. After all fixups, push once at the end of the cycle rather than after each commit — fewer force pushes, single rebuild trigger on the bugbot side.
</sub-step>

<sub-step id="4f" name="End-of-cycle output">
After processing all threads, output exactly one line:

`bugbot addressed <N> thread(s) on <HEAD_SHORT>; new HEAD <NEW_SHORT>` if you pushed fixups,
or `bugbot addressed <N> thread(s) on <HEAD_SHORT>; no fixups` if all were reply-only.

The new HEAD will need a fresh scan; the caller's next scheduled cycle handles that.
</sub-step>
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

<scheduling description="This skill is a single cycle. Use your tool's native scheduler to run it recurrently. All examples use a 5-minute cadence — bugbot scans typically take 4–7 minutes, so tighter polling just wastes cycles.">

<tool name="Claude Code (session-scoped)">
```
/loop 5m /bugbot <owner>/<repo>#<pr>
```
Stop with `CronDelete <job-id>` when the cycle outputs `bugbot clean on <SHA>` or `bugbot skipped <SHA>`. The `/loop` wrapper prompt can grep for those strings and call `CronDelete` itself.
</tool>

<tool name="Claude Code (durable cloud schedule)">
```
/schedule every 5 minutes: /bugbot <owner>/<repo>#<pr>
```
Cancel from `/schedule list` when the PR is clean.
</tool>

<tool name="Cursor (Automations)">
In the Automations panel, create a recurring Automation:
- Schedule: cron `*/5 * * * *`
- Prompt: `/bugbot <owner>/<repo>#<pr>`
- Disable the Automation manually when the clean report fires.
</tool>

<tool name="Codex (Automations)">
Ask Codex: "Create a standalone automation that runs every 5 minutes with prompt `/bugbot <owner>/<repo>#<pr>`." Disable when clean.
</tool>

</scheduling>

<edge-cases>
<case name="Branch has uncommitted changes">Rely on `pr-address.sh ensure-branch` — it stashes automatically and reports `STASHED=true`. Surface that to the user so they know where their changes are.</case>
<case name="Check-run is failure">Same handling as `neutral` with threads — bugbot just marked the findings blocking-severity rather than informational. Proceed through Step 4.</case>
<case name="Bugbot re-ran and posted on an older SHA">After a push, the previous HEAD's check-run no longer matters — always query the LATEST HEAD SHA. The script's `sort_by(.started_at) | last` logic handles cases where bugbot posts multiple runs on the same SHA.</case>
<case name="Thread from a non-cursor[bot] author">Skip. This skill is scoped to bugbot. For mixed human/bot reviews, run `/pr-address` separately.</case>
<case name="Empty PR / no check-runs ever">Step 2 returns `status: "none"`. Step 3 row 2 applies — report and wait. Bugbot has up to ~1 minute before it enqueues a scan.</case>
<case name="Script exit 2 (PROMPT_GH_AUTH / PROMPT_GH_INSTALL)">Prompt the user to install/authenticate `gh`, STOP. Do not fall back to curl or manual API calls.</case>
</edge-cases>
