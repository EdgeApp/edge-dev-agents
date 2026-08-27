---
name: develop-staging
description: Cut an edge-react-gui staging release by merging develop into staging - bump the version, open the new CHANGELOG release section, date the one it retires, merge, prove develop and staging end up equivalent, then push. Use when the user asks to cut a staging release, merge develop into staging, run the staging checklist, or bump the app version for release.
compatibility: Requires git, node, curl. gh for the Crowdin precondition check.
metadata:
  author: j0ntz
---

<goal>Take edge-react-gui from "develop has accumulated a release" to "staging carries that release", and refuse to push when the two branches would not end up equivalent.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">`scripts/staging-release-merge.sh` owns the whole flow. Never hand-run the bump, the merge, the parity diff or the pushes.</rule>
<rule id="never-touch-the-callers-checkout">The script works in a throwaway `git worktree` on temp branches cut from `<remote>/develop` and `<remote>/staging`. Never check out develop or staging in the caller's repo: the operator's uncommitted work is not yours to move.</rule>
<rule id="dry-run-first">Run `--dry-run` and show the operator the plan, the conflict report and the parity result. Only run for real after they have seen it.</rule>
<rule id="dry-run-publishes-tags-not-branches">A dry run pushes NOTHING to `develop` or `staging`. It does push two annotated tags under `dryrun/`, so the merge result is inspectable from any machine. Never widen that to a branch push, and never let the prefix reach the `vX.Y.Z` namespace: those tags mean a shipped release, and this skill reads them to date CHANGELOG headings. `--no-publish` opts out.</rule>
<rule id="relay-the-step-report">Every run ends with a Step report followed by `RESULT:`. Relay the Step report, not a paraphrase of it. It is the run's own account of which phases ran, which stopped and which were never reached.</rule>
<rule id="deviation-from-conventions-doc">The edge-conventions doc (workflows/develop-to-staging.md) merges with `git merge -X theirs develop`, which silently takes develop's side of every conflict hunk. This skill deliberately does NOT: the task contract is to surface conflicts and wait for feedback, so the merge stops and each file is cleared by the operator with `--resolve-theirs`. The end state is the same; the difference is per-file consent. The doc's post-merge `git diff develop` assert is the Parity phase, and its pre-push `verify` is the Verify phase.</rule>
<rule id="operator-owns-the-clearances">`--allow` and `--resolve-theirs` encode a decision only the operator can make. Never pass either on your own initiative, and never on the same invocation that first surfaced the path. Re-run with the flags they name.</rule>
<rule id="changelog-resolution-is-shared">CHANGELOG conflicts go through `~/.cursor/skills/pr-land/scripts/changelog-union-merge.sh --release-merge`, shared with pr-land. Never fork it. Any edit to it must leave the default no-flag path producing the same resolved file, stderr and exit code, which pr-land's rebase flow depends on.</rule>
<rule id="no-script-bypass">Report the script's `RESULT:` line and STOP. `conflicts` and `parity-mismatch` are operator decision points, not errors to route around.</rule>
<rule id="publish-ordering-is-pr-lands">The dep release chain keeps pr-land's ordering: bump+tag locally, push master+tag, THEN npm publish. pr-land step 6 owns the rationale (git is retryable, npm is not; a pushed version commit npm lacks is benign and the publish resumes idempotently; the reverse direction is unrecoverable). Never reorder to publish-first, and treat a publish that ends at the auth boundary as a resumable stop, not a stranded tree.</rule>
<rule id="checkpoint-bumps-are-patch">Checkpoint refreshes (zcash, piratechain) are PATCH releases: dep_step passes `"bump":"patch"` to `pr-land-publish.sh`, overriding the changelog-tag derivation. The chain-registry/accountbased bump stays changelog-derived.</rule>
<rule id="publish-failures-are-stops">A publish-phase problem is a STOP, never a skip: a missing CHANGELOG or Unreleased heading, an unreadable publish result, a registry/master version mismatch, a permission rejection, and an auth that never completes all end the run with a failed step row. The ONLY publish no-op is the fully-benign shape, verified not assumed: Unreleased section present and empty AND the registry already serves master's package.json version (the gui pin still gets upgraded if it trails). The script enforces this; never reinterpret a failed publish row as ignorable.</rule>
<rule id="auth-link-relay">Publish auth links follow pr-land `npm-publish-auth`, restated here because every publish phase depends on it: relay each `AUTH_URL` the MOMENT it prints, as a bare clickable URL in the MESSAGE text AND inside the push notification body (a push saying "see chat" is dead weight on a phone). A fresh link supersedes all prior ones; say so rather than re-listing. A 403 after a completed auth is a permission problem, not link expiry — read the publish capture before re-relaying anything.</rule>
<rule id="checklist-steps-are-phases">Every Staging-checklist subtask is a ledger phase with its own Step-report row: the two Crowdin merges, the three dependency publishes (zcash and piratechain checkpoints, chain-registry into accountbased), release-dating, the bump, the merge, parity, verify, push. The dependency publish chain reuses pr-land's machinery (`pr-land-publish.sh`, `npm-publish-web.sh`, `upgrade-dep.sh`); never hand-roll a publish. There are NO operator skip flags: the run is all or nothing, and a phase reports `ok, nothing to do` only when that is baked-in fact (no open Crowdin PR, no refresh changes with the registry current, publish already complete). Interrupted work resumes idempotently on re-run (debris-tag guard, unpublished-version resume, registry/master mismatch check).</rule>
<rule id="crowdin-gap-is-reported-not-blocking">The Crowdin sync trigger is the Sync Now button in Crowdin's GitHub app, with no API surface, and the scheduled sync has been dormant since 2026-06. When no `l10n_develop` PR exists the phase records `ok, nothing to merge` (the checklist's own reading of an absent PR) with a reminder that Sync Now is the trigger if a sync was expected, and the cut proceeds, as the 4.50.0 cut did.</rule>
</rules>

