---
name: develop-staging
description: Run the edge-react-gui release merge from develop into staging - bump the version, open the new CHANGELOG release section, date the previous one, merge, prove develop and staging are at parity, then push. Use when the user asks to cut a staging release, merge develop into staging, run the staging checklist, or bump the app version for release.
compatibility: Requires git, node, curl. gh for the Crowdin precondition check.
metadata:
  author: j0ntz
---

<goal>Take edge-react-gui from "develop has accumulated a release" to "staging carries that release", following the Staging checklist, and refuse to push when develop and staging would not end up equivalent.</goal>

<rules description="Non-negotiable constraints.">
<rule id="use-companion-script">`scripts/develop-staging.sh` owns the whole flow. Do NOT hand-run the bump, the merge, the parity diff or the pushes. The script exists because each of those steps has a trap that hand-running walks into.</rule>
<rule id="never-touch-the-callers-checkout">The script works in a throwaway `git worktree` on temp branches cut from `<remote>/develop` and `<remote>/staging`. The caller's HEAD, index and working tree are never modified, and a `--dry-run` leaves zero residue. Never "simplify" this by checking out develop or staging in the caller's repo: the operator's uncommitted work is not yours to move.</rule>
<rule id="dry-run-first">Run `--dry-run` first and show the operator the plan, the conflict report and the parity result. Only run for real after they have seen it.</rule>
<rule id="non-changelog-diffs-abort">A post-merge difference between staging and develop in ANY path other than `CHANGELOG.md` aborts the push (exit 11). Report the paths and their diffs and WAIT for the operator. Do not clear them yourself: `--allow <glob>` exists for the operator's decision, not the agent's.</rule>
<rule id="conflicts-outside-changelog-stop">`CHANGELOG.md` conflicts resolve mechanically. Every other conflicted path stops the run (exit 10) with a per-file classification. Do not take a side on the operator's behalf: `--resolve-theirs <path>` is how they authorize it on the re-run.</rule>
<rule id="changelog-resolution-is-shared">CHANGELOG conflicts go through `~/.cursor/skills/pr-land/scripts/changelog-union-merge.sh --release-merge`. That script is shared with pr-land. Never fork it, and never change its default (no-flag) behavior: pr-land's rebase path depends on it byte for byte.</rule>
<rule id="no-script-bypass">If the script exits non-zero, report the exit code and its output and STOP. Exit 10 and 11 are decision points for the operator, not errors to route around.</rule>
<rule id="manual-steps-are-reported-not-performed">Crowdin syncs and the checkpoint/chain-registry publishes are browser and npm-publish work the script cannot do. It warns when they look outstanding. Surface those warnings to the operator before the push.</rule>
</rules>

<step id="1" name="Establish the release">
Confirm the repo (default `~/git/edge-react-gui`) and the version. The default is a MINOR bump of
develop's `package.json` version, which is what the Staging checklist means by "bump version".
Pass `--version X.Y.Z` for a patch release or any other explicit target.
</step>

<step id="2" name="Dry run">
```bash
~/.cursor/skills/develop-staging/scripts/develop-staging.sh --dry-run
```

Read the output in four parts and relay all four:

1. **Checklist preconditions.** Warnings for an open "New Crowdin updates" PR in `edge-react-gui` or
   `edge-login-ui-rn`, and for `react-native-zcash` / `react-native-piratechain` /
   `edge-currency-accountbased` pinned behind their published version. Each maps to a checklist
   subtask someone still has to do by hand.
2. **The bump.** The previous release's `(staging)` heading gets dated from the commit date of its
   `vX.Y.Z` tag, then `## <version> (staging)` opens above the accumulated entries. The commit touches
   `package.json`, `package-lock.json` and `CHANGELOG.md` and nothing else.
3. **The merge.** Conflicts, if any, with a classification per file.
4. **The parity gate.** Which paths still differ between staging and develop.
</step>

<step id="3" name="Handle a stop">
**Exit 10, conflicts outside CHANGELOG.md.** Each file is classified:

- *develop is a superset of staging* is the ordinary shape. It means a hotfix landed on staging and
  reached develop through a different commit, so the two histories disagree about lines they agree
  about textually. Taking develop's side loses nothing.
- *staging carries content develop lacks* is the one that matters. Something on staging never made it
  back to develop. Back-port it to develop first. This is the checklist's "Extra changes in staging?
  Need to ensure they're also in develop".

Show the operator the classification. On their say-so, re-run adding `--resolve-theirs <path>` per
file they cleared.

**Exit 11, non-CHANGELOG parity diff.** The two branches would not be equivalent. Show each path and
its diff. Two common causes:

- Genuine drift on one branch. Back-port it and re-run.
- The repo's own precommit chain: it runs `update-eslint-warnings` and the localize step, so
  `eslint.config.mjs` and `src/locales/strings` can be rewritten by the merge commit itself. That is
  an artifact, not drift. Once the operator confirms it, re-run with
  `--allow eslint.config.mjs` (repeat the flag per path).
</step>

<step id="4" name="Push">
With a clean dry run, re-run without `--dry-run`. The script confirms interactively before pushing;
`--yes` skips that prompt. It pushes the bump to `develop` first, then the merge to `staging`.

Never push these branches any other way. There is no PR in this flow: the merge goes straight to
`origin/staging`, which is how every prior develop-into-staging merge in this repo was done.
</step>

<step id="5" name="Report">
Tell the operator: the version, the bump commit, the merge commit, every precondition warning, and
anything cleared with `--allow` or `--resolve-theirs`. A cleared path is a decision worth recording,
not a detail to drop.
</step>

<params>
| Flag | Default | Meaning |
|---|---|---|
| `--repo <path>` | `$EDGE_GUI_DIR` or `~/git/edge-react-gui` | Repo to release |
| `--version X.Y.Z` | minor bump of develop's version | Explicit release version |
| `--prev-date YYYY-MM-DD` | commit date of tag `vX.Y.Z` | Date for a stale `(staging)` heading |
| `--dry-run` | off | Do everything except the two pushes |
| `--yes` | off | Skip the push confirmation |
| `--allow <glob>` | none | Parity path the operator has cleared (repeatable) |
| `--resolve-theirs <path>` | none | Take develop's side for a conflicted path (repeatable) |
| `--develop` / `--staging` | `develop` / `staging` | Branch names |
| `--remote <name>` | `origin` | Remote |
| `--keep-workspace` | off | Leave the temp worktree for inspection |

Exit codes: `0` done, `10` conflicts outside CHANGELOG.md, `11` non-CHANGELOG parity diff,
`12` preflight failed, `2` usage.
</params>

<edge-cases>
<case name="No `(staging)` heading to date">Normal. It means the previous release was already dated, so the script only opens the new section.</case>
<case name="No tag for the previous release">The script dates it today and says so. Re-run with `--prev-date` if that is wrong.</case>
<case name="CHANGELOG conflict the union cannot resolve">Only happens when the two sides order their release sections differently, which is a genuine editing mistake on one branch. The script stops. Fix the ordering on the source branch and re-run.</case>
<case name="Patch release off staging">This skill merges develop into staging. A hotfix that goes the other way is `/staging-cherry-pick`, not this.</case>
<case name="A repo other than edge-react-gui">The flow is generic (bump, open a section, merge, parity, push) but the precondition warnings are edge-react-gui's. Pass `--repo` and read the warnings as advisory.</case>
</edge-cases>
