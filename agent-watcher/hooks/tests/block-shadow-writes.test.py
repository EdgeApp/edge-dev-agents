#!/usr/bin/env python3
"""Vectors for hooks/block-shadow-writes.sh (Jev routing shadow runs).

Run: python3 ~/.config/agent-watcher/hooks/tests/block-shadow-writes.test.py
"""
import json, os, subprocess, sys

HOOK = os.path.expanduser("~/.config/agent-watcher/hooks/block-shadow-writes.sh")


def run(tool, cmd=None, shadow=True, hide=""):
    env = {k: v for k, v in os.environ.items() if k not in ("AGENT_SHADOW", "AGENT_TASK_GID", "AGENT_SHADOW_HIDE_PRS")}
    if hide:
        env["AGENT_SHADOW_HIDE_PRS"] = hide
    if shadow:
        env["AGENT_SHADOW"] = "1"
    payload = {"tool_name": tool, "tool_input": {"command": cmd} if cmd is not None else {}}
    return subprocess.run([HOOK], input=json.dumps(payload), capture_output=True, text=True, env=env).returncode


BLOCK = [
    "git push origin HEAD",
    "cd /x && git push -u origin shadow/1",
    "git -C /x/repo push",
    "git fetch origin develop",
    "git pull --rebase",
    "git ls-remote origin",
    "git remote set-url origin https://github.com/a/b",
    "gh pr create --title t --body b",
    "gh pr comment 12 --body hi",
    "gh issue create -t x",
    "gh api repos/a/b/issues/1/comments -f body=hi",
    "gh api -X PATCH repos/a/b/pulls/1",
    "gh api graphql -f query='mutation{}'",
    "~/.cursor/skills/one-shot/scripts/pr-create.sh --repo x",
    "~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh --task 1 --comment-file f",
    "~/.config/agent-watcher/update-status.sh 1 Complete",
    "timeout 60 ~/.config/agent-watcher/set-agent-field.sh 1 x y",
    "curl -X POST https://app.asana.com/api/1.0/tasks/1/stories",
    "curl -s https://slack.com/api/chat.postMessage -d x",
    "npm publish",
    "gh pr list --repo EdgeApp/edge-react-gui --search 'full balance'",
    "gh pr status",
    "gh search prs 'Revolut' --repo EdgeApp/edge-reports-server",
    "gh api repos/EdgeApp/edge-react-gui/pulls?head=EdgeApp:jon/x",
    "gh api 'repos/EdgeApp/edge-react-gui/pulls'",
    "gh api search/issues?q=revolut",
    "gh pr diff 227 --repo EdgeApp/edge-reports-server",
    "gh pr view 227",
]
PASS = [
    "git status",
    "git commit -m 'fix: thing'",
    "git log --oneline -5",
    "git diff origin/develop",
    "gh pr view 12",
    "gh api repos/a/b/pulls/1",
    "npx tsc --noEmit",
    "npx jest src/foo.test.ts",
    "echo 'the plan says git push origin HEAD, skipped'",
    "cat > report.md <<'EOF'\nSkipped: gh pr create and update-status.sh\nEOF",
    "grep -rn 'pr-create.sh' docs/",
    "gh pr diff 211 --repo EdgeApp/edge-reports-server | head -300",
    "gh api repos/EdgeApp/edge-reports-server/pulls/211/files",
    "echo 'see #227 later'",
]

fails = 0
for c in BLOCK:
    if run("Bash", c, hide="227") != 2:
        print("MISS  (should block):", c); fails += 1
for c in PASS:
    if run("Bash", c, hide="227") != 0:
        print("FALSE (should pass): ", c); fails += 1
for t in ("ScheduleWakeup", "CronCreate", "mcp__claude_ai_Asana__add_comment", "mcp__claude_ai_Slack__slack_send_message", "mcp__plugin_product-management_slack__authenticate"):
    if run(t) != 2:
        print("MISS  (should block):", t); fails += 1
for t in ("mcp__maestro__run", "Read"):
    if run(t) != 0:
        print("FALSE (should pass): ", t); fails += 1
# off outside a shadow run
if run("Bash", "git push origin HEAD", shadow=False) != 0:
    print("FALSE (non-shadow session blocked)"); fails += 1
if run("mcp__claude_ai_Asana__add_comment", shadow=False) != 0:
    print("FALSE (non-shadow MCP blocked)"); fails += 1

n = len(BLOCK) + len(PASS) + 9
print(f"{n - fails}/{n} vectors ok")
sys.exit(1 if fails else 0)
