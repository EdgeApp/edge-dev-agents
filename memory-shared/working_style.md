---
name: working-style
description: "'Until done' = take it all the way to a SUCCESSFUL TEST (verify empirically, not just 'wired up'); don't stop mid-task to ask — proceed with a sensible default and present deferred decisions as alternatives at the end"
metadata:
  node_type: memory
  type: preference
  originSessionId: 0c8256a3-90a6-4a73-9002-9118441c36fd
---

When Jon says "continue until done" / "until done" (or similar persistence
directives), **"done" means carried all the way to a SUCCESSFUL TEST** — not
just implemented, wired up, or plumbed. Verify behavior empirically (actually
run it and observe the result); "looks correct" or "files are in place" is not
done.

**Defer decisions to the end.** Do not halt mid-task to ask which option to
take. When a genuine decision or uncertainty arises, pick a sensible default,
proceed, and keep going to a tested result. Collect the open decision points and
present them at the END as alternatives to try — don't block on them mid-stream.

Learned from the memory/orchestration task: the failure modes were (1) stopping
at plumbing instead of empirically testing, and (2) hedging mid-way (e.g.
supporting both options) instead of proceeding and deferring the choice.
