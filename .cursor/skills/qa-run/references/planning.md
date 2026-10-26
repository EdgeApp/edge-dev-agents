# QA planning phase

<rules>
<rule id="no-sim-in-planning">This phase drives nothing. Read, probe servers with `curl`, and write the plan. The session's sim (`AGENT_SIM_UDID`) stays untouched until the gate allows the plan; never boot, clone or allocate another.</rule>
<rule id="account-parity">The plan's account is the one the dev run's environment line names (the roster `agent` role by default). Another roster account, or a fresh throwaway, only when a named case needs it.</rule>
<rule id="probe-before-plan">Probe every server or provider a case touches now. An unreachable dependency moves its case to the not-covered list with the probe result.</rule>
</rules>

<step id="1" name="Ingest">
Run in parallel:
```bash
~/.cursor/skills/asana-get-context.sh <gid>
gh pr diff <PR_URL>
gh pr view <PR_URL> --json body -q .body
```
Read every `<N>-report.md` under `/tmp/asana-task-<gid>/`: its Testing section, `verify_blockers`, not-tested list and environment line (account, asset, funding, provider forcing). A `<N>-qa-report.md` there is an earlier QA pass: its cases are covered.
</step>

<step id="2" name="Coverage map and cases">
List every behavior the diff changes, each marked `dev` (cite the report line or screenshot) or `uncovered`. Candidates are the uncovered rows plus boundaries on covered paths: zero or max balance, token vs mainnet, Back after a provider redirect, an error the app can receive without code edits, a second wallet, a sibling asset. Keep a candidate only per the core rule `beyond-dev-never-repeat`, and keep at most 5. The only funds limit is the pass's $20 budget in USD fees: a swap keeps its value as another asset, so only swap and network fees count. Fund a case with as many swaps as it takes (several pairs to reach the target asset, another swap when a case consumes it). A candidate needing a hack goes to the not-covered list with its reason.
</step>

<step id="3" name="Write PLAN_FILE">
```markdown
---
decision: cases            # or skip
lane: ios                  # ios | android | none
account: <roster role or "new: <case id>">
skip_reason: <one line>    # skip only
---

## Coverage map

| Behavior | Covered by | Evidence |
|---|---|---|

### C1 <title>

- Scenario:
- Preconditions: account, asset, amount, wallet state
- Steps:
- Expected: <result> (source: task | spec | prior app behavior)
- Why dev did not cover it:
- Cost: estimated fees in USD, minutes

## Funds

<per case: target asset, amount, and the swap chain that funds it, including refunds when a case consumes the asset; total estimated fees in USD>

## Not covered

- <case idea>: <reason>
```
A skip plan keeps the coverage map and the not-covered list and has no `### C` headings. Then run `qa-gate.sh` (core step 2).
</step>
