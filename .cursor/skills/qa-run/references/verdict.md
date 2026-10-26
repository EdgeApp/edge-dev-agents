# QA verdict

<rules>
<rule id="plain-comment">The comment is for the operator: plain words, no bare identifiers, no em dashes, /no-slop. Lead with the verdict, then the case table, then the not-covered list.</rule>
<rule id="failed-cases-section">A Failed report carries `## Failed cases`, one subsection per failed case with steps, expected vs actual, the source of the expectation and the proof frame. The dev followup takes exactly this section as its scope.</rule>
</rules>

<step id="1" name="Write the report">
`/tmp/qa-report-<gid>.md`:
```markdown
---
verdict: Passed            # Passed | Blocked | Failed
blocker_class: harness     # Blocked only: precondition | harness | task-drafting
---

# QA report

## Verdict

<one paragraph>

## Environment

Account, sim, app build (cache hit or rebuilt), runtime switches used and reverted.

## Cases

| Case | Expected | Actual | Result | Proof |
|---|---|---|---|---|

## Failed cases

### C<n> <title>

Steps, expected (source), actual, proof frame.

## Not covered

## Plan

<the approved plan, verbatim>
```
Omit `## Failed cases` unless the verdict is Failed.
</step>

<step id="2" name="Write the comment">
`/tmp/qa-comment-<gid>.txt`: one line with the verdict and why, the case table in plain words (case, what was tried, result), then the not-covered list.
</step>

<step id="3" name="Post">
```bash
~/.cursor/skills/qa-run/scripts/qa-verdict.sh --verdict <Passed|Blocked|Failed> --report /tmp/qa-report-<gid>.md --comment /tmp/qa-comment-<gid>.txt
```
1. Exit 0 → end the turn.
2. Exit 1 → fix each failed item. A Failed verdict denied on V2 is reposted as Blocked with the class the item names.
3. Exit 3 or 4 → core edge cases.
</step>
