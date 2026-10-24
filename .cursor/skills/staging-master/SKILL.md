---
name: staging-master
description: Ship an edge-react-gui X.Y.0 release by merging staging into master - merge with git's default message, date the release's CHANGELOG heading, prove master ends up with staging's tree, verify, push master, then push the vX.Y.0 tag. Use when the user asks to merge staging into master, ship or tag a release to master, or run the master release merge. Not for point releases (X.Y.Z with Z > 0), which ship through /point-release.
compatibility: Requires git, node.
metadata:
  author: j0ntz
---

<goal>Take edge-react-gui from "staging carries a finished X.Y.0 release" to "master carries exactly staging's tree, dated and tagged", and refuse to push when the merge result would differ from staging.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">`scripts/master-release-merge.sh` owns the whole flow. Never hand-run the merge, the CHANGELOG dating, the parity diff, the push or the tag.</rule>
<rule id="never-touch-the-callers-checkout">The script works in a throwaway `git worktree` on a temp branch cut from `<remote>/master`. Never check out master or staging in the caller's repo.</rule>
<rule id="dry-run-first">Run `--dry-run` and show the operator the Step report and any stop output. Run for real only after they say go: the real run pushes `master` and the `vX.Y.0` tag, which are outward-facing and not undone by a re-run.</rule>
<rule id="dry-run-publishes-tags-not-branches">A dry run pushes NOTHING to `master` and creates no `v*` tag. It does push one annotated tag, `dryrun/<version>-master`, so the merge result is inspectable from any machine. Never widen that to a branch push. `--no-publish` opts out.</rule>
<rule id="relay-the-step-report">Every run ends with a Step report followed by `RESULT:`. Relay the Step report, not a paraphrase of it.</rule>
<rule id="operator-owns-the-clearances">`--resolve-theirs` and `--allow` encode a decision only the operator can make, even for files the script lists as cleared by the commit match. Never pass either on your own initiative, and never on the same invocation that first surfaced the path. Re-run with the flags they name.</rule>
<rule id="build-config-ready-is-operator-only">Pass `--build-config-ready` only after the operator states the master build server's config already matches the release's config schema. You cannot check that config; never infer it from the repo.</rule>
<rule id="point-releases-out-of-scope">X.Y.Z with Z > 0 ships through `/point-release`, not this skill. The preflight refuses it; do not work around the refusal.</rule>
<rule id="no-script-bypass">On any stop, report the `RESULT:` line and the stop output, then STOP. `conflicts`, `parity-mismatch` and `build-config` are operator decision points, not errors to route around.</rule>
</rules>

<step id="1" name="Dry run">
The script ships the tip of `<remote>/staging`. Pass `--ref <commit>` only when the operator names an
earlier staging commit.

```bash
~/.cursor/skills/staging-master/scripts/master-release-merge.sh --dry-run
```

On a clean dry run the report names the inspection tag. Give the operator these commands with the
version filled in:

```bash
git fetch origin --tags --force
git show --stat dryrun/<version>-master
git diff origin/staging dryrun/<version>-master
```

The last diff is the dated CHANGELOG heading and nothing else.
</step>

<step id="2" name="Read the RESULT line">
1. `conflicts` → step 3a.
2. `parity-mismatch` → step 3b.
3. `build-config` → step 3c.
4. `ok` on a dry run → step 4. `ok` on a real run → step 5.
5. `aborted` → nothing was pushed; report it and stop.
6. `error` → report the script's stderr and stop.

A `warn` row on the Master-only phase names master commits with no counterpart on staging. Relay
each one; they are what the conflict and parity stops are judged against.
</step>

<step id="3" name="Take the stop back to the operator">
<sub-step name="3a: conflicts outside CHANGELOG.md">
`CHANGELOG.md` is resolved automatically and never appears here. The script splits the conflicted
files into two lists:

- *Cleared by the commit match*: every master commit touching the file has a counterpart on staging.
  Taking staging's side loses nothing.
- *Need an operator decision*: at least one touching master commit has no staging counterpart. Show
  the listed commits and diffs. The operator confirms staging carries each change or something newer
  (a dependency staging already moved past is the routine case), or lands the missing change on
  develop and brings it over with `/staging-cherry-pick` first.

