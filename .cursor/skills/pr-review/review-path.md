# code-review-sonnet: fan-out anatomy

The engine behind /pr-review's deep mode (`~/.claude/workflows/code-review-sonnet.js`,
level-parity re-pin from Claude Code 2.1.232). The typed level IS the fan-out agents'
reasoning effort; `angles=N` widens or narrows the correctness fan-out independently.
Scope and Synthesize inherit the session model; everything between them is pinned
Sonnet at the level's effort.

```mermaid
flowchart LR
    sc["`**Scope**
    session model`"]

    aA["`**angle-A**
    line-by-line`"]
    aB["`**angle-B**
    removed behavior`"]
    aC["`**angle-C**
    cross-file callers`"]
    aD["`**angle-D** pitfalls
    xhigh/max, angles≥4`"]
    aE["`**angle-E** wrappers
    xhigh/max, angles=5`"]
    cl["`**cleanup ×1**
    5 merged lenses`"]

    sc --> aA & aB & aC & cl
    sc -.-> aD & aE
    aA & aB & aC & aD & aE & cl --> pool["`**pool** barrier
    ≤perAngle each
    group by file:line`"]

    pool --> ver["`**Verify** Sonnet
    1 per location
    keep C+P only`"]
    ver --> syn["`**Synthesize**
    rank, merge, cap
    session model`"]
    ver -.->|"xhigh/max"| swp["`**Sweep ×1**
    gaps ≤8, re-verify`"] -.-> syn
```

All finder/verifier/sweep agents run pinned Sonnet at the level's effort; Scope and
Synthesize inherit the session model. Dashed = level-gated.

Per-level dials (`LEVEL_PARAMS`):

| Level | Effort (fan-out) | Correctness angles | Cands/angle | Verify | Sweep | Report cap |
|---|---|---|---|---|---|---|
| low | medium (sonnet quirk) | single-pass: 1 finder, all lenses | 8 total | none | no | 4 |
| medium | medium | 3 (A-C) | 6 | plain ladder | no | 8 |
| high | high | 3 (A-C) | 6 | recall-biased | no | 10 |
| xhigh | xhigh | 5 (A-E) | 8 | recall-biased | yes | 15 |
| max | max | 5 (A-E) | 8 | recall-biased | yes | 15 |

Reading notes:

- An angle is a finder's assigned lens; each correctness angle is its own parallel
  agent. `angles=N` (1-5) moves the A-E cutoff independently of level.
- Cleanup stays ONE merged finder whose candidate budget (5×perAngle) matches the
  official build's five separate cleanup-family finders — the clone's one structural
  divergence.
- Verifier count tracks distinct (file,line) locations, not finder count. Grouping is
  not dedup: every candidate keeps its own verdict; semantic merging happens in
  Synthesize. A location's verifier dying drops that location's candidates rather
  than passing them unverified.
- Verify framing: medium judges on the plain verdict ladder (precision); high and
  above add the recall bias.
- Low is the official single-pass cell: no fan-out, no verify, precision by
  construction.
- Not cloned: ultra (cloud, user-triggered), the diff-size finder-budget hint,
  non-sonnet per-model prompt cells.
