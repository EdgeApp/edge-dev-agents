---
name: point-release
description: Ship an edge-react-gui point release (X.Y.Z with Z > 0) from the Asana tasks whose Release field names it - cherry-pick their develop commits onto master and staging, cut a dated CHANGELOG section and version bump on all three branches, prove master and staging received the same change, verify, push, then tag vX.Y.Z on master. Use when the user asks to ship, cut, dry-run or tag a point release, a hotfix release, or "4.x.y" for tasks marked with a point-release Release value. Not for X.Y.0 releases (/staging-master) or staging-only cherry-picks (/staging-cherry-pick).
compatibility: Requires git, node, gh.
metadata:
  author: j0ntz
---

<goal>Take edge-react-gui from "Asana marks tasks for X.Y.Z and their changes are on develop" to "master, staging and develop each carry those changes and one dated X.Y.Z section, and master is tagged vX.Y.Z", and refuse to push when master and staging would differ.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">`scripts/point-release-ship.sh` owns the whole flow: resolving the Asana tasks, the picks, the CHANGELOG section, the version bumps, the parity gate, the pushes and the tag. Never hand-run any of them.</rule>
<rule id="never-touch-the-callers-checkout">The script works in throwaway `git worktree`s on temp branches. Never check out master, staging or develop in the caller's repo.</rule>
<rule id="develop-first">Every change in a point release is already on develop. A task whose change is not there stops the run (`not-on-develop`); the fix is to land it on develop, never to commit it straight to master or staging.</rule>
<rule id="dry-run-first">Run `--dry-run` and show the operator the Step report and any stop output. Run for real only after they say go: the real run pushes develop, staging and master and the `vX.Y.Z` tag, which are outward-facing and not undone by a re-run.</rule>
<rule id="dry-run-publishes-tags-not-branches">A dry run pushes NOTHING to a branch and creates no `v*` tag. It pushes annotated `dryrun/<version>-{master,staging,develop}` tags so the result is inspectable from any machine. Never widen that to a branch push. `--no-publish` opts out.</rule>
<rule id="relay-the-step-report">Every run ends with a Step report followed by `RESULT:`. Relay the Step report, not a paraphrase of it, and every `warn` row.</rule>
<rule id="operator-owns-the-overrides">`--skip-task`, `--pick`, `--entries-file` and `--build-config-ready` change what ships. Pass them only when the operator names them. `--build-config-ready` needs the operator to state the master build server's config already matches the release's config schema; never infer it from the repo.</rule>
<rule id="no-script-bypass">On any stop, report the `RESULT:` line and the stop output, then STOP. `unmerged`, `not-on-develop`, `conflicts`, `parity-mismatch` and `build-config` are operator decision points, not errors to route around.</rule>
</rules>

<step id="1" name="Dry run">
```bash
~/.cursor/skills/point-release/scripts/point-release-ship.sh --dry-run --version <X.Y.Z>
```

The Tasks section lists every Asana task marked for the release, its PRs, the develop commits picked,
the dependency versions riding along and the CHANGELOG entries. A dependency upgrade carries every
change between the old and new pinned version, not only the task's; relay that list.

On a clean dry run, give the operator the inspection commands the script prints.
</step>

<step id="2" name="Read the RESULT line">
1. `unmerged` → step 3a.
2. `not-on-develop` → step 3b.
3. `conflicts` → step 3c.
4. `parity-mismatch` → step 3d.
5. `build-config` → step 3e.
6. `ok` on a dry run → step 4. `ok` on a real run → step 5.
7. `aborted` → nothing was pushed; report it and stop.
8. `error` → report the script's stderr and stop.
</step>

<step id="3" name="Take the stop back to the operator">
<sub-step name="3a: open PRs">
A release task has a PR not yet merged to develop. A dry run lists it as a `warn` and ships the rest;
a real run stops. The operator merges it and re-runs, or leaves the task out with
`--skip-task <gid>`.
</sub-step>

<sub-step name="3b: not on develop">
The task's change has no commit on develop the script can find. The operator lands it on develop,
names the commit with `--pick <sha>`, or leaves the task out with `--skip-task <gid>`.
</sub-step>

