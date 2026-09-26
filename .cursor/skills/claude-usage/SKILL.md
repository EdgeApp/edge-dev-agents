---
name: claude-usage
description: Check the Claude subscription's remaining usage (5-hour session window, 7-day weekly window, per-model weekly limits) and when each resets. Use when an agent or the operator asks how much usage is left, whether to start or continue expensive work, when a limit resets, or why a session stopped on a usage limit. Read-only.
metadata:
  author: j0ntz
---

<goal>Answer usage questions from the live subscription numbers, through one companion script.</goal>

<rules description="Non-negotiable constraints.">

<rule id="script-is-the-only-path">Read usage only with `~/.cursor/skills/claude-usage/scripts/claude-usage.sh`. Never read the Keychain item or `~/.claude/.credentials.json` yourself, never print or inline the OAuth token, and never call the usage or token endpoints by hand.</rule>

<rule id="never-refresh-the-token">Never refresh the OAuth token, and never write to the Keychain item or the credentials file. On `error: token_stale`, report it and stop; do not retry in a loop. Only unattended launchd callers pass `--wake` (see the script header for why).</rule>

</rules>

<step id="1" name="Read usage">

```bash
~/.cursor/skills/claude-usage/scripts/claude-usage.sh
```

Report `five_hour.pct` and `seven_day.pct` as percent USED (remaining is 100 minus it), each with its `resets_at` converted to the operator's local time, plus any `scoped` entry at or above 80%. `locked: true` means new requests fail until `locked_until`.

For a yes/no gate against thresholds, use `check` (exit 0 under, 3 at or over):

```bash
~/.cursor/skills/claude-usage/scripts/claude-usage.sh check --five-hour <N> --seven-day <N>
```
</step>

<edge-cases>
<case name="Exit 1">Relay the `error` field (`token_stale`, `no_credentials`, `network`, `http_<code>`) in one line. Treat usage as unknown, not as zero or full.</case>
</edge-cases>
