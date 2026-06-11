---
name: agent-orchestration
description: "Jon's in-progress autonomous agent orchestration project (agent-watcher + one-shot run reports)"
metadata:
  node_type: memory
  type: project
  originSessionId: 0c8256a3-90a6-4a73-9002-9118441c36fd
---

Jon is building an autonomous agent orchestration system (ongoing, evolving — keep this high-level, expect details to change).

- **Topology:** TWO Macs on the same Claude login. Jon's interactive sessions run on his local dev Mac, "jontz"; the remote Mac "eddy" runs the agent-watcher background tasks and spawns the remote-control agent sessions. There is NO ssh access to eddy (and `openclaw` in ssh config is NOT it — do not assume ssh targets are the orch machine). Files/secrets must reach eddy by other means (Jon manually, Universal Clipboard/AirDrop, pasting into a Claude session running there, or committing to edge-dev-agents and pulling).
- **Driver:** `~/.config/agent-watcher/` watches Asana tasks and spawns Claude/Codex agent sessions into per-task git worktrees, with pooled iOS sims, resource/OOM watchdog (`session-watchdog.js`), and slot management. Asana custom fields (`agent_status`, `blocked`) are the run-state channel — not comments. Worktree setup copies `env.json` and `testconfig.json` from the main checkout; other gitignored configs do NOT propagate to worktrees unless added in `setup-task-workspace.sh`.
- **Per-task agent flow:** the `/one-shot` skill runs Planning → Developing → Reviewing → Testing → Complete, delegating to `/asana-plan`, `/im`, `/pr-create`, `/build-and-test`.
- **Completion documentation:** at the terminal state (complete or blocked), the agent fills `~/.cursor/skills/one-shot/templates/agent-run-report.md` and attaches it to the Asana task via `asana-task-update.sh --attach-file` (one attachment, at most one pointer comment). Report sections feed back into the system: Skill Gaps → `/author`, Orchestration Issues → harness fixes, Follow-ups & Risks → actionable proposals.
- **Convention sync:** skills/rules/scripts are authored under `~/.cursor/` and synced to the `edge-dev-agents` repo via `/convention-sync`; `~/.claude/CLAUDE.md` is generated from always-apply cursor rules (don't hand-edit it).
