<goal>Review this branch's own diff at the depth the task asks for, fix what survives curation, and do it before the PR exists.</goal>

<rules description="Non-negotiable constraints for the self-review phase.">

<rule id="field-decides">The task's `agent_review` field decides whether this phase runs and at what depth; nothing else does. Resolve it ONCE with `~/.cursor/skills/asana-review-field.sh <task-gid> --variant`. Output `none` means SKIP the whole phase, spend nothing, and say nothing about it in the report. Any other output is the workflow's args, passed through verbatim. Never infer a depth from the diff's size or the task's importance, and never run a review the field did not ask for.</rule>

<rule id="before-the-pr">This phase runs after local verification and BEFORE PR creation. Reviewer bots bill per push (pr-address `one-push-per-round`), so findings fixed now cost zero bot rounds, and the PR opens on reviewed code. It also makes the fixups free: with no PR yet the fold-mode oracle answers `no-pr` and every fix folds into the commit that introduced it, so the branch keeps a clean history with no fixup commits to finalize.</rule>

<rule id="findings-are-candidates">Workflow findings are candidates, not conclusions; judge each against your own read of the diff per pr-review `curation-owns-truth`. A rejected finding is recorded with its evidence in the run report, never silently dropped.</rule>

<rule id="fix-through-the-fixup-path">Apply surviving findings through the normal fixup path, never with a bare `git commit`: pick the target commit per pr-address's "Determine fixup target" sub-step, then `~/.cursor/skills/lint-commit.sh --fixup <target-sha> --for auto -m "<what changed and which finding it answers>"`, grouped one fixup per target per pr-address `one-fixup-per-target-per-turn`. `--for auto` is the right kind: a self-review finding is a self-found defect, so it bundles with reviewer-bot fixups exactly as those do. The fold-mode oracle inside `lint-commit.sh` decides fold-vs-preserve on its own; never pass a mode.</rule>

<rule id="post-record-to-own-pr">The phase's record reaches GitHub ONLY on a PR we author, as one `COMMENT` review whose body is pr-review's curation-record block (pr-review step 5): a `Fixed before review` list (each line naming the commit subject the fix folded into) and a `Rejected in curation` list (each with its evidence), deduped per pr-review `rejected-on-own-prs`. The `agent_review` field is the posting direction, so pr-review's `posting-gate` orch default does not hold it back. It posts through `github-pr-review.sh submit` (step 4.5f), never as inline comments, and only once the PR head carries the phase's fixes: right after phase 5 opens the PR on a first run; on a followup with an open PR, after the push that carries the fixes, or at once when nothing was fixed. A phase that found nothing, or could not run, posts nothing. On a PR we do not author (`non-owner-pr-completion`), nothing from this phase is posted; the record lives in the run report.</rule>

<rule id="report-both-sides">The run report's Testing section names the variant that ran and the counts fixed and rejected, and links the review posted per `post-record-to-own-pr` instead of repeating its lists; it carries the full lists (fixes with their fixup target, rejections with their evidence) only when nothing was posted. The phase posts no Asana comment; the PR review and the run report are its record. A phase that ran and found nothing says so; only a phase the field skipped is silent.</rule>

</rules>

<step id="4.5a" name="Resolve the variant">
```bash
~/.cursor/skills/asana-review-field.sh <task-gid> --variant
```
`none` ends the phase here. Otherwise keep the output as `<VARIANT>` for step 4.5b.
</step>

<step id="4.5b" name="Run the review on the branch diff">
The target is this branch's own diff against its base, not a PR:

```bash
git merge-base --fork-point <base-branch> HEAD || git merge-base <base-branch> HEAD
```

Then invoke the clone with the variant and that range:

```
Workflow({ name: "code-review-sonnet", args: "<VARIANT> <merge-base>..HEAD" })
```

It runs in the background; wait for its result (TaskOutput, blocking) before step 4.5c. The result carries `findings[]` (file, line, summary, failure_scenario, category, verdict) and `refuted[]`.
</step>

<step id="4.5c" name="Curate">
Per `findings-are-candidates`, judge every finding against the diff. Keep the rejection list with its evidence for step 4.5e.
</step>

<step id="4.5d" name="Fix">
Group survivors by target commit and apply them per `fix-through-the-fixup-path`. A finding you reject produces no commit.

Then re-verify at the SAME bar a reviewer-thread fix carries (watch.md step 6 point 3, reached from followup.md `followup-reopens-status` (4)), whether or not phase 4 ran in this segment: a fix that reaches code the app runs owes `/build-and-test` again (status back to `Developing` while fixing, `Testing` while verifying); an inert one owes nothing but the note in the report. A fix that breaks the build is worse than the finding it answered.
</step>

<step id="4.5e" name="Record">
Update `/tmp/agent-state-<gid>.md` (Decisions and Verified) with both lists, and mark the record `post: pending` when `post-record-to-own-pr` owes a post. Carry them into the run report per `report-both-sides`.
</step>

<step id="4.5f" name="Post the record (our own PR only)">
Runs at the point `post-record-to-own-pr` names (phase 5 calls back here on a first run). Write the review JSON to a file, pre-check it, then submit:

```bash
~/.cursor/skills/pr-review/scripts/github-pr-review.sh context --pr <number> --owner <owner> --repo <repo> > /tmp/agent-selfreview-ctx-<gid>.json
~/.cursor/skills/pr-review/scripts/github-pr-review.sh submit --check-only --pr <number> --owner <owner> --repo <repo> --sha <headSha> < /tmp/agent-selfreview-<gid>.json
~/.cursor/skills/pr-review/scripts/github-pr-review.sh submit --pr <number> --owner <owner> --repo <repo> --sha <headSha> < /tmp/agent-selfreview-<gid>.json
```

The payload is `{"event": "COMMENT", "body": "<curation-record blocks>"}`, with `author == me` and the dedupe checked against `reviews[]` in the context output. Flip the state file's mark to `post: done <review-url>`.
</step>

<edge-cases>
<case name="Field absent on the task">`asana-review-field.sh` returns the fleet default for an unset field, so an ordinary non-agent task without the field behaves exactly like the default. No special handling.</case>
<case name="Followup run with an open PR">The phase still runs when the field asks for it, and on a re-armed task an `agent_review` value the operator just set is what re-enters it, per followup.md `field-deltas-are-re-entry`. The fold-mode oracle answers `preserve` if a human is mid-review, so fixes stay visible as `fixup!` commits and reach the remote through the sanctioned finalize path rather than this phase; step 4.5f posts after that push.</case>
<case name="Workflow fails or returns nothing">A review that cannot run is not a blocker: record it in the report and continue to PR creation. The field asked for a review, not for a gate.</case>
</edge-cases>
