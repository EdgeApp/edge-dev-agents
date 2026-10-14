#!/usr/bin/env python3
"""Contract tests for block-sim-wipe.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/block-sim-wipe.test.py

The hook stops a task session from running `simctl uninstall` or `simctl
erase`, which delete the logged-in test account on the simulator. It reads the
line through cmd-parse.sh, so two properties hold:

  1. The wipe blocks wherever the line runs it: behind xcrun and its options,
     behind simctl's own --set <path>, after another command, in a loop body,
     inside `bash -c` text.
  2. A line that only names the wipe passes: a grep, an echo, a heredoc, a
     comment, another simctl verb, a path or an argument spelled "erase".

Outside a task session (no AGENT_TASK_GID) the hook is silent.
"""
import json, os, subprocess, sys, tempfile

HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/block-sim-wipe.sh')

BLOCKS = [
    ('xcrun simctl uninstall', 'xcrun simctl uninstall booted co.edgesecure.app'),
    ('bare simctl erase', 'simctl erase all'),
    ('absolute simctl path', '/usr/bin/simctl erase U1'),
    ('xcrun option before simctl', 'xcrun --sdk iphonesimulator simctl uninstall U1 a.b'),
    ('simctl --set before the verb', 'xcrun simctl --set /tmp/devs erase all'),
    ('after another command', 'xcrun simctl boot U1 && xcrun simctl uninstall U1 a.b'),
    ('uninstall then install', 'xcrun simctl uninstall U1 a.b; xcrun simctl install U1 /p/Edge.app'),
    ('env assignment in front', 'DEVELOPER_DIR=/x xcrun simctl erase U1'),
    ('inside a condition body', 'if true; then xcrun simctl erase U1; fi'),
    ('inside a loop body', 'for u in A B; do xcrun simctl uninstall $u a.b; done'),
    ('inside a subshell', '(cd /tmp && xcrun simctl erase U1)'),
    ('inside bash -c text', "bash -c 'xcrun simctl uninstall U1 a.b'"),
    ('inside a substitution', 'OUT=$(xcrun simctl erase U1 2>&1); echo "$OUT"'),
    ('an echo in front no longer excuses it', 'echo start; xcrun simctl erase U1'),
    ('a grep in front no longer excuses it', 'grep -c x f; xcrun simctl uninstall U1 a.b'),
    ('behind timeout', 'timeout 60 xcrun simctl erase U1'),
]

PASSES = [
    ('simctl install', 'xcrun simctl install U1 /p/Edge.app'),
    ('simctl list piped to grep', 'xcrun simctl list devices | grep erase'),
    ('grep for the phrase', 'grep -rn "simctl uninstall" ~/.config/agent-watcher'),
    ('echo of the phrase', 'echo "never run xcrun simctl erase"'),
    ('heredoc naming it', "cat > /dev/null <<'E'\nxcrun simctl uninstall U1 a.b\nE"),
    ('commented', 'ls # xcrun simctl erase U1'),
    ('--set path named erase', 'xcrun simctl --set /tmp/erase list'),
    ('an app id named uninstall', 'xcrun simctl launch U1 uninstall'),
    ('eval text is not read', 'eval "xcrun simctl erase U1"'),
    ('the sanctioned reinstall script', '~/.config/agent-watcher/sim-app-reinstall.sh --udid U1 --app /p/Edge.app'),
    ('a mention inside bash -c text', "bash -c 'echo \"simctl erase\"'"),
    ('unrelated', 'ls -la && cat README.md'),
]


def run(cmd, off, task=True):
    env = dict(os.environ, JEV_SHADOW_ROOT=off)
    env.pop('AGENT_TASK_GID', None)
    if task:
        env['AGENT_TASK_GID'] = '1111111111'
    p = subprocess.run(['bash', HOOK], input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': cmd}}),
                       capture_output=True, text=True, env=env, timeout=30)
    return p.returncode, p.stderr


def main():
    fails = []
    with tempfile.TemporaryDirectory() as off:
        # An OFF file keeps the log-only shadow queue out of the test.
        open(os.path.join(off, 'OFF'), 'w').close()
        for name, cmd in BLOCKS:
            rc, err = run(cmd, off)
            ok = rc == 2 and 'BLOCKED' in err
            print(f"{'ok  ' if ok else 'FAIL'} blocks: {name} (exit {rc})")
            if not ok:
                fails.append(name)
        for name, cmd in PASSES:
            rc, err = run(cmd, off)
            ok = rc == 0 and not err.strip()
            print(f"{'ok  ' if ok else 'FAIL'} passes: {name} (exit {rc})")
            if not ok:
                fails.append(name)
        rc, err = run('xcrun simctl erase all', off, task=False)
        ok = rc == 0
        print(f"{'ok  ' if ok else 'FAIL'} silent outside a task session (exit {rc})")
        if not ok:
            fails.append('outside a task session')
    if fails:
        print(f'{len(fails)} failing: {fails}')
        sys.exit(1)
    print('all cases pass')


if __name__ == '__main__':
    main()
