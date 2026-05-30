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

## Tooling: `-p`/headless vs interactive

Prefer interactive (tmux-driven) sessions for anything long-lived or high-volume;
reserve `claude -p` (headless) for one-off, low-volume verification where a clean
programmatic assertion matters (stdout / `--output-format json` / exit code).
- `-p` gives clean captured output, a real completion + structured result; tmux
  scraping (`capture-pane`) is fragile — ANSI, timing/no done-signal, scrollback
  truncation. So `-p` is the right tool for a crisp one-off test assertion.
- BUT post-2026-06-15, `-p`/Agent-SDK use on a Pro/Max subscription meters against
  a separate SDK credit pool (API rates), not the subscription. Negligible for a
  few probes; it bites at volume. Interactive use stays on the subscription.
- Jon's orchestration spawns interactive `claude --rc` in tmux (NOT `-p`) →
  billing-exempt; keep it that way. Don't convert the fleet to `-p`.
