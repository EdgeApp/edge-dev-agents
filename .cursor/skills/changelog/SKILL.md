---
name: changelog
description: Update CHANGELOG.md(s) with new entries describing changes made in the repo(s). Use when the user wants to update changelogs, and delivered by the CHANGELOG.md write gate before any agent-authored entry.
metadata:
  author: j0ntz
---

<goal>Add a few one-line CHANGELOG entries that state the final outcome of the branch's changes, in the shape the repo used before agents wrote its changelog.</goal>

<rules description="Non-negotiable constraints.">
<rule id="entry-shape">One entry is one line, one clause, under 140 characters, in the form `- type: description` (`(Plugin)` after the colon in multi-plugin repos). It names the outcome the user or integrator sees, and nothing else: no root cause, no mechanism, no clause opening with "so", "since", "because", or "which", no second sentence. That material goes in the commit body. The write gate lints these bounds; a blocked write is rewritten, never padded around.</rule>
<rule id="final-state-only">Entries describe the final state of all the branch's changes, not the journey. Reverted or superseded intermediate work gets no entry.</rule>
<rule id="few-entries">At most a few entries per branch. One entry per user-visible outcome, not one per commit.</rule>
<rule id="reference-old-entries">The top of the file is NOT the style reference: recent entries are agent-written and long. Calibrate on entries deep in the file, per `<step id="2">`.</rule>
<rule id="no-wrap">Never word-wrap an entry across lines.</rule>
</rules>

<step id="1" name="Locate the section">
Find the target section with `grep -n '^## ' CHANGELOG.md | head -5`. In `edge-react-gui` the choice between `Unreleased (develop)` and the `(staging)` section follows the im skill's CHANGELOG placement rules; every other repo takes the top `Unreleased` section. Types are grouped in order: `added`, `changed`, `fixed`, then the rest.
</step>

<step id="2" name="Calibrate on old entries">
Read a slice from well below the top, in one call:
```bash
grep -E '^\s*- ' CHANGELOG.md | sed -n '200,225p'
```
Match that length and register. Do not read the top hundred lines for style.
</step>

<step id="3" name="Write the entries">
Add the entries to the located section, grouped by type, one per outcome.

<examples description="Hypothetical before/after; the after is the shape to produce.">
- Before: `- fixed: (Foo) The sync ratio no longer reads a fresh wallet as synced. The SDK reports its state as ready before the first refresh pass, so a poll landing in that window latched to 1.`
- After: `- fixed: (Foo) Sync ratio no longer reports a fresh wallet as fully synced`
- Before: `- changed: Deep links now wait only for the account state they use, so a link that just opens a scene follows immediately after login instead of waiting for every wallet to load.`
- After: `- changed: Scene-only deep links open immediately after login`
</examples>
</step>

<edge-cases>
<case name="Repo without type prefixes">Some older repos write bare bullets. Keep the repo's existing convention for the prefix; the length and one-clause bounds still apply.</case>
<case name="No user-visible outcome">Refactors, test-only changes, and tooling with no external effect get no entry unless the repo's history shows it logs them (a `changed:` line in the old slice is the evidence).</case>
</edge-cases>
