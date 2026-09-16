---
name: resolve-run
description: Resolve orchestrated agent run(s) into a compact JSON evidence manifest (transcript, PRs, Asana status, slot/pool/worktree state, infra log paths). Use when an eval or investigation needs the full evidence surface for a run by task GID, or to enumerate runs since a date. Read-only.
---

<goal>Turn a task GID or a date window into evidence manifest(s) that downstream evaluators (/agent-eval, /orch-eval, /eval-run) consume — without each of them re-deriving run context.</goal>

<rules description="Non-negotiable constraints.">
<rule id="read-only">This skill NEVER mutates anything: no Asana writes, no tmux commands beyond has-session, no slot/pool/worktree changes. It only resolves and reports.</rule>
<rule id="script-does-the-work">All resolution logic lives in `~/.cursor/skills/resolve-run/scripts/resolve-run.sh`. Do NOT re-implement discovery/resolution inline (no ad hoc grep of the watcher log or transcript hunting). Run the script and interpret its JSON.</rule>
<rule id="no-credentials">Never read or print the contents of `~/.config/agent-watcher/credentials.json`. The script reads the token internally for the Asana fetch; that is the only sanctioned access.</rule>
<rule id="manifest-is-pointers">The manifest carries PATHS and compact signals, not file contents. Downstream consumers do their own targeted reads (grep, line ranges) of the transcript and logs it points to.</rule>
</rules>

<step id="1" name="Run the resolver">
One of (with a 60000ms+ timeout):

```bash
~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid <task-gid>
~/.cursor/skills/resolve-run/scripts/resolve-run.sh --since <ISO-date>
~/.cursor/skills/resolve-run/scripts/resolve-run.sh --since <ISO-date> --list   # discovery only, no deep resolution
~/.cursor/skills/resolve-run/scripts/resolve-run.sh --gid <task-gid> --transcript-only   # just the transcript path
```

Output is a JSON array of manifests (stdout only; diagnostics on stderr). Exit 0 = ok, 1 = error, 2 = usage.
</step>

<step id="2" name="Interpret">
Key manifest fields:
- `in_flight: true` — run is still executing; evaluators must SKIP it (incomplete evidence).
- `transcript` is the run's NEWEST SEGMENT: the session whose opening records name the gid on a run-identity record (the `/one-shot` args, a resumed `lastPrompt`, the run-context `Task gid:` line) and whose head carries the run signature, ordered by the timestamp of its LAST record. A gid merely mentioned elsewhere in a session, and a `--chat` fork of the run, are both excluded by construction.
- `transcript: null` — transcript not found; a transcript-eval cannot run for this gid (report it). A report-eval still can: `prs` and `era` fall back to Asana data.
- `evidence_sources` — where `prs` (`transcript`, `asana-attachments`, both, or `none`) and the `era.as_of` date (`window_end`, `release_receipt`, `report_attached`, `version_stamp`, `spawned_at`, or `none`) came from. `era_as_of: none` means every era row is in effect regardless of the run's age; say so when grading a dated dimension.
- `asana.status: "__MISSING__"` — task deleted/404; `"__NO_AUTH__"` — no token available.
- `signals.revive_pings_in_transcript > 0` — durable evidence of a watchdog revive (orch-eval liveness dimension).
- `slot`/`pool_entry` non-null on a Complete run — leaked resources (orch-eval release dimension); null on a completed run is the EXPECTED state, not evidence of clean release.
- `release_receipt` non-null — the watchdog's durable retirement receipt (`released:{sim,slot,metro}` + slot identity); this is the primary clean-release evidence. Null = run predates the receipt hook (2026-06-10) → NOT_CAPTURED for release dimensions.
</step>

<edge-cases>
<case name="Watcher log rotated/empty">Discovery falls back to worktree-dir mtimes; runs whose worktree was already GC'd AND missing from the log are unenumerable — note this as a coverage gap rather than silently reporting completeness.</case>
<case name="Multiple transcripts match a gid">A run that was resumed has one session per segment; the script returns the one whose LAST RECORD is newest, which is the segment the run finished in. A file's mtime is NOT that ordering (a rewritten old segment carries a newer mtime). If an eval needs the earlier segments too, list them manually and say so.</case>
</edge-cases>
