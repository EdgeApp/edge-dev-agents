#!/usr/bin/env python3
"""Contract tests for the operator hold: operator-hold.sh, the prompt hook, the gate.

Run: python3 ~/.config/agent-watcher/hooks/tests/operator-hold.test.py

The model (2026-09-09 simplification): held means the stamp file exists, no TTL,
no owner. A human prompt sets it; a prompt whose first word (after ok/yes/sure/
please) is go/resume/continue/proceed releases it. Machine prompts touch nothing.
While held the gate blocks status transitions, pushes (raw and via
git-branch-ops.sh / pr-finalize-fixups.sh) and PR actions.

The prompt hook is run under a temp HOME whose agent-watcher dir carries the
real scripts but NO orch-run-context.sh, so the in-flight-run check is skipped
(this test is not a tmux run session).
"""
import json, os, shutil, subprocess, sys, tempfile

AW = os.path.expanduser('~/.config/agent-watcher')
GID = '7777777777'
STAMP = f'/tmp/agent-operator-hold-{GID}'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


tmp = tempfile.mkdtemp(prefix='hold-')
home = os.path.join(tmp, 'home')
os.makedirs(os.path.join(home, '.config/agent-watcher/hooks'))
for f in ('operator-hold.sh', 'cmd-executes.sh'):
    src = os.path.join(AW, f) if f == 'operator-hold.sh' else os.path.join(AW, 'hooks', f)
    dst = os.path.join(home, '.config/agent-watcher', f) if f == 'operator-hold.sh' else os.path.join(home, '.config/agent-watcher/hooks', f)
    os.symlink(src, dst)
for f in ('operator-hold-prompt.sh', 'operator-hold-gate.sh', 'strip-cmd-mentions.sh'):
    os.symlink(os.path.join(AW, 'hooks', f), os.path.join(home, '.config/agent-watcher/hooks', f))
ENV = dict(os.environ, HOME=home, AGENT_TASK_GID=GID)


def prompt(text):
    p = subprocess.run([os.path.join(home, '.config/agent-watcher/hooks/operator-hold-prompt.sh')],
                       input=json.dumps({'prompt': text}), capture_output=True, text=True, env=ENV)
    return p.stdout


def held():
    return os.path.exists(STAMP)


def gate(cmd):
    p = subprocess.run([os.path.join(home, '.config/agent-watcher/hooks/operator-hold-gate.sh')],
                       input=json.dumps({'tool_input': {'command': cmd}}), capture_output=True, text=True, env=ENV)
    return p.returncode


try:
    if os.path.exists(STAMP):
        os.remove(STAMP)
    RELEASE = ['go', 'Go.', 'ok go', 'Yes, proceed', 'resume, and fix X when you are done', 'continue', 'go ahead and push', 'GO: looks good']
    HOLD = ['looks good, go ahead', 'lgtm, continue', 'yes do it', 'continue with the data fix instead'.replace('continue', 'work'),
            'approved', 'ship it', 'no, hold on', 'what does the fee row show?']
    for t in RELEASE:
        prompt('anything')  # ensure held first
        out = prompt(t)
        check(f'release: {t!r}', (not held()) and 'released' in out, f'held={held()} out={out[:60]!r}')
    for t in HOLD:
        if held():
            os.remove(STAMP)
        out = prompt(t)
        check(f'hold: {t!r}', held() and 'steering' in out, f'held={held()} out={out[:60]!r}')

    os.remove(STAMP)
    machine = ['<task-notification>\n<task-id>abc</task-id>\n<status>completed</status>\n</task-notification>',
               '<system-reminder>Note: /x changed on disk since you last read it.</system-reminder>',
               '<watchdog-revive-ping> hello', '/one-shot https://app.asana.com/x --yolo']
    for t in machine:
        out = prompt(t)
        check(f'machine prompt does not stamp: {t[:40]!r}', not held() and out == '', f'held={held()} out={out[:60]!r}')

    # oracle semantics: exists = held, no TTL
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'set', GID])
    os.utime(STAMP, (0, 0))
    p = subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'status', GID], capture_output=True, text=True)
    check('status: an old stamp is still held (no TTL)', p.returncode == 0 and p.stdout.startswith('held'), p.stdout)
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'release', GID])
    p = subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'status', GID], capture_output=True, text=True)
    check('status: released -> clear, exit 1', p.returncode == 1 and p.stdout.strip() == 'clear', p.stdout)

    # gate
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'set', GID])
    for cmd, name in [('~/.config/agent-watcher/update-status.sh 7777777777 Complete', 'status transition'),
                      ('cd /r && git push --force-with-lease origin br', 'raw git push'),
                      ('~/.cursor/skills/git-branch-ops.sh push --force-with-lease', 'git-branch-ops push'),
                      ('~/.cursor/skills/pr-finalize-fixups.sh --owner o --repo r --pr 1', 'pr-finalize-fixups'),
                      ('gh pr ready 12', 'gh pr ready')]:
        check(f'gate blocks while held: {name}', gate(cmd) == 2)
    for cmd, name in [('git status', 'git status'), ('~/.cursor/skills/lint-commit.sh -m x f.ts', 'local commit'),
                      ('~/.config/agent-watcher/update-status.sh 7777777777 Testing --blocked yes --reason x', 'operator-directed block')]:
        check(f'gate allows while held: {name}', gate(cmd) == 0)
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'release', GID])
    check('gate allows a push once released', gate('git push origin br') == 0)

    # Stop hook and concession gate under a hold (real HOME: both read the real oracle).
    real = dict(os.environ, AGENT_TASK_GID=GID)
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'set', GID])
    count = f'/tmp/agent-stop-block-count-{GID}'
    if os.path.exists(count):
        os.remove(count)
    p = subprocess.run([os.path.join(AW, 'hooks/require-continuation-or-block.sh')], input='{}', capture_output=True, text=True, env=real, timeout=60)
    check('stop hook stands down while held (exit 0, counter untouched)', p.returncode == 0 and p.stdout.strip() == '' and not os.path.exists(count), f'rc={p.returncode} {p.stdout[:80]}')
    verdict = f'/tmp/agent-concession-verdict-{GID}.json'
    if os.path.exists(verdict):
        os.remove(verdict)
    blk = {'tool_input': {'command': f'~/.config/agent-watcher/update-status.sh {GID} Complete --blocked yes --reason "operator-directed: discuss"'}}
    p = subprocess.run([os.path.join(AW, 'hooks/require-concession-validation.sh')], input=json.dumps(blk), capture_output=True, text=True, env=real, timeout=60)
    check('concession gate accepts an operator-directed block while held', p.returncode == 0, f'rc={p.returncode} {p.stderr[:120]}')
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'release', GID])
    p = subprocess.run([os.path.join(AW, 'hooks/require-concession-validation.sh')], input=json.dumps(blk), capture_output=True, text=True, env=real, timeout=60)
    check('concession gate still judges a block once clear', p.returncode == 2, f'rc={p.returncode}')
finally:
    if os.path.exists(STAMP):
        os.remove(STAMP)
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
