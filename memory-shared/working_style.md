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

## Tooling & cost: interactive vs `-p`/headless

**Guiding principle: be cost-conscious — squeeze the most out of the Max
subscription WITHOUT incurring extra (pay-as-you-go) cost.** That's the real goal;
the `-p` mechanics below are just how to honor it.

- **Interactive Claude Code** — including the orchestration's tmux `claude --rc`
  sessions — runs on the subscription with no extra metering. Prefer it for
  anything long-lived or high-volume. Keep the agent fleet interactive; do NOT
  convert it to `-p`.
- **`-p` / headless (Agent SDK)** on a Pro/Max sub draws from a **monthly INCLUDED
  credit allotment** (resets monthly, no rollover — Max-20x $200, Max-5x $100,
  Pro $20; confirm current plan). Up to that allotment it's effectively free; you
  only pay extra (pay-as-you-go API rates) AFTER it's exhausted, and only if
  overflow/usage-credits is enabled. This split takes effect ~2026-06-15.
- So `-p` is fine for occasional, low-volume one-off verification (well within the
  monthly credit) where a clean programmatic assertion matters — and it's cleaner
  than tmux scraping (stdout / `--output-format json` / exit code vs fragile
  `capture-pane`). Avoid high-frequency `-p` loops that would burn the allotment
  into paid overflow.
- Monitor remaining credit at `claude.ai/settings/usage` (the SDK's
  `total_cost_usd` is a client-side estimate, not authoritative).