<step id="1" name="Dry run">
The version defaults to a MINOR bump of develop's `package.json` version, which is what the Staging
checklist means by "bump version". Pass `--version X.Y.Z` for a patch release or any other target.

```bash
~/.cursor/skills/develop-staging/scripts/staging-release-merge.sh --dry-run
```

Relay every part the run reached. The phases follow the Staging checklist: translations (both
repos), workspace, the three dependency publishes, release-dating, the version bump, the merge, the
parity gate, the push. A `conflicts` stop happens before the parity gate runs, so on that verdict
there is no parity output to report.

On a real (non-dry) run, the dependency phases pull each dep repo's clean `master`, refresh its data
(checkpoints, or `chain-registry`), and when anything changed: commit, version-bump and tag via
`pr-land-publish.sh`, push, publish via `npm-publish-web.sh` (relay its `AUTH_URL` lines to the
operator as clickable links in the message), then bump the pin in the gui worktree via
`upgrade-dep.sh`. The Crowdin phases close-and-delete a stale `l10n_develop` PR, prompt the operator
for the Sync Now click, and merge the fresh PR.

The Step report at the end states this for you, one line per phase with `ok`, `warn`, `stopped` or
`not-reached`. Relay it verbatim. On a clean dry run it also names the two `dryrun/` inspection tags,
which any machine can fetch:

```bash
git fetch origin --tags --force
git diff dryrun/<version>-develop dryrun/<version>-staging
```
</step>

<step id="2" name="Read the RESULT line">
The last line is `RESULT: <verdict>`. Route on it:

1. `conflicts` → step 3a. Expect this on the first run of a real release cut: staging accumulates
   hotfix commits between releases, so `package.json`, `package-lock.json` and `ios/Podfile.lock`
   conflict nearly every time.
2. `parity-mismatch` → step 3b.
3. `ok` → go to step 4.
4. `error` → report the script's stderr and stop.
</step>

<step id="3" name="Take the stop back to the operator">
<sub-step name="3a — conflicts outside CHANGELOG.md">
`CHANGELOG.md` is resolved automatically and is never in this list. In the printed diffs the `HEAD`
side is staging and the other side is develop; `--resolve-theirs` takes the develop side.

The script classifies each conflicted file. Relay which classification it printed:

- *develop is a superset of staging*: a hotfix landed on staging and reached develop through a
  different commit, so the histories disagree about lines that agree textually.
- *develop supersedes staging (N entries at a newer version)*: the same dependency entries moved on
  both branches and develop went further. The routine case for the manifest and the lockfiles.