Show both lists and the printed `--resolve-theirs` flags. Re-run the dry run with the flags the
operator approves.
</sub-step>

<sub-step name="3b: parity mismatch">
The merge result differs from staging beyond the dated heading. Relay the stop output as printed.
Paths the script prints under "superseded these; re-run adding" are master changes staging took and
then reworked or reverted; git's merge keeps the master version, and `--resolve-theirs` takes
staging's. Anything else is master content staging never received: the operator lands it on develop
and cherry-picks it to staging, or keeps it with `--allow <glob>`.

A parity stop on `CHANGELOG.md` itself means master has a released section staging lacks. That is
fixed on the branches, never with a flag.
</sub-step>

<sub-step name="3c: build config">
The release changes the config schema, and master builds read their config from the build server.
Relay the changed files and ask the operator to confirm the master build config is updated. Re-run
with `--build-config-ready` only after they confirm. A dry run records this as a `warn` row and
continues, so surface it before asking for the go in step 4.
</sub-step>
</step>

<step id="4" name="Push">
After the operator says go, re-run the last dry-run command without `--dry-run`, with the same
flags, plus `--build-config-ready` if they confirmed it in 3c. The script confirms interactively
before pushing; pass `--yes` only when the operator asked to skip that prompt. It pushes `master`,
then the lightweight `vX.Y.0` tag on the merge commit, then deletes the inspection tag. What it
pushes and tags is the inspection tag's commit when the rebuild matches it (same base, tree and commit
contents), else the rebuild with a `warn` Reviewed row naming why: relay that row, since the shipped
merge is then not the one the operator reviewed.

There is no PR in this flow; every prior staging-into-master merge went straight to `origin/master`.
</step>

<step id="5" name="Report">
Report the version, the merge commit, the tag, the release date used, every path cleared with
`--resolve-theirs` or `--allow`, and whether `--build-config-ready` was passed. QA publishes the
GitHub release from the tag; this skill does not.
</step>

<params>
| Flag | Default | Meaning |
|---|---|---|
| `--repo <path>` | `$EDGE_GUI_DIR` or `~/git/edge-react-gui` | Repo to release |
| `--ref <commit>` | `<remote>/staging` tip | Staging commit to ship |
| `--date YYYY-MM-DD` | today | Release date for the CHANGELOG heading |
| `--dry-run` | off | Do everything except the master push and the `vX.Y.0` tag |
| `--yes` | off | Skip the push confirmation |
| `--resolve-theirs <path>` | none | Take staging's side for a path (repeatable) |
| `--allow <glob>` | none | Parity path the operator cleared (repeatable) |
| `--build-config-ready` | off | Operator confirmed the master build config |
| `--master` / `--staging` | `master` / `staging` | Branch names |
| `--remote <name>` | `origin` | Remote |
| `--keep-workspace` | off | Leave the temp worktree for inspection |
| `--no-publish` | off | Skip the inspection tag on a dry run |
| `--tag-prefix <ns>` | `dryrun` | Namespace for that tag; refuses a `v*` prefix |

Exit `0` with `RESULT: ok`; `2` with `conflicts`, `parity-mismatch`, `build-config` or `aborted`;
`1` with `error`.
</params>

<edge-cases>
<case name="Staging moved after the dry run">The real run fetches and ships the current staging tip, so its merge differs from the reviewed preview and the Reviewed row is `warn`. Re-run the dry run first whenever staging moved since the operator reviewed it.</case>
<case name="Master moved after the dry run">The master push is non-force and fails if master moved; nothing changes on the remote. Re-run the dry run to merge onto the new tip.</case>
<case name="The vX.Y.0 tag already exists">The preflight refuses. A remote tag means the release already shipped. A local-only tag is debris from an earlier attempt; the error names the delete command, which the operator runs.</case>
<case name="No `(staging)` heading for the version">The preflight refuses. The release section on staging was already dated or never opened; that is fixed on staging through develop, not here.</case>
<case name="A hotfix landed on master during the cycle">It shows on the Master-only row. If staging has it (cherry-picked or reworked) the commit match clears it; if not, it reaches step 3a or 3b as an operator decision.</case>
</edge-cases>
