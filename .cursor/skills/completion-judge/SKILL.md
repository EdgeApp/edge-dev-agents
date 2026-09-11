<goal>Judge every completion event of an orchestrated run (Complete, pr-create, blocked=Yes) in a fresh headless context against the run's collected evidence, and gate the event on the verdict.</goal>

<rules description="Non-negotiable constraints.">
<rule id="deny-is-actionable">A judge deny arrives as gate stderr listing each failed dimension with its evidence and a `what_to_do`. Your only move is to DO each `what_to_do` (drive and log the attempt, revert scaffolding, regenerate and re-attach the report, deliver the ask) so the evidence changes, then retry the same command; the judge does not read arguments, so never re-issue the command unchanged, never edit prose to satisfy an item that asked for an action, and never write `/tmp/agent-completion-verdict-<gid>.json` or `/tmp/agent-judge-waiver-<gid>` yourself. When a genuine attempt at a `what_to_do` hits a real wall, take the blocked completion with that wall as the reason.</rule>
</rules>

<mechanism description="What the scripts decide on their own; documented in their headers, not restated here.">
- Gate: `~/.config/agent-watcher/hooks/require-completion-judgment.sh` (PreToolUse Bash) intercepts `update-status.sh <gid> Complete`, `--blocked yes`, and `pr-create.sh`; a block under an operator hold and an operator waiver pass without judgment; judge unavailable denies with a retry recipe.
- Launcher: `~/.config/agent-watcher/completion-judge.sh` collects the evidence bundle (`completion-evidence.sh`), reuses a verdict while the bundle hash is unchanged, honors an operator override found in the segment's comments, otherwise spawns `claude -p` outside the run and writes the verdict plus a provenance line.
- Rubric: `references/rubric.md` (dimensions J1 to J8, segment-scoped: a first run is judged against the task description, a followup only against the comments that re-armed it) and `references/concession-taxonomy.md`.
</mechanism>

<step id="1" name="Manual use">
```bash
~/.config/agent-watcher/completion-judge.sh --gid <gid> --event complete|pr-create|block [--reason "<text>"] [--force] [--offline]
cat /tmp/agent-completion-verdict-<gid>.json
```
`--force` ignores the cached verdict; `--offline` skips the Asana and GitHub fetches.
</step>
