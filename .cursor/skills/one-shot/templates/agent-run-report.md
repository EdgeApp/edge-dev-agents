---
task_gid: ""
task_name: ""
agent_session_uuid: ""   # $AGENT_SESSION_UUID — the orchestration session that produced this run
orch_version: ""         # $AGENT_ORCH_VERSION — digest of the orch (skills/rules/watcher/hooks) governing this segment
repo: ""
branch: ""
base: origin/develop
pr: none                 # PR URL, or "none"
outcome: complete        # complete | partial | blocked
verified: not-run        # pass | partial | not-run | fail
verify_blockers: []      # any of: precondition | harness | code | task-drafting
started: ""              # ISO 8601
ended: ""                # ISO 8601
skills_used: []          # e.g. [asana-plan, im, pr-create, build-and-test, debugger]
slot_index: null         # from `node ~/.config/agent-watcher/lib/slots.js get --task-gid <gid>`
metro_port: null         # $AGENT_METRO_PORT
sim_udid: ""             # $AGENT_SIM_UDID
---

## Summary
<!-- cat: summary -->
<!-- 3-6 SHORT BULLETS: what was asked, what shipped, final state, links.
     FORMAT, whole report: bullets and short sections over prose blocks — a
     reviewer scans this, they don't read it. No paragraph longer than 2 lines.
     ALL prose in this report follows /no-slop (~/.cursor/skills/no-slop/SKILL.md):
     no em-dashes, no courtesy enders, no self-grading or announcement sentences. -->
_None observed._

## Finalize Gate
<!-- cat: finalize-gate -->
<!-- The completion evidence as a CHECKLIST — one line per gate condition, checked
     only if verified against LIVE state at finalize time (each unchecked box needs
     a one-line reason). This is the structured mirror of one-shot `finalize-gate`;
     the eval cross-checks every box against GitHub/Asana (a checked box that
     contradicts live state is a report-honesty finding). Per PRIMARY PR:
       - [ ] CI checks green on HEAD (`gh pr checks`)
       - [ ] every reviewer bot completed-clean on HEAD (SUCCESS/skipped; not NEUTRAL)
       - [ ] zero unresolved review threads (bot AND human)
       - [ ] landed or auto-merge armed (per `land-on-approval`) / stopped at PR (say which)
       - [ ] Build field routing done (cheese pushed / staging noted / none)  -->
_None observed._

## Testing
<!-- cat: testing -->
<!-- HOW this run actually verified the change — concrete and reproducible, so a
     reviewer can see what was exercised and trust (or challenge) the `verified`
     frontmatter. This is the visibility surface for test completeness: NEVER leave
     it thin. Fill it even when verification was static-only or blocked (say which).
     Draw from the /build-and-test run. Cover, in order:
       - What was exercised: the real end-to-end user action driven to its TERMINAL
         success state (per build-and-test `test-drives-the-real-action`), e.g.
         "BTC->AVAX SideShift swap executed to the order-submitted scene." If it
         stopped short, name the exact step reached and why.
       - Method: static checks run WITH results (tsc / jest / eslint / verify-repo);
         sim build flavor; the maestro flow(s) run (path) and whether driven via MCP
         exploration or a single yaml proof run; any /debugger breakpoints used.
       - Environment: sim UDID + slot, roster account used and any mid-test switch
         (via env.json), funding (asset + amount, any swap-to-fund a major), and any
         provider forced + whether reverted.
       - Evidence: the proof screenshot paths (`/tmp/agent-proof-<gid>-NN-slug.png`)
         and confirmation they are attached to the PR; name the success-scene frame.
       - Fallback (ONLY if in-app execution was blocked): the gated direct
         verification used (live-API / boot-time plugin-init) per the sim-testing
         playbook Fabric-SIGABRT entry, and a note that it followed a GENUINE funded
         attempt that hit the crash, not a first resort.
       - Not tested / preconditions: what could NOT be verified here and why (mirror
         `verify_blockers`), so the residual risk is explicit. -->
_None observed._

## Decisions
<!-- cat: decisions -->
<!-- Consequential / non-obvious choices only. Each: the decision, the rejected
     alternative, and why. In --yolo this also captures auto-deferred decisions
     (question, default chosen). Do NOT annotate a choice as reversible — that's
     the default and saying it is noise; note reversibility ONLY when a choice was
     IRREVERSIBLE. -->
_None observed._

## Dev Notes & Gotchas
<!-- cat: dev-notes-gotchas -->
<!-- Reusable codebase/product knowledge for the next agent on this repo. Prefix each
     bullet with an inline tag for later slicing:
       [build]  how to build/prepare/install for this work, what was actually needed
       [test]   how to verify this area, preconditions, what a real test run requires
       [debug]  debugging method that worked (e.g. CDP/debugger usage)
       [gotcha] surprising behavior, footgun, non-obvious constraint
       [playbook] PROPOSED sim-testing-playbook entry. SCOPE TIGHTLY (per
                build-and-test maestro-flows-are-shortcuts): only SIM-TESTING
                working knowledge (how to drive/fund/enable/verify a change in the
                running app) that is a stable external fact AND parallel-safe (no
                fixed-port/shared-resource recipe — propose the slot-safe variant or
                a warning). NOT for orchestration/watchdog/eval-tooling concerns or
                one-off specifics — those go in Orchestration Issues / Skill Gaps.
                Write the entry text ready to promote. NEVER edit the playbook
                directly; the operator reviews and promotes (collected by
                /agent-eval). -->
_None observed._

## Orchestration Issues
<!-- cat: orchestration -->
<!-- Friction with the autonomous harness itself (NOT the task code): worktree /
     env.json / sim / metro / ports / resume / tmux / wakeup / resource limits /
     auth in the spawned env. Enough detail to reproduce or fix. -->
_None observed._

## Skill Gaps
<!-- cat: skill-gaps -->
<!-- Per skill: name + what was missing / ambiguous / wrong / didn't trigger when it
     should have + a concrete suggested fix. Feeds /author. -->
_None observed._

## Task-Drafting Feedback
<!-- cat: task-drafting -->
<!-- What the task description got right or wrong. Info the agent had to guess or hunt
     for (creds, paths, acceptance criteria, scope bounds, push/no-push, required
     account/KYC/funds preconditions). What to include in the next task of this kind. -->
_None observed._

## Follow-ups & Risks
<!-- cat: follow-ups -->
<!-- Forward-looking items the task surfaced but did not (and should not) resolve:
     out-of-scope fixes, tech debt, future work, risks. Write each as an ACTIONABLE
     proposal a reviewer can approve at a glance — not a vague observation. Omit
     low-confidence hunches. One subsection per item, in this shape:

       ### <imperative title, e.g. "Reset provider singletons on logout">
       - **What & why:** 1-2 lines — the change and the reason it matters.
       - **Where:** `path/to/file.ts:line`, PR, or area.
       - **Proposed action:** the concrete change + the owner skill to carry it
         (e.g. /author for a skill/rule, /im for code, /pr-address for review threads).
       - **Confidence:** high | medium (drop low-confidence items entirely).

     Keep to real, high-signal items. Use _None observed._ if there are none. -->
_None observed._