- *staging carries content develop lacks*: the only one that matters. The script names the offending
  lines. Something on staging never made it back to develop, so it has to be back-ported to develop
  first. This is the checklist's "Extra changes in staging? Need to ensure they're also in develop".
  Never clear one of these with `--resolve-theirs`.

For the first two the script prints a ready-to-paste re-run with a `--resolve-theirs` per safe file.
Show it to the operator and run it once they agree.
</sub-step>

<sub-step name="3b — non-CHANGELOG parity diff">
The two branches would not be equivalent. Show each path and its diff, and name the likely cause:

- Genuine drift on one branch. It has to be back-ported, then re-run.
- The repo's own precommit chain, which runs the localize step and `update-eslint-warnings`, so
  `eslint.config.mjs` and `src/locales/strings` can be rewritten by the merge commit itself. That is
  an artifact rather than drift.

Once the operator confirms, re-run adding `--allow <glob>` per path. The globs match whole paths, so
a directory needs a trailing wildcard: `--allow 'src/locales/strings/*'`, not
`--allow src/locales/strings`.
</sub-step>
</step>

<step id="4" name="Push">
Re-run the same command without `--dry-run`. The script confirms interactively before pushing;
`--yes` skips that prompt. It pushes the bump to `develop` first, then the merge to `staging`.

There is no PR in this flow. The merge goes straight to `origin/staging`, which is how every prior
develop-into-staging merge in this repo was done.
</step>

<step id="5" name="Report">
Report the version, the bump commit, the merge commit, every precondition warning, and every path
cleared with `--allow` or `--resolve-theirs`. A cleared path is a decision worth recording.
</step>

<params>
| Flag | Default | Meaning |
|---|---|---|
| `--repo <path>` | `$EDGE_GUI_DIR` or `~/git/edge-react-gui` | Repo to release |
| `--version X.Y.Z` | minor bump of develop's version | Explicit release version |
| `--prev-date YYYY-MM-DD` | commit date of tag `vX.Y.Z` | Date for a release still marked `(staging)` |
| `--dry-run` | off | Do everything except the two pushes |
| `--yes` | off | Skip the push confirmation |
| `--allow <glob>` | none | Parity path the operator cleared (repeatable) |
| `--resolve-theirs <path>` | none | Take develop's side for a conflicted path (repeatable) |
| `--develop` / `--staging` | `develop` / `staging` | Branch names |
| `--remote <name>` | `origin` | Remote |
| `--keep-workspace` | off | Leave the temp worktree for inspection |
| `--no-publish` | off | Skip the `dryrun/` inspection tags on a dry run |
| `--tag-prefix <ns>` | `dryrun` | Namespace for those tags; refuses a `v*` prefix |

Exit `0` with `RESULT: ok`; `2` with `RESULT: conflicts`, `parity-mismatch` or `aborted`; `1` with
`RESULT: error`.
</params>

<edge-cases>
<case name="No `(staging)` heading to date">Normal: the previous release was already dated, so the script only opens the new section. Undated headings elsewhere in the CHANGELOG are backfilled from their tags in the same pass, per the checklist's "if there are missing dates in other published versions, add the dates"; versions with no tag are left alone and counted in the report.</case>
<case name="No tag for the release being retired">The script dates it today and says so. Re-run with `--prev-date` if that is wrong.</case>
<case name="CHANGELOG conflict the union refuses">Only happens when the two sides order their release sections differently, which is an editing mistake on one branch. Fix the ordering on the source branch and re-run.</case>
<case name="A stale dryrun tag from an earlier attempt">Re-running force-updates the two tags in place, so they always point at the latest attempt for that version. Tags from older versions persist; delete them with `git push origin :refs/tags/dryrun/<version>-staging` when a release ships.</case>
<case name="The dependency files conflict on every release">Expected. `package.json`, `package-lock.json` and `ios/Podfile.lock` carry pins that moved on both branches, so they conflict on nearly every cut and classify as *develop supersedes staging*. Clear them with the printed re-run.</case>
<case name="A single staging-targeted commit mid-cycle">That goes onto staging through `/staging-cherry-pick`, which cherry-picks individual merged commits. This skill is the whole-release merge at the end of a cycle.</case>
<case name="A repo other than edge-react-gui">The flow is generic but the precondition warnings are edge-react-gui's. Pass `--repo` and read those warnings as advisory.</case>
</edge-cases>
