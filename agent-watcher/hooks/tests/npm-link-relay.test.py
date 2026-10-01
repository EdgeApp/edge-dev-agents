#!/usr/bin/env python3
"""Contract test for pr-land npm-auth-wait.sh and require-npm-link-relay.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/npm-link-relay.test.py

Wait half: the wait returns within one poll of a new relay line (not at its
cap), prints only lines it has not returned before, names the newest untapped
link of every log still waiting, and exits 3 once every log finished.

Hook half: the next wait is blocked until the last AUTH_URL the wait returned
is in assistant chat text outside a code span, and in orch runs also in a
PushNotification (or an escape note exists). Unreturned, tapped, and quoted
cases never block.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

WAIT = os.path.expanduser('~/.cursor/skills/pr-land/scripts/npm-auth-wait.sh')
HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/require-npm-link-relay.sh')
GID = 'npmrelaytest'
ESCAPE = '/tmp/agent-npm-relay-%s.md' % GID
U1 = 'https://www.npmjs.com/login?next=/login/cli/aaaa-1111'
U2 = 'https://www.npmjs.com/login?next=/login/cli/bbbb-2222'
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def append(path, *lines):
    with open(path, 'a') as f:
        f.write(''.join(l + '\n' for l in lines))


def wait(*args):
    t = time.time()
    r = subprocess.run(['bash', WAIT, *args], capture_output=True, text=True)
    return r.returncode, r.stdout, time.time() - t


d = tempfile.mkdtemp()
login = os.path.join(d, 'npm-login.log')
open(login, 'w').close()

# --- wait half ---------------------------------------------------------------
threading.Timer(2, append, [login, 'login attempt 1/20...', 'AUTH_URL login ' + U1,
                            'link minted 08:00:01Z (attempt 1)']).start()
rc, out, took = wait('--cap', '30', login)
check(rc == 0, 'first link: exit %d, want 0\n%s' % (rc, out))
check(took < 8, 'first link: returned after %.1fs, want within one poll of the write' % took)
check('NEW %s AUTH_URL login %s' % (login, U1) in out, 'first link: no NEW line\n' + out)
check('RELAY %s %s minted 08:00:01Z' % (login, U1) in out, 'first link: no RELAY line\n' + out)

rc, out, took = wait('--cap', '4', login)
check(rc == 4 and 'WAITING' in out and 'NEW' not in out,
      'idle: exit %d, want 4 with no NEW\n%s' % (rc, out))

threading.Timer(1, append, [login, 'AUTH_URL login ' + U2, 'link minted 08:04:01Z (attempt 2)']).start()
rc, out, _ = wait('--cap', '30', login)
check(rc == 0 and 'RELAY %s %s' % (login, U2) in out and U1 not in out,
      'remint: want only the new link\n' + out)

append(login, 'AUTH_DONE login someone', 'LOGGED_IN someone')
rc, out, _ = wait('--cap', '30', login)
check(rc == 3 and 'DONE %s LOGGED_IN someone' % login in out and '\nRELAY ' not in '\n' + out,
      'login done: exit %d, want 3 with DONE and no RELAY\n%s' % (rc, out))

pa, pb = os.path.join(d, 'npm-publish-a.log'), os.path.join(d, 'npm-publish-b.log')
append(pa, 'AUTH_URL publish ' + U1, 'AUTH_DONE publish a@1.0.0', 'PUBLISHED a@1.0.0')
append(pb, 'AUTH_URL publish ' + U2)
rc, out, _ = wait('--cap', '5', pa, pb)
check(rc == 0 and 'DONE %s PUBLISHED a@1.0.0' % pa in out and 'RELAY %s %s' % (pb, U2) in out
      and 'RELAY %s' % pa not in out, 'two logs: one done, one waiting\n' + out)
append(pb, 'AUTH_DONE publish b@1.0.0')
rc, out, _ = wait('--cap', '5', pa, pb)
check(rc == 0 and '\nRELAY ' not in '\n' + out, 'tapped link: no RELAY while the registry settles\n' + out)

pc, pd = os.path.join(d, 'npm-publish-c.log'), os.path.join(d, 'npm-publish-d.log')
append(pc, 'AUTH_URL publish ' + U1)
append(pd, 'AUTH_URL publish ' + U2)
rc, out, _ = wait('--cap', '5', pc, pd)
check(rc == 0 and ('RELAY %s %s minted unknown\nRELAY %s %s' % (pc, U1, pd, U2)) in out,
      'two waiting logs: one RELAY line each\n' + out)

# A log restarted with > is read from its first line again, even when the
# new run already holds as many lines as the old one returned.
open(login, 'w').write('AUTH_URL login ' + U2 + '\n')
rc, out, _ = wait('--cap', '5', login)
check(rc == 0 and 'NEW %s AUTH_URL login %s' % (login, U2) in out, 'restarted log: re-read from the top\n' + out)

# --- hook half ---------------------------------------------------------------
def transcript(*entries):
    tf = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False, dir=d)
    for kind, val in entries:
        block = ({'type': 'text', 'text': val} if kind == 'text' else
                 {'type': 'tool_use', 'name': 'PushNotification', 'input': {'message': val}})
        tf.write(json.dumps({'type': 'assistant', 'message': {'content': [block]}}) + '\n')
    tf.write(json.dumps({'type': 'user', 'message': {'content': [
        {'type': 'tool_result', 'content': 'AUTH_URL login ' + U1}]}}) + '\n')
    tf.close()
    return tf.name


def hook(log, tp, orch=False, cmd=None):
    cmd = cmd or '~/.cursor/skills/pr-land/scripts/npm-auth-wait.sh %s' % log
    env = {k: v for k, v in os.environ.items() if k != 'AGENT_TASK_GID'}
    if orch:
        env['AGENT_TASK_GID'] = GID
    p = subprocess.run(['bash', HOOK], input=json.dumps(
        {'tool_input': {'command': cmd}, 'transcript_path': tp}),
        capture_output=True, text=True, env=env)
    return p.returncode, p.stderr


def fresh_log(lines, returned):
    p = tempfile.NamedTemporaryFile('w', suffix='.log', delete=False, dir=d)
    p.write(''.join(l + '\n' for l in lines))
    p.close()
    if returned is not None:
        marks = ''.join(l + '\n' for l in lines[:returned])
        ck = subprocess.run(['cksum'], input=marks, capture_output=True, text=True).stdout.split()[0]
        open(p.name + '.relayed', 'w').write('%d %s' % (returned, ck))
    return p.name


if os.path.exists(ESCAPE):
    os.remove(ESCAPE)
one = fresh_log(['AUTH_URL login ' + U1], 1)
empty_tp = transcript()
CASES = [
    ('never returned', fresh_log(['AUTH_URL login ' + U1], None), empty_tp, False, 0),
    ('push only, plain session', one, transcript(('push', 'link ' + U1)), False, 2),
    ('chat text, plain session', one, transcript(('text', 'Tap ' + U1)), False, 0),
    ('code span only', one, transcript(('text', 'Tap `' + U1 + '`')), False, 2),
    ('markdown link', one, transcript(('text', '[npm login](' + U1 + ')')), False, 0),
    ('orch, chat text only', one, transcript(('text', 'Tap ' + U1)), True, 2),
    ('orch, push only', one, transcript(('push', 'link ' + U1)), True, 2),
    ('orch, both', one, transcript(('text', 'Tap ' + U1), ('push', 'link ' + U1)), True, 0),
    ('tapped', fresh_log(['AUTH_URL login ' + U1, 'AUTH_DONE login x'], 2), empty_tp, True, 0),
    ('newer link not returned yet', fresh_log(['AUTH_URL login ' + U1, 'AUTH_URL login ' + U2], 1),
     transcript(('text', 'Tap ' + U1)), False, 0),
    ('older link relayed, newer returned', fresh_log(['AUTH_URL login ' + U1, 'AUTH_URL login ' + U2], 2),
     transcript(('text', 'Tap ' + U1)), False, 2),
]
for name, log, tp, orch, want in CASES:
    rc, err = hook(log, tp, orch)
    check(rc == want, 'hook %s: exit %d, want %d\n%s' % (name, rc, want, err))

restarted = fresh_log(['AUTH_URL login ' + U1], 1)
open(restarted, 'w').write('AUTH_URL login ' + U2 + '\n')
rc, err = hook(restarted, empty_tp)
check(rc == 0, 'hook restarted log: exit %d, want 0 (nothing returned from the new run)\n%s' % (rc, err))

rc, err = hook(one, empty_tp, cmd='echo "next: npm-auth-wait.sh %s"' % one)
check(rc == 0, 'hook quoted mention: exit %d, want 0\n%s' % (rc, err))

open(ESCAPE, 'w').write('no push channel in this harness')
rc, err = hook(one, transcript(('text', 'Tap ' + U1)), orch=True)
check(rc == 0, 'hook escape note waives push: exit %d\n%s' % (rc, err))
rc, err = hook(one, empty_tp, orch=True)
check(rc == 2, 'hook escape note never waives chat text: exit %d' % rc)
os.remove(ESCAPE)

if fails:
    print('FAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('PASS (8 wait cases, %d hook cases)' % (len(CASES) + 4))
