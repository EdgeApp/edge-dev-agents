#!/usr/bin/env python3
"""Contract test for agent-watcher/derived-data-reap.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/derived-data-reap.test.py

--orphans deletes a folder whose workspace is gone and nothing else.
--stale-hours deletes a folder whose workspace still exists only when it sits
under an agent root, no in-use slot holds its worktree, and nothing built into
it for that long. The primary checkout, a hand-opened project, a live run and a
folder with no recorded workspace all survive. --under is unchanged.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

REAP = os.path.expanduser('~/.config/agent-watcher/derived-data-reap.sh')
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def world():
    """A DerivedData root plus the workspaces its folders were built from."""
    d = tempfile.mkdtemp()
    dd = os.path.join(d, 'DerivedData')
    roots = {k: os.path.join(d, k) for k in ('worktrees', 'shadows', 'primary', 'elsewhere')}
    os.makedirs(dd)
    made = {}

    def folder(name, ws, age_h, exists=True, plist=True):
        path = os.path.join(dd, name)
        os.makedirs(os.path.join(path, 'Build'))
        open(os.path.join(path, 'Build', 'obj.o'), 'w').write('x' * 100)
        if exists:
            os.makedirs(ws, exist_ok=True)
        if plist:
            subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Add :WorkspacePath string ' + ws,
                            os.path.join(path, 'info.plist')], capture_output=True)
        t = time.time() - age_h * 3600
        for target in ([os.path.join(path, 'info.plist')] if plist else []) + [path]:
            os.utime(target, (t, t))
        made[name] = path

    folder('edge-idle', roots['worktrees'] + '/111/gui/ios/edge.xcworkspace', 30)
    folder('edge-recent', roots['worktrees'] + '/222/gui/ios/edge.xcworkspace', 2)
    folder('edge-live', roots['worktrees'] + '/333/gui/ios/edge.xcworkspace', 30)
    folder('edge-shadow', roots['shadows'] + '/444-retro/gui/ios/edge.xcworkspace', 300)
    folder('edge-primary', roots['primary'] + '/gui/ios/edge.xcworkspace', 300)
    folder('edge-elsewhere', roots['elsewhere'] + '/proj/App.xcworkspace', 300)
    folder('edge-orphan', roots['worktrees'] + '/555/gui/ios/edge.xcworkspace', 1, exists=False)
    folder('Runner-noplist', '', 300, exists=False, plist=False)
    os.makedirs(os.path.join(dd, 'ModuleCache.noindex'))
    slots = os.path.join(d, 'slots.json')
    json.dump({'slots': [{'task_gid': '333', 'worktree_path': roots['worktrees'] + '/333'}]}, open(slots, 'w'))
    return dd, roots, slots, made


def run(dd, roots, slots, *args):
    r = subprocess.run(['bash', REAP, '--root', dd, '--slots', slots,
                        '--agent-root', roots['worktrees'], '--agent-root', roots['shadows'], *args],
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def left(made):
    return sorted(n for n, p in made.items() if os.path.isdir(p))


ALL = ['Runner-noplist', 'edge-elsewhere', 'edge-idle', 'edge-live', 'edge-orphan',
       'edge-primary', 'edge-recent', 'edge-shadow']

dd, roots, slots, made = world()
rc, out = run(dd, roots, slots, '--stale-hours', '24', '--dry-run')
check(rc == 0 and left(made) == ALL, 'dry run deletes nothing\n' + out)
check('REAP edge-idle' in out and 'REAP edge-shadow' in out and out.count('REAP ') == 2,
      'dry run names exactly the two stale agent folders\n' + out)

rc, out = run(dd, roots, slots, '--stale-hours', '24')
check(rc == 0 and left(made) == [n for n in ALL if n not in ('edge-idle', 'edge-shadow')],
      'stale: only the idle worktree and the shadow go\n%s\n%s' % (left(made), out))
check(os.path.isdir(os.path.join(dd, 'ModuleCache.noindex')), 'stale: shared caches survive')
check('stale24h' in out, 'stale: summary names the mode\n' + out)

dd, roots, slots, made = world()
rc, out = run(dd, roots, slots, '--orphans')
check(rc == 0 and left(made) == [n for n in ALL if n != 'edge-orphan'], 'orphans: only the orphan goes\n' + out)

dd, roots, slots, made = world()
rc, out = run(dd, roots, slots, '--orphans', '--stale-hours', '24')
check(rc == 0 and left(made) == ['Runner-noplist', 'edge-elsewhere', 'edge-live', 'edge-primary', 'edge-recent'],
      'both modes in one pass\n%s\n%s' % (left(made), out))

dd, roots, slots, made = world()
os.remove(slots)
rc, out = run(dd, roots, slots, '--stale-hours', '24')
check(rc == 0 and 'edge-recent' in left(made) and 'edge-idle' not in left(made),
      'no slots file: age and root still decide\n' + out)

dd, roots, slots, made = world()
rc, out = run(dd, roots, slots, '--under', roots['worktrees'] + '/222')
check(rc == 0 and left(made) == [n for n in ALL if n != 'edge-recent'], 'under: unchanged behaviour\n' + out)

for bad in (['--under', roots['worktrees'], '--orphans'], ['--stale-hours', 'soon'], []):
    rc, out = run(dd, roots, slots, *bad)
    check(rc == 2, 'usage error for %s: exit %d, want 2' % (bad, rc))

if fails:
    print('FAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('PASS (10 cases)')
