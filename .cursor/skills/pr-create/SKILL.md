---
name: pr-create
description: Create a pull request from the current branch, with optional Asana attach.
compatibility: Requires git, gh, node, jq. ASANA_TOKEN for Asana updates. ASANA_GITHUB_SECRET is OPTIONAL — only consumed by the `--asana-attach` widget path; the Asana link in the PR body works without it.
metadata:
  author: j0ntz
---

<goal>Create a PR from the current branch, optionally attach it to Asana.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">Do NOT call `gh` directly for PR creation. Use `~/.cursor/skills/pr-create/scripts/pr-create.sh`.</rule>
<rule id="no-script-bypass">If a companion script fails, report the error and STOP. Do NOT fall back to raw `gh`, `curl`, or workarounds.</rule>
<rule id="gh-auth-required">If script exits code 2 with `PROMPT_GH_AUTH`, prompt user to run `gh auth login` and STOP.</rule>
<rule id="no-dirty-pr">Do NOT create a PR when there are uncommitted changes.</rule>
<rule id="no-base-push">Do NOT push to `master`/`develop` directly.</rule>
<rule id="base-must-match-branch-point">Pass `--base <ref>` whenever the branch was cut from anything other than the repo's default branch (a white-label branch such as edge-react-gui's `coinhub`, a release branch, a stacked PR's parent). Without it the PR targets the default branch and its diff carries every commit separating the two, which no reviewer can read. Resolve the ref with `git merge-base --is-ancestor origin/<ref> HEAD` or from the branch's upstream before creating the PR.</rule>
<rule id="verification-required">Run verification before creating the PR.</rule>
<rule id="no-reviewer-assignment">Do NOT auto-assign Asana reviewers, set review-needed status, or estimate review hours from this skill. Reviewer choice is a human step; callers that want those behaviors must invoke `asana-task-update` themselves.</rule>
<rule id="flag-contract">To attach the PR to its Asana task, pass `--asana-task <gid>` AND `--asana-attach` to `pr-create.sh`; the script runs the attach itself, so never follow it with a separate `asana-task-update.sh --attach-pr` call unless the attach failed. Resolve the gid from chat context when the caller did not name one. Read the result from the JSON `asana_attached` field: `true` attached, `false` the attach failed (stderr WARN carries the manual command), `null` means `--asana-attach` was not passed.</rule>
<rule id="script-timeouts">Asana updates can take up to 90s. Use `block_until_ms: 120000` for `asana-task-update.sh` calls.</rule>
<rule id="repo-template-required">If the repo has `.github/PULL_REQUEST_TEMPLATE.md`, the PR body must preserve that template's section headings. Do NOT substitute generic sections like `Summary` or `Test plan`.</rule>
<rule id="attach-test-evidence">When proof screenshots of the change exist (an orchestrated run's `/build-and-test` saves them as `/tmp/agent-proof-<task-gid>-NN-<slug>.png`, or the caller names files), attach them via `~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh --repo <owner/repo> --pr <num> <png...>` — it downscales copies, uploads them to the public assets branch (`edge-dev-agents@agent-pr-assets`), and renders them as ONE table inside the PR BODY between `<!-- agent-test-evidence -->` sentinels (filename slug → caption, `NN` → the cell number prose can cite, argument order → display order). Frames group into BATCHES, one per attach at one head sha, and the script re-renders the whole table every run, so never hand-write evidence into a body or comment. When ANY attached file carries the `HACKED` token you MUST pass `--hack-note "<one short line: what was hacked>"` (e.g. "hard-coded the empty-state branch true in WalletList") — the script refuses without it, so the row banner names the actual hack instead of a generic paragraph; reuse the description from the report's Testing section. GitHub has NO API for uploading images into a PR — do NOT inline base64, commit images onto the PR branch, or link local paths. If no proof screenshots exist, skip silently (not every PR is app-testable).</rule>
<rule id="prose-edit-funnel">To change an EXISTING PR's title or prose body (a rename, a stale description), write the full new body to a file and run `~/.cursor/skills/pr-create/scripts/pr-prose-edit.sh --repo <owner/repo> --pr <num> [--title "<title>"] [--body-file <path>]`. Write only the prose: every agent sentinel block (evidence table, synced description) is carried over from the live body by the script, so leave those blocks out or copy them unchanged. Exit 2 is a lint refusal: fix the prose and re-run. It refuses PRs you did not author.</rule>
<rule id="evidence-dispositions">Attaching at a head sha that MOVED since the last attach opens a new batch and retires the previous one, so the table shows the current build rather than every state the branch has been in. The script refuses (exit 2, nothing uploaded) until every retiring frame has a decision, and prints the scene list plus the command to re-run: `--carry-forward <scene>` for a frame still true at the new head (re-points the existing blob; no recapture, no re-upload), `--retire <scene>` for one the change invalidated. Re-shooting a frame in the same run IS its decision and needs no flag. `all` works with either flag and an explicit scene beats it. Retirement only happens before a human has reviewed; once a human has acted on the PR, batches freeze and new frames append as their own row, so the refusal cannot fire. Never work around it by skipping the attach or by renaming files — an unmentioned frame is the one case the script cannot distinguish from an oversight.</rule>
</rules>

<step id="1" name="Push branch">
Push current branch if needed:

```bash
git push -u origin HEAD
```

If tracking is already configured and branch is up to date, skip.
</step>

<step id="2" name="Verification">
Run:

```bash
~/.cursor/skills/verify-repo.sh . --base <upstream-ref>
```

Use `origin/develop` for `edge-react-gui` and `origin/master` for other repos. On
a branch cut from a non-default base (per `base-must-match-branch-point`), use
that base instead so verification and the PR diff cover the same commits.
</step>

<step id="3" name="Build PR description">
Gather context in parallel:

```bash
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' || echo master)
git log origin/$DEFAULT_BRANCH..HEAD --format=%B---
```

If `.github/PULL_REQUEST_TEMPLATE.md` exists, read it now and use it as the source of truth for the PR body structure. Fill in its existing sections and only append `### Description` if the template has no description section and branch context needs a place to live.

If Asana context is available from chat or fetched via `--asana-task`, add it inside `### Description`. Do not invent alternate section sets such as `Summary` / `Test plan`.
</step>

<step id="4" name="Create PR">
Write body to `/tmp/pr-body-<task-gid>.md` (gid-scoped — a shared `/tmp/pr-body.md` was clobbered by a concurrent slot mid-run; use the PID if no gid exists), then run:

```bash
~/.cursor/skills/pr-create/scripts/pr-create.sh \
  --title "<title>" \
  --body-file /tmp/pr-body-<task-gid>.md \
  [--base <ref>] \
  [--asana-task <task_gid> --asana-attach]
```

`--base` defaults to the repo's default branch; pass it explicitly per
`base-must-match-branch-point`. The script refuses a base that does not exist on
`origin` or that equals the current branch, and it scopes its changelog, title,
and description reads to the same base.

The companion script validates body files against the repo template and rejects generic fallback sections on templated repos. Capture PR URL and number from JSON output.
</step>

<step id="4b" name="Attach test-evidence screenshots">
Per `attach-test-evidence`: if proof screenshots exist for this change (`ls /tmp/agent-proof-<task-gid>-*.png`, or caller-provided files), attach them now:

```bash
~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh \
  --repo <owner/repo> --pr <pr-number> \
  /tmp/agent-proof-<task-gid>-01-<slug>.png [more...]
```

Pass them in narrative order (NN prefix). If ANY file carries the `HACKED` token, add `--hack-note "<one short line: what was hacked>"` per `attach-test-evidence`. No screenshots → skip silently. Never rename a `HACKED`-marked file to hide the marker — the script keys the 🪓 caption and banner off that token (build-and-test `hack-verify-visual-changes`).

On a FIRST attach nothing retires, so no disposition is ever needed here. Exit 2 means this PR already had evidence from an earlier build: re-run with the `--carry-forward` / `--retire` flags the refusal printed, per `evidence-dispositions`.
</step>

<step id="5" name="Check the Asana PR attach">
If `--asana-attach` was not requested, skip.

Per `flag-contract`, read `asana_attached` from step 4's JSON. On `false`, run the manual attach the WARN line names, once, and report its result. Reviewer assignment and review status stay out of scope per `no-reviewer-assignment`.
</step>

<step id="6" name="Report result">
Display PR URL as a clickable markdown link:

`[owner/repo#123](https://github.com/owner/repo/pull/123)`
</step>

<edge-cases>
<case name="Branch already has an open PR">Report the existing PR URL and stop.</case>
<case name="No gh auth">Prompt user to run `gh auth login` and stop.</case>
<case name="Rebase needed">Ask user before rebasing and force-pushing.</case>
</edge-cases>
