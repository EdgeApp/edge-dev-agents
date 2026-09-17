#!/usr/bin/env python3
"""Contract tests for wait-for-quiet-load.sh's own-share load correction.

Run: python3 ~/.config/agent-watcher/hooks/tests/quiet-load-own-share.test.py
     WQL_STAGE=<dir> python3 ...   (test a staged copy instead of the installed script)

Covers:
  - raw load above threshold but this session's own process tree accounts for
    the excess -> proceed immediately, no wait
  - a process reparented out of the pane tree but named by the run's worktree
    still counts as ours
  - load owned by OTHER sessions is not subtracted -> the gate waits, then
    proceeds when the machine actually quiets
  - the 1200s-style ceiling still fires (WAIT_TIMEOUT) and runs verification
  - the correction is clamped to [0, raw]: never negative, never above raw,
    and with no own-tree data the gate behaves exactly like the uncorrected one
  - the tmux-less ancestor walk finds the session root and stops below the
    shared tmux server
  - exit code is 0 in every branch
sysctl, ps, tmux, uname and sleep are all stubbed: no real load, process
inspection, or waiting.
"""
import os, stat, subprocess, sys, tempfile

HOME_REAL = os.path.expanduser('~')
INSTALLED = f'{HOME_REAL}/.cursor/skills/pr-land/scripts/wait-for-quiet-load.sh'
STAGE = os.environ.get('WQL_STAGE')
SCRIPT = os.path.join(STAGE, 'wait-for-quiet-load.sh') if STAGE else INSTALLED

GID = '1216839790397157'
WORKTREE = f'{HOME_REAL}/git/.agent-worktrees/{GID}'

fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def write_exec(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write('#!/usr/bin/env bash\n' + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


tmp = tempfile.mkdtemp(prefix='wql-')
stub = os.path.join(tmp, 'bin')
os.makedirs(stub, exist_ok=True)

write_exec(f'{stub}/uname', 'echo Darwin\n')

write_exec(f'{stub}/sysctl', r'''
case "$*" in
  *hw.ncpu*) echo 16 ;;
  *vm.loadavg*) L=$(cat "$WQL_LOADFILE"); echo "{ $L $L $L }" ;;
  *) exit 1 ;;
esac
exit 0
''')

# sleep never sleeps: it counts calls and can flip the machine load partway.
write_exec(f'{stub}/sleep', r'''
n=$(cat "$WQL_SLEEPS" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$WQL_SLEEPS"
if [ -n "${WQL_LOAD_AFTER:-}" ] && [ "$n" -ge "${WQL_FLIP_AT:-1}" ]; then
  printf '%s' "$WQL_LOAD_AFTER" > "$WQL_LOADFILE"
fi
exit 0
''')

write_exec(f'{stub}/tmux', r'''
[ -n "${WQL_PANE_PIDS:-}" ] || exit 1
case "$*" in *"claude-asana-$AGENT_TASK_GID"*) printf '%s\n' $WQL_PANE_PIDS; exit 0 ;; esac
exit 1
''')

# ps over a fixture of "pid ppid pcpu command..." lines. Unknown pids (the test
# runner's own shell) report WQL_UNKNOWN_PPID so the ancestor walk is testable.
write_exec(f'{stub}/ps', r'''
FIX="${WQL_PS_FIXTURE:-/dev/null}"
mode="" target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -Ao*|-ao*) mode=all ;;
    -o) case "$2" in ppid*) mode=ppid ;; comm*) mode=comm ;; esac; shift ;;
    -p) target="$2"; shift ;;
  esac
  shift
done
case "$mode" in
  all) grep -v '^[[:space:]]*$' "$FIX" ;;
  ppid) out=$(awk -v t="$target" '$1 == t {print $2; found=1} END {exit !found}' "$FIX") \
          && printf '%s\n' "$out" || printf '%s\n' "${WQL_UNKNOWN_PPID:-}" ;;
  comm) awk -v t="$target" '$1 == t {print $4}' "$FIX" ;;
esac
exit 0
''')


def run(fixture_lines, load, *, gid=GID, pane='500', extra_env=None, args=(),
        load_after=None, flip_at=1):
    """Run the gate under stubs. Returns (rc, stderr, sleep_count)."""
    d = tempfile.mkdtemp(dir=tmp)
    fix = os.path.join(d, 'ps.fixture')
    with open(fix, 'w') as f:
        f.write('\n'.join(fixture_lines) + '\n')
    loadfile = os.path.join(d, 'load')
    with open(loadfile, 'w') as f:
        f.write(str(load))
    sleeps = os.path.join(d, 'sleeps')
    env = dict(os.environ)
    env.pop('AGENT_TASK_GID', None)
    env.update({
        'PATH': stub + os.pathsep + env['PATH'],
        'HOME': HOME_REAL,
        'WQL_PS_FIXTURE': fix,
        'WQL_LOADFILE': loadfile,
        'WQL_SLEEPS': sleeps,
    })
    if gid:
        env['AGENT_TASK_GID'] = gid
    if pane:
        env['WQL_PANE_PIDS'] = pane
    if load_after is not None:
        env['WQL_LOAD_AFTER'] = str(load_after)
        env['WQL_FLIP_AT'] = str(flip_at)
    if extra_env:
        env.update(extra_env)
    p = subprocess.run(['bash', SCRIPT, *args], env=env, capture_output=True, text=True, timeout=60)
    n = 0
    if os.path.exists(sleeps):
        n = int(open(sleeps).read() or 0)
    return p.returncode, p.stderr, n


# Shared machine picture: pane shell 500 under the tmux server 400, our own
# prepare/npm/webpack under it, and a second session's tree under 600.
def machine(own_cpu, other_cpu=3000.0, extra=()):
    return [
        f'400 1 0.0 tmux',
        f'500 400 0.1 zsh',
        f'501 500 {own_cpu * 0.1:.1f} node /Users/x/.cursor/skills/pr-land/scripts/pr-land-prepare.sh',
        f'502 501 {own_cpu * 0.5:.1f} npm install',
        f'503 501 {own_cpu * 0.4:.1f} node webpack',
        f'600 400 0.1 zsh',
        f'601 600 {other_cpu:.1f} xcodebuild',
        *extra,
    ]


# 1. Raw load 40 > 32, but our own tree is 10 cores of it -> 30, proceed at once.
rc, err, naps = run(machine(1000.0), 40)
check('own-tree correction proceeds immediately', rc == 0 and naps == 0 and 'waiting' not in err,
      f'rc={rc} naps={naps} err={err!r}')

# 2. A worktree-named process reparented to pid 1 still counts as ours.
reparented = [f'700 1 700.0 node {WORKTREE}/edge-react-gui/node_modules/.bin/webpack']
rc, err, naps = run(machine(200.0, extra=reparented), 40)
check('reparented worktree process counted as own', rc == 0 and naps == 0,
      f'rc={rc} naps={naps} err={err!r}')
rc2, err2, naps2 = run(machine(200.0), 40, args=('--max-wait', '0'))
check('...and without it the same load would wait', rc2 == 0 and 'WAIT_TIMEOUT' in err2 and 'still 38' in err2,
      f'rc={rc2} err={err2!r}')

# 3. Load owned by other sessions is not subtracted: wait, then proceed on quiet.
rc, err, naps = run(machine(200.0), 40, load_after=34, flip_at=2)
check('other sessions load makes the gate wait',
      rc == 0 and naps == 2 and 'waiting up to' in err and 'proceeding' in err,
      f'rc={rc} naps={naps} err={err!r}')
check('other sessions load is not subtracted', '(own 2)' in err, err)

# 4. The ceiling still fires and hands control back to verification.
rc, err, naps = run(machine(100.0), 117, args=('--max-wait', '120'))
check('ceiling fires with WAIT_TIMEOUT', rc == 0 and naps == 4 and 'WAIT_TIMEOUT' in err,
      f'rc={rc} naps={naps} err={err!r}')
check('ceiling reports the corrected load', 'still 116' in err and 'raw 117' in err, err)

# 5. Correction is clamped: an own share larger than the raw load floors at 0.
rc, err, naps = run(machine(8000.0), 40, args=('--threshold', '-1', '--max-wait', '0'))
check('correction never goes negative', rc == 0 and 'still 0 (raw 40, own 80)' in err,
      f'rc={rc} err={err!r}')
check('corrected load never exceeds raw', '-' not in err.split('still ')[1].split()[0], err)

# 6. No own-tree data at all -> own 0, gate behaves like the uncorrected one.
rc, err, naps = run(['400 1 0.0 tmux', '601 400 3000.0 xcodebuild'], 40, pane='',
                    gid='', args=('--max-wait', '0'), extra_env={'WQL_UNKNOWN_PPID': ''})
check('no own-tree data degrades to the raw gate', rc == 0 and 'still 40 (raw 40, own 0)' in err,
      f'rc={rc} err={err!r}')

# 7. No tmux: the ancestor walk climbs to the pane shell and stops below tmux.
rc, err, naps = run(machine(1000.0), 40, gid='', pane='',
                    extra_env={'WQL_UNKNOWN_PPID': '501'})
check('ancestor walk finds the session root without tmux', rc == 0 and naps == 0 and 'waiting' not in err,
      f'rc={rc} naps={naps} err={err!r}')
rc, err, naps = run(machine(1000.0, other_cpu=30000.0), 40, gid='', pane='',
                    extra_env={'WQL_UNKNOWN_PPID': '501'}, args=('--threshold', '1', '--max-wait', '0'))
check('ancestor walk stops below the shared tmux server',
      rc == 0 and 'still 30 (raw 40, own 10)' in err, err)

print()
print(f'{len(fails)} failure(s)' if fails else 'all checks passed')
sys.exit(1 if fails else 0)
