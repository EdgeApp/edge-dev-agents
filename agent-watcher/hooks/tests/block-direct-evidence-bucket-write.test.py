#!/usr/bin/env python3
"""Vectors for hooks/block-direct-evidence-bucket-write.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/block-direct-evidence-bucket-write.test.py
"""
import json, os, subprocess, sys

HOOK = os.path.expanduser("~/.config/agent-watcher/hooks/block-direct-evidence-bucket-write.sh")
B = "~/.cursor/skills/pr-create/scripts/evidence-bucket"
CREDS = "~/.config/site-orch/secrets/r2.json"


def run(cmd, task=True, tool_input=None):
    env = {k: v for k, v in os.environ.items() if k != "AGENT_TASK_GID"}
    if task:
        env["AGENT_TASK_GID"] = "1200000000000001"
    payload = {"tool_name": "Bash", "tool_input": {"command": cmd} if tool_input is None else tool_input}
    p = subprocess.run([HOOK], input=json.dumps(payload), capture_output=True, text=True, env=env)
    return p.returncode, p.stderr


BLOCK = [
    f"{B}.sh put widget7/001-x.png /tmp/x.png",
    f"{B}.sh manifest-put acme/widget 7 /tmp/m.json",
    f"{B}.sh delete widget7/001-x.png",
    f'"$HOME/.cursor/skills/pr-create/scripts/evidence-bucket.sh" put k /tmp/x.png',
    f"cd /tmp && {B}.sh put k x.png",
    f"ls /tmp; {B}.sh delete k",
    f"timeout 60 {B}.sh put k x.png",
    f"EVIDENCE_BUCKET_CONFIG=/tmp/c.json {B}.sh put k x.png",
    f"bash {B}.sh put k x.png",
    f"node {B}.js put k x.png",
    f"node {B}.js delete k",
    f"{B}.sh exists k || {B}.sh put k x.png",
    f"{B}.sh 'put' k x.png",
    f"cat {CREDS}",
    f"jq -r .secretAccessKey {CREDS}",
    f"curl --aws-sigv4 aws:amz:auto:s3 -K <(jq -r .accessKeyId {CREDS}) https://example.test/b/k",
    f"node -e 'console.log(require(process.argv[1]))' {CREDS}",
    f"cp {CREDS} /tmp/c.json",
]

ALLOW = [
    f"{B}.sh check",
    f"{B}.sh exists widget7/001-x.png",
    f"{B}.sh get widget7/001-x.png /tmp/x.png",
    f"{B}.sh list widget7/",
    f"{B}.sh url widget7/001-x.png",
    f"{B}.sh manifest-get acme/widget 7 /tmp/m.json",
    f"{B}.sh manifest-key acme/widget 7",
    f"node {B}.js list widget7/",
    "~/.cursor/skills/pr-create/scripts/pr-attach-screenshots.sh --repo acme/widget --pr 7 /tmp/a.png",
    "~/.cursor/skills/pr-create/scripts/pr-evidence-withdraw.sh --repo acme/widget --pr 7 wallet-list",
    f"grep -n 'put' {B}.js",
    f"rg -n delete {B}.sh",
    f"sed -n 1,40p {B}.js",
    f'echo "never run {B}.sh put by hand"',
    f"cat > /tmp/note.md <<'EOF'\nthe attach script calls {B}.sh put k f\n{B}.sh delete k\nEOF",
    f'git commit -m "Stop calling evidence-bucket.sh delete directly"',
    f"ls -l {CREDS}",
    f"grep -rn 'site-orch/secrets/r2.json' ~/.cursor/skills",
    "git push origin HEAD",
    "",
]

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        fails += 1


for c in BLOCK:
    rc, err = run(c)
    check(f"block: {c[:90]!r}", rc == 2, f"rc={rc} {err[:200]}")
    check("  the refusal names the rule and both compliant scripts",
          rc != 2 or all(x in err for x in ("evidence-bucket-write-funnel", "pr-attach-screenshots.sh", "pr-evidence-withdraw.sh")), err[:200])
for c in ALLOW:
    rc, err = run(c)
    check(f"allow: {c[:90]!r}", rc == 0, f"rc={rc} {err[:200]}")
for c in BLOCK[:3]:
    check(f"no task gid, no-op: {c[:60]!r}", run(c, task=False)[0] == 0)
check("a payload with no command passes", run(None, tool_input={})[0] == 0)

print(f"\n{fails} failure(s)" if fails else "\nall passed")
sys.exit(1 if fails else 0)
