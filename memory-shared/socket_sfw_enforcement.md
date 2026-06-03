---
name: socket-sfw-enforcement
description: Jon's local npm supply-chain guard — sfw (Socket Firewall) via PATH shims + agent hooks, and the fork-bomb gotcha
metadata:
  type: project
---

Jon's machines wrap every `npm`/`npx`/`pnpm`/`yarn` call through **sfw (Socket Firewall Free)**, not the `socket` CLI (migrated 2026-06-02). Three pieces, all rooted at `$HOME` so they are user-agnostic:

- **PATH shims** at `~/.agent-shims/{npm,npx,pnpm,yarn}` — each strips `~/.agent-shims` from PATH, then `exec sfw <tool>`. The shim dir is prepended to PATH in `.zshenv`/`.zprofile` and (last, after nvm init) in `.zshrc`.
- **Agent hooks**: `~/.claude/settings.json` PreToolUse(Bash) and `~/.cursor/hooks.json` beforeShellExecution both run `~/.agent-tools/socket-guard.mjs`, which denies bare npm/npx/pnpm/yarn and tells the agent to use `sfw npm` instead.
- **`~/.npmrc` hardenings**: `ignore-scripts=true`, `fund=false`. `min-release-age` is intentionally DISABLED (commented out) due to a bug — do not re-enable without asking.

**THE GOTCHA (non-obvious; took a careful empirical test to find):** `sfw` resolves its wrapped package-manager command via PATH. So a naive shim `exec sfw npm` fork-bombs: npm→shim→sfw→npm→shim→sfw… Each shim MUST strip its own dir from PATH first so sfw's inner call lands on the real binary. The old `socket` CLI did NOT need this (it resolved the real npm internally). Verified 2026-06-02.

Layer 3 (network sandbox / sfw enterprise proxy) is NOT installed — no enterprise license. The setup is the local file-based one above only. There is a full handoff doc for replicating this on another machine at `~/sfw-handoff.md`.

See also [[working-style]] (verify empirically, not just wired up).
