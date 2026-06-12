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
<rule id="verification-required">Run verification before creating the PR.</rule>
<rule id="no-reviewer-assignment">Do NOT auto-assign Asana reviewers, set review-needed status, or estimate review hours from this skill. Reviewer choice is a human step; callers that want those behaviors must invoke `asana-task-update` themselves.</rule>
<rule id="flag-contract">`--asana-attach` only runs when a task GID is available from chat context or explicit `--asana-task <gid>`. If no task GID is available, fail fast and skip the attach.</rule>
<rule id="script-timeouts">Asana updates can take up to 90s. Use `block_until_ms: 120000` for `asana-task-update.sh` calls.</rule>
<rule id="repo-template-required">If the repo has `.github/PULL_REQUEST_TEMPLATE.md`, the PR body must preserve that template's section headings. Do NOT substitute generic sections like `Summary` or `Test plan`.</rule>
<rule id="attach-test-evidence">When proof screenshots of the change exist (an orchestrated run's `/build-and-test` saves them as `/tmp/agent-proof-<task-gid>-NN-<slug>.png`, or the caller names files), attach them to the PR after creation via `~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh --repo <owner/repo> --pr <num> <png...>` — it uploads them to the public assets branch (`edge-dev-agents@agent-pr-assets`) and posts ONE comment embedding the images inline (filename slug → caption; argument order → display order). GitHub has NO API for uploading images directly into comments — do NOT inline base64, commit images onto the PR branch, or link local paths. If no proof screenshots exist, skip silently (not every PR is app-testable).</rule>
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

Use `origin/develop` for `edge-react-gui` and `origin/master` for other repos.
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
  [--asana-task <task_gid>]
```

The companion script validates body files against the repo template and rejects generic fallback sections on templated repos. Capture PR URL and number from JSON output.
</step>

<step id="4b" name="Attach test-evidence screenshots">
Per `attach-test-evidence`: if proof screenshots exist for this change (`ls /tmp/agent-proof-<task-gid>-*.png`, or caller-provided files), attach them now:

```bash
~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh \
  --repo <owner/repo> --pr <pr-number> \
  --title "Test evidence" \
  /tmp/agent-proof-<task-gid>-01-<slug>.png [more...]
```

Pass them in narrative order (NN prefix). No screenshots → skip silently.
</step>

<step id="5" name="Optional Asana PR attach">
If `--asana-attach` was not requested, skip.

If `--asana-attach` is requested, resolve `task_gid` from:

1. explicit `--asana-task <gid>` argument
2. chat context (previous task-review/im context)

If no task GID is available, fail fast and report:

> `--asana-attach` was requested but no task GID was found in flags or chat context.

Then call:

```bash
~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh \
  --task <task_gid> \
  --attach-pr --pr-url <pr_url> --pr-title "<title>" --pr-number <number>
```

Do NOT pass `--assign`, `--set-status`, or `--auto-est-review-hrs` from this skill. Reviewer assignment and review-status updates are intentionally out of scope — see `no-reviewer-assignment` rule.
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