<sub-step name="3c: conflicts">
A pick conflicted outside `CHANGELOG.md` (CHANGELOG conflicts are resolved by the script). Relay the
files and the diff excerpt. A lockfile or `package.json` conflict usually means an earlier develop
commit (a prior pin of the same package) is missing; the operator names it with `--pick`. Anything
else is reworked on develop first.
</sub-step>

<sub-step name="3d: parity mismatch">
Master and staging received different changes, the X.Y.Z section differs between branches or is out
of entry type order, or develop's bump touched more than the CHANGELOG and version. Relay the stop
output as printed. It is fixed on the branches, never with a flag.
</sub-step>

<sub-step name="3e: build config">
The picks change the build config schema, and master builds read their config from the build
server. Relay the changed files and ask the operator to confirm the master build config is updated.
A dry run records this as a `warn` row and continues, so surface it before asking for the go.
</sub-step>
</step>

<step id="4" name="Push">
After the operator says go, re-run the last dry-run command without `--dry-run`, with the same flags,
plus `--build-config-ready` if they confirmed it in 3e. The script runs the repo verify on master and
staging, confirms interactively, then pushes develop, staging, master (never forced), tags `vX.Y.Z`
on master's bump commit and deletes the inspection tags. Pass `--yes` only when the operator asked to
skip the prompt. What it pushes and tags is the inspection tags' commits when the rebuild matches them
(same base, tree and commit contents), else the rebuild with a `warn` Reviewed row naming why: relay
that row, since the shipped commits are then not the ones the operator reviewed.

A push failure part-way is finished by re-running the same command: work already on the remote is
detected and skipped.
</step>

<step id="5" name="Report">
Report the version, the tasks shipped and skipped, the picks, master's bump commit, the tag, the
release date, and every override passed. QA publishes the GitHub release from the tag; this skill
does not.
</step>

<params>
| Flag | Default | Meaning |
|---|---|---|
| `--version X.Y.Z` | required | Point release to ship; master must be at X.Y.(Z-1) |
| `--repo <path>` | `$EDGE_GUI_DIR` or `~/git/edge-react-gui` | Repo to release |
| `--date YYYY-MM-DD` | today | Release date for the CHANGELOG heading |
| `--dry-run` | off | Do everything except the pushes and the tag |
| `--yes` | off | Skip the push confirmation |
| `--skip-task <gid>` | none | Leave an Asana task out (repeatable) |
| `--pick <sha>` | none | Add a develop commit to the picks (repeatable) |
| `--entries-file <f>` | generated | CHANGELOG entries, one `- <kind>: <text>` per line |
| `--build-config-ready` | off | Operator confirmed the master build config |
| `--master` / `--staging` / `--develop` | branch names | Branch names |
| `--remote <name>` | `origin` | Remote |
| `--keep-workspace` | off | Leave the temp worktrees for inspection |
| `--no-publish` | off | Skip the inspection tags on a dry run |
| `--tag-prefix <ns>` | `dryrun` | Namespace for those tags; refuses a `v*` prefix |

Exit `0` with `RESULT: ok`; `2` with `unmerged`, `not-on-develop`, `conflicts`, `parity-mismatch`,
`build-config` or `aborted`; `1` with `error`.
</params>

<edge-cases>
<case name="A branch moved after the dry run">Every push is non-force and fails if its branch moved; re-run the dry run so the picks land on the new tips before asking for the go again.</case>
<case name="Staging lacks a master-only hotfix">Parity compares each branch's delta, not its tree, so a hotfix on master that staging never got does not stop the run. Mention it to the operator; it belongs on staging through develop.</case>
<case name="Dependency entries report not in Unreleased">Expected: a dependency's entries live in its own CHANGELOG, not develop's Unreleased section, so the bump adds them without removing anything. Only a GUI entry missing from Unreleased deserves a look.</case>
<case name="The vX.Y.Z tag already exists">The preflight refuses. A remote tag means the release already shipped. A local-only tag is debris; the error names the delete command, which the operator runs.</case>
<case name="No task carries the Release value">The script stops with `error`. The tasks are marked in Asana's Release field; marking them is the operator's call.</case>
</edge-cases>
