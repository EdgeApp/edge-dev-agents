# Followup comment template — re-run / re-test followups

Stamped onto an Asana task when an eval Actions row of type `[re-run]` is approved.
Fill the two placeholders from the action item; the standing-policy block is fixed
and tracks current rules (update it HERE when rules change, never per-comment).
Destination is Asana: no em-dashes, /no-slop applies.

## Template

```
Followup: {GAP}. {BAR}. Treat the prior run's report and comments as historical
context only; re-verify environment and tooling claims fresh before working
around them. Attach pixel-verified proof screenshots captured from the device
that was driven, and update the tested field. Size any value-moving action per
the minimum-viable-amounts rule in the sim-testing playbook. No code change is
expected unless the test exposes a bug.
```

- `{GAP}` — what the prior run's evidence shows is missing, one sentence with the
  specific shortfall (e.g. "only unit tests are on record; the change was never
  exercised in the app", "test evidence stops at an in-app quote").
- `{BAR}` — the terminal success state this followup must drive, one sentence,
  per-action (executed-swap success scene, send broadcast/confirmation, the
  specific in-app render, or the gated alternative when execution is genuinely
  impossible, stated as such).
- Drop the minimum-viable-amounts sentence when the test moves no value.

## After the comment

```
~/.config/agent-watcher/update-status.sh <gid> Pending
```

The watcher spawns fresh sessions up to the concurrency cap and drains the rest
as slots free; no manual batching is needed (defer-and-drain is in
asana-watcher.js). Fresh spawns read current skills at invocation, so rule
upgrades bind automatically.
