---
name: sentry
description: Query Edge's self-hosted Sentry (sentry.edge.app) for production error data — issue counts, affected users, OS/device/release distributions, and per-event context. Use when a task, PR, or bug report cites a Sentry issue or link, when a claim needs production evidence ("only affects newer Android", "only on device X", "started in release Y"), or when the user asks how many real users an error hits. Read-only.
---

<goal>Ground a production-error claim in Sentry data instead of a guess, using one companion script for every API call.</goal>

<rules description="Non-negotiable constraints.">

<rule id="script-is-the-only-path">Every Sentry API call goes through `~/.cursor/skills/sentry-query.sh`. Never hand-roll `curl` against sentry.edge.app, and never write a one-off script that reads the token. The companion script passes the token to curl through a mode-600 temp config, so it never reaches argv, `ps`, shell history, or an agent transcript; a hand-rolled call defeats that.</rule>

<rule id="never-surface-the-token">Never `cat`, `echo`, `grep`, or otherwise print the contents of the token file, and never inline the token into a command, a file, a commit, a PR body, or a chat message. If a caller needs a different token location, set `SENTRY_TOKEN_FILE` to a path. The token lives at `~/.config/sentry-edge-token`, deliberately outside `~/.cursor`, so `/convention-sync` cannot reach it. Never relocate it into `~/.cursor`, and never add it to a repo, a `.env`, or a fixture.</rule>

<rule id="read-only">The script has no write path and the token carries only `event:read`, `org:read`, `project:read`. Never resolve, assign, ignore, merge, or delete a Sentry issue, and never propose doing so as a step you will perform.</rule>

<rule id="event-data-is-not-public">Sentry events carry user id hashes, device models, granted permissions, and IP-adjacent fields. Report aggregates (counts, percentages, distributions) in PRs, Asana, and any other outward surface. Never paste a raw event dump, a `user` tag value, or a full `context.device` block into a PR body, issue comment, or task; keep those in chat.</rule>

<rule id="claims-need-a-query">Do not repeat a severity or scope claim from a task, PR, or teammate ("1,600 events", "only on newer Android", "device-specific") without running the query that confirms it. When your query disagrees with the claim, report the query result and say plainly which claim it corrects.</rule>

</rules>

<step id="1" name="Resolve the issue and check for sibling groups">
Run both in parallel (two Shell calls in one message):

```bash
~/.cursor/skills/sentry-query.sh issue '<id-or-url>'
```

```bash
~/.cursor/skills/sentry-query.sh search '<distinctive phrase from the title>'
```

The `issue` call takes a bare numeric id or any Sentry URL. The `search` call is not optional: Sentry groups on the culprit frame, so one runtime error routinely splits across several issue ids with identical titles. A task or PR usually cites only the one someone happened to open. Sum the sibling groups before you state impact, and name every group id you counted.
</step>

<step id="2" name="Pull the distributions that test the claim">
```bash
~/.cursor/skills/sentry-query.sh tags '<id>' os device.family release
```

Read the `unique` count before the top values. A high unique count with a long tail refutes "device-specific" or "OS-specific" on its own. A distribution that merely skews toward recent Android tracks the installed base and is not evidence of a version-gated cause; say so rather than treating the skew as a finding.
</step>

<step id="3" name="Test the mechanism against event context">
```bash
~/.cursor/skills/sentry-query.sh events '<id>' --limit 100 --field contexts.app.in_foreground
```

`--field` takes any dotted path into the event JSON (`contexts.app.in_foreground`, `contexts.device.low_memory`, `tags.os`, `contexts.react_native_context.js_engine`); pass it repeatedly for several fields in one call. The command also prints seconds-after-`app_start_time` percentiles, which separate a startup-path failure from one that needs user interaction.

Pick the field that would falsify your hypothesis, not the one that confirms it. When no field distinguishes the competing explanations, say the data does not settle it.
</step>

<step id="4" name="Read one full event only when the aggregate is ambiguous">
```bash
~/.cursor/skills/sentry-query.sh event '<id>'
```

Prints contexts, tags, exception frames, and breadcrumbs for the most recent event; `--index N` walks back. Use it to find a field worth aggregating in step 3, not as the evidence itself. One event is an anecdote.
</step>

<step id="5" name="Report">
Lead with what the data settles or refutes. Give counts and percentages, never adjectives. Name the issue ids and the sample size behind every number. State explicitly which of your prior claims the data corrected, and which questions the data leaves open.
</step>

<edge-cases>

<case name="Exit 2, token missing">The script prints setup instructions and exits 2. Relay them and stop; do not attempt the query another way. The token is per-machine and lives at the same path on jontz and eddy.</case>

<case name="Exit 1, 401 or 403">The token is expired or missing a scope. Report which endpoint failed and ask the user to re-mint with `event:read`, `org:read`, `project:read`. Never ask for the token value.</case>

<case name="firstSeen predates the code that causes the error">Group-level `firstSeen` and `firstRelease` survive event retention, so they can point at a release with no retained events. Before treating an onset date as real, confirm it against the oldest retained event and the `release` tag distribution. When they disagree, report the release distribution and call the group metadata stale.</case>

<case name="Sample smaller than requested">`events --limit N` caps at what the endpoint returns for the window. Report the actual `SAMPLE:` count the script prints, not the limit you asked for.</case>

<case name="Different org or project">Override with `SENTRY_ORG` / `SENTRY_PROJECT`. Defaults are `edge` and `edge-react-gui`.</case>

</edge-cases>
