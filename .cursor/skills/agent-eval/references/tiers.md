# Tiers: who pays when a finding is real

Findings and the remediation rows drawn from them are grouped by tier, never merged into one global ranking. Within a tier the order is: approved-but-unbuilt classes first (the operator already ruled; every further cohort re-finds them), then recurrence since the class's last fix, descending. Gates (A3, A16, O2, O3) stay above every tier. A finding's tier comes from its dimension; a remediation class with no dimension (an infra footgun, a script defect) takes the tier of the consequence it causes, from the Classes column. `~/.cursor/skills/eval-run/scripts/actions-ledger.sh` reads this table.

| Tier | Name | Who pays | Dimensions | Classes without a dimension |
|---|---|---|---|---|
| 1 | Trust | the operator acts on a false claim | A3, A8, A15, A20, A22, A26, A35, O9 | fabricated citations, silent post-Complete rework, a gate that lets a completion through unjudged |
| 2 | Lost scope | work the task owed vanishes or ships wrong | A7, A14, A21, A23, A24, A25, A27, A32 | watermark breaks that hide asks from the next run, tested-field credit dropped by a later segment |
| 3 | Budget | runs burn time and tokens | A5, A6, A16, A17, A19, A29, O1, O2, O3, O4, O5, O6, O7, O8, O10 | hook false positives, stale workspaces, MCP or sim drift, re-runs, budget collisions |
| 4 | Hygiene | nobody yet; the record gets harder to read | A1, A2, A4, A9, A10, A11, A12, A13, A18, A30, A31, A33, A34 | commit shape, report form, doc placement |
