#!/usr/bin/env python3
"""Contract tests for the long-wait chunking and the land-lease upkeep.

Run: python3 ~/.config/agent-watcher/hooks/tests/long-wait-and-lease.test.py
     LWL_STAGE=<dir> python3 ...   (test flat staged copies instead of installed scripts)

Covers:
  - ios-rn-build.sh --detach writes /tmp/ios-rn-build-<udid>.{log,status}
  - ios-rn-build-wait.sh: exit 7 while running, then the build's exit; stall -> 3
    (build killed); missing status -> 4; release-pool-entry.sh kills a detached build
  - watch-pr.sh: exit 7 at MAX_CALL with the budget preserved per task+repo+PR,
    and the land lease renewed each poll; pr-merge-watch.sh renews too
  - repo-land-lock.sh renew: same owner ok, other owner / expired fail, none -> 3
  - pr-land-prepare.sh releases its lease on failure; verify-repo.sh renews
Everything external is stubbed (xcrun, npx, curl, lsof, gh, git, timeout, pm.sh):
no real build, sim, PR, or network call.
"""
import json, os, shutil, stat, subprocess, sys, tempfile, time

HOME_REAL = os.path.expanduser('~')
INSTALLED = {
    'ios-rn-build.sh': f'{HOME_REAL}/.cursor/skills/build-and-test/scripts/ios-rn-build.sh',
    'ios-rn-build-wait.sh': f'{HOME_REAL}/.cursor/skills/build-and-test/scripts/ios-rn-build-wait.sh',
    'watch-pr.sh': f'{HOME_REAL}/.cursor/skills/one-shot/scripts/watch-pr.sh',
    'pr-merge-watch.sh': f'{HOME_REAL}/.cursor/skills/pr-land/scripts/pr-merge-watch.sh',
    'repo-land-lock.sh': f'{HOME_REAL}/.cursor/skills/pr-land/scripts/repo-land-lock.sh',
    'pr-land-prepare.sh': f'{HOME_REAL}/.cursor/skills/pr-land/scripts/pr-land-prepare.sh',
    'verify-repo.sh': f'{HOME_REAL}/.cursor/skills/verify-repo.sh',
    'release-pool-entry.sh': f'{HOME_REAL}/.config/agent-watcher/release-pool-entry.sh',
}
STAGE = os.environ.get('LWL_STAGE')


def script(name):
    return os.path.join(STAGE, name) if STAGE else INSTALLED[name]


fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def write_exec(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write('#!/usr/bin/env bash\n' + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def link(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.lexists(dst):
        os.remove(dst)
    os.symlink(src, dst)


tmp = tempfile.mkdtemp(prefix='lwl-')
home = os.path.join(tmp, 'home')
state = os.path.join(tmp, 'state')
stub = os.path.join(tmp, 'bin')
marks = os.path.join(tmp, 'marks')
for d in (home, state, stub, marks, os.path.join(home, '.config/agent-watcher')):
    os.makedirs(d, exist_ok=True)
link(script('ios-rn-build-wait.sh'), f'{home}/.cursor/skills/build-and-test/scripts/ios-rn-build-wait.sh')
link(script('repo-land-lock.sh'), f'{home}/.cursor/skills/pr-land/scripts/repo-land-lock.sh')
write_exec(f'{home}/.cursor/skills/pm.sh', 'case "$1" in detect) echo npm ;; esac\nexit 0\n')

# ---- stubs ----
write_exec(f'{stub}/xcrun', r'''
[ "$1" = simctl ] || exit 0
case "$2" in
  bootstatus) [ -z "${STUB_BOOT_FAIL:-}" ]; exit $? ;;
  spawn|launch|terminate|install) exit 0 ;;
  get_app_container)
    [ -f "$LWL_MARKS/installed-$3" ] || exit 1
    mkdir -p "$LWL_MARKS/data-$3"; echo "$LWL_MARKS/data-$3"; exit 0 ;;
esac
exit 0
''')
write_exec(f'{stub}/npx', r'''
case "$*" in
  *"react-native start"*) exit 0 ;;
  *"react-native run-ios"*)
    echo "stub run-ios: building"
    sleep "${STUB_BUILD_SECS:-0}"
    if [ "${STUB_BUILD_EXIT:-0}" = 0 ]; then
      udid=$(printf '%s\n' "$@" | awk 'f{print;exit} $0=="--udid"{f=1}')
      touch "$LWL_MARKS/installed-$udid"; echo "stub run-ios: BUILD SUCCEEDED"
    fi
    exit "${STUB_BUILD_EXIT:-0}" ;;
esac
exit 0
''')
write_exec(f'{stub}/curl', 'echo "packager-status:running"\n')
write_exec(f'{stub}/lsof', 'exit 1\n')
write_exec(f'{stub}/timeout', 'shift; exec "$@"\n')
write_exec(f'{stub}/git', 'exit 1\n')
write_exec(f'{stub}/gh', r'''
case "$*" in
  *"pr checks"*) echo '[{"name":"build","bucket":"pending"}]' ;;
  *headRefOid*) echo "${STUB_HEAD:-abc123}" ;;
  *isDraft,commits*) echo '{"d":false,"m":"feat: x"}' ;;
  *"--json state,mergeStateStatus"*) echo '{"state":"OPEN","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"status":"IN_PROGRESS"}],"reviewDecision":""}' ;;
  *) exit 1 ;;
esac
''')

ENV = dict(os.environ, HOME=home, XDG_STATE_HOME=state, LWL_MARKS=marks,
           PATH=f'{stub}:{os.environ["PATH"]}', AGENT_SESSION_UUID='owner-A')
for k in ('AGENT_SIM_UDID', 'AGENT_METRO_PORT', 'MAX_CALL'):
    ENV.pop(k, None)
repo = os.path.join(tmp, 'repo')
# native_deps_hash needs at least one edge-* webview asset dir, as a real gui tree has.
os.makedirs(os.path.join(repo, 'node_modules/edge-fake/android/src/main/assets'))
open(os.path.join(repo, 'node_modules/edge-fake/android/src/main/assets/plugin.js'), 'w').write('x')
RUN_ID = str(os.getpid())
UDIDS = []


def udid(tag):
    u = f'LWL-TEST-{RUN_ID}-{tag}'
    UDIDS.append(u)
    return u


def run(cmd, env=None, cwd=None, timeout=120, stdin=None):
    return subprocess.run(cmd, env=env or ENV, cwd=cwd, capture_output=True, text=True, timeout=timeout, input=stdin)


def status(u):
    try:
        return dict(l.split('=', 1) for l in open(f'/tmp/ios-rn-build-{u}.status').read().splitlines() if '=' in l)
    except FileNotFoundError:
        return {}


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def detach(u, **extra):
    env = dict(ENV, **extra)
    t0 = time.time()
    p = run(['bash', script('ios-rn-build.sh'), '--udid', u, '--bundle-id', 'co.test', '--port', '18999',
             '--skip-install', '--detach'], env=env, cwd=repo)
    return p, time.time() - t0


def wait(u, **extra):
    return run(['bash', script('ios-rn-build-wait.sh'), '--udid', u], env=dict(ENV, POLL_SECS='1', **extra))


try:
    # ---------------- detach + wait ----------------
    u = udid('ok')
    p, took = detach(u, STUB_BUILD_SECS='5')
    check('detach: returns 0 immediately', p.returncode == 0 and took < 4, f'rc={p.returncode} took={took:.1f} {p.stderr[-300:]}')
    time.sleep(1)
    st = status(u)
    check('detach: status file has pid, phase, started', st.get('pid') and st.get('phase') and st.get('started'), st)
    check('detach: log file exists', os.path.exists(f'/tmp/ios-rn-build-{u}.log'))
    w = wait(u, MAX_CALL='2')
    check('wait: exit 7 CONTINUE while the build runs', w.returncode == 7 and 'RESULT: continue' in w.stdout, f'rc={w.returncode} {w.stdout[-200:]} {w.stderr[-200:]}')
    w = wait(u, MAX_CALL='60')
    check('wait: then the build exit code (0)', w.returncode == 0, f'rc={w.returncode} {w.stdout[-400:]}')
    st = status(u)
    check('status: exit=0 phase=done recorded', st.get('exit') == '0' and st.get('phase') == 'done', st)
    check('detach: stable run-ios log keyed by udid', os.path.exists(f'/tmp/ios-rn-build-runios-{u}.log'))

    u = udid('fail')
    detach(u, STUB_BUILD_EXIT='1')
    w = wait(u, MAX_CALL='60')
    check('wait: failing build surfaces exit 1', w.returncode == 1, f'rc={w.returncode} {w.stdout[-300:]}')

    u = udid('noboot')
    detach(u, STUB_BOOT_FAIL='1')
    w = wait(u, MAX_CALL='30')
    check('wait: child exiting before the build (sim not booted) surfaces exit 2', w.returncode == 2, f'rc={w.returncode} {w.stdout[-300:]}')

    # marker gate deferred to the child (reinstall running), child blocks there and
    # exits 1 before any build: the exit must still reach the status file.
    gate_repo = os.path.join(tmp, 'gate-repo')
    shutil.copytree(repo, gate_repo, symlinks=True)
    open(os.path.join(gate_repo, '.stale-node-modules'), 'w').write('stale\n')
    write_exec(f'{home}/.config/agent-watcher/lib/node-modules-freshness.sh',
               'nm_installer_alive() { return 0; }\nnm_build_gate() { sleep 2; return 1; }\n')
    u = udid('gate')
    env = dict(ENV)
    p = run(['bash', script('ios-rn-build.sh'), '--udid', u, '--bundle-id', 'co.test', '--port', '18999',
             '--skip-install', '--detach'], env=env, cwd=gate_repo)
    check('detach: marker gate with a live reinstall defers to the child', p.returncode == 0, f'rc={p.returncode} {p.stderr[-300:]}')
    w = wait(u, MAX_CALL='30')
    check('wait: child blocked at the marker gate surfaces exit 1 (not 4)', w.returncode == 1 and status(u).get('exit') == '1', f'rc={w.returncode} {status(u)}')
    os.remove(f'{home}/.config/agent-watcher/lib/node-modules-freshness.sh')

    u = udid('stall')
    detach(u, STUB_BUILD_SECS='120')
    time.sleep(1)
    pid = status(u).get('pid')
    w = wait(u, MAX_CALL='60', STALL_SECS='4')
    check('wait: silent log -> exit 3 STALLED', w.returncode == 3 and 'STALLED' in w.stderr, f'rc={w.returncode} {w.stderr[-300:]}')
    time.sleep(1)
    check('wait: stalled build was killed', pid and not alive(pid), pid)
    w = wait(u, MAX_CALL='5')
    check('wait: after the stall kill, a re-wait reports a finished (failed) build', w.returncode == 1, f'rc={w.returncode}')

    w = wait(f'LWL-TEST-{RUN_ID}-nonexistent', MAX_CALL='5')
    check('wait: missing status file -> exit 4', w.returncode == 4, f'rc={w.returncode}')

    u = udid('running-twice')
    detach(u, STUB_BUILD_SECS='120')
    time.sleep(1)
    p, _ = detach(u, STUB_BUILD_SECS='1')
    check('detach: refuses a second build on a sim with one running', p.returncode == 1 and 'already running' in p.stderr, f'rc={p.returncode} {p.stderr[-200:]}')

    # release-pool-entry.sh kills a detached build on the released sim
    pid = status(u).get('pid')
    os.makedirs(os.path.join(state, 'agent-watcher'), exist_ok=True)
    with open(os.path.join(state, 'agent-watcher', 'pool.json'), 'w') as f:
        json.dump({'pool': [{'slot': 0, 'udid': u, 'state': 'claimed', 'task_gid': '424242'}]}, f)
    r = run(['bash', script('release-pool-entry.sh'), '--task-gid', '424242'])
    time.sleep(1)
    pool = json.load(open(os.path.join(state, 'agent-watcher', 'pool.json')))
    check('release-pool-entry: slot marked dirty', r.returncode == 0 and pool['pool'][0]['state'] == 'dirty', f'rc={r.returncode} {r.stderr[-300:]}')
    check('release-pool-entry: detached build on that sim killed', pid and not alive(pid), f'pid={pid} {r.stderr[-300:]}')

    # ---------------- land lease ----------------
    LOCK = script('repo-land-lock.sh')
    lockfile = os.path.join(state, 'agent-watcher', 'land-locks', 'lwl-repo.json')

    def lock(*a, owner='owner-A'):
        return run(['bash', LOCK, *a, '--repo', 'lwl-repo', '--owner', owner])

    check('lease: renew with no lease -> 3', lock('renew').returncode == 3)
    check('lease: acquire', lock('acquire', '--ttl', '100').returncode == 0)
    before = json.load(open(lockfile))['expires']
    check('lease: renew same owner -> 0 and TTL extended', lock('renew').returncode == 0 and json.load(open(lockfile))['expires'] > before + 1000)
    r = lock('renew', owner='owner-B')
    check('lease: renew other owner -> 1', r.returncode == 1, r.stderr)
    lf = json.load(open(lockfile)); lf['expires'] = int(time.time()) - 10; json.dump(lf, open(lockfile, 'w'))
    check('lease: renew own EXPIRED lease -> 1 (must re-acquire)', lock('renew').returncode == 1)
    check('lease: acquire after expiry still works', lock('acquire').returncode == 0)

    # watch-pr.sh: exit 7 at MAX_CALL, per task+repo+PR budget, lease renewal
    lf = json.load(open(lockfile)); lf['expires'] = int(time.time()) + 100; json.dump(lf, open(lockfile, 'w'))
    gid = f'lwl{RUN_ID}'
    bf1 = f'/tmp/agent-watch-budget-{gid}-EdgeApp-lwl-repo-pr1'
    bf2 = f'/tmp/agent-watch-budget-{gid}-EdgeApp-lwl-repo-pr2'

    def watch(pr, max_call='3'):
        return run(['bash', script('watch-pr.sh'), '--pr', pr, '--repo', 'EdgeApp/lwl-repo', '--task-gid', gid,
                    '--budget-seconds', '100', '--interval', '1'], env=dict(ENV, MAX_CALL=max_call))

    w = watch('1')
    check('watch-pr: exit 7 at MAX_CALL with RESULT: continue', w.returncode == 7 and 'RESULT: continue' in w.stdout, f'rc={w.returncode} {w.stdout[-200:]} {w.stderr[-300:]}')
    rem1 = int(open(bf1).read().split()[0]) if os.path.exists(bf1) else None
    check('watch-pr: budget file keyed by task+repo+PR, decremented', rem1 is not None and 90 <= rem1 < 100, rem1)
    check('watch-pr: land lease renewed during the watch', json.load(open(lockfile))['expires'] > int(time.time()) + 1000)
    watch('2')
    check('watch-pr: a second PR gets its own budget file', os.path.exists(bf2))
    check('watch-pr: second PR did not reset the first PR budget', int(open(bf1).read().split()[0]) == rem1)
    watch('1')
    rem1b = int(open(bf1).read().split()[0])
    check('watch-pr: re-invoke continues the preserved budget', rem1b < rem1, (rem1, rem1b))

    # pr-merge-watch.sh renews too
    lf = json.load(open(lockfile)); lf['expires'] = int(time.time()) + 100; json.dump(lf, open(lockfile, 'w'))
    spec = f'EdgeApp/lwl-repo#{RUN_ID}'
    m = run(['bash', script('pr-merge-watch.sh'), spec, '--interval', '1', '--timeout', '600'], env=dict(ENV, MAX_CALL='3'))
    check('pr-merge-watch: exit 7 CONTINUE', m.returncode == 7, f'rc={m.returncode} {m.stdout[-200:]}')
    check('pr-merge-watch: land lease renewed', json.load(open(lockfile))['expires'] > int(time.time()) + 1000)

    # verify-repo.sh renews at start (no package.json / CHANGELOG: passes fast)
    vdir = os.path.join(tmp, 'lwl-repo')
    os.makedirs(vdir, exist_ok=True)
    lf = json.load(open(lockfile)); lf['expires'] = int(time.time()) + 100; json.dump(lf, open(lockfile, 'w'))
    v = run(['node', script('verify-repo.sh'), vdir])
    check('verify-repo: passes and renews the land lease', v.returncode == 0 and json.load(open(lockfile))['expires'] > int(time.time()) + 1000, f'rc={v.returncode} {v.stderr[-300:]}')

    # pr-land-prepare.sh: failure releases the lease; a busy exit leaves a foreign lease alone
    os.remove(lockfile)
    pr = run(['node', script('pr-land-prepare.sh')], stdin=json.dumps([{'repo': 'lwl-repo', 'branch': 'x/y'}]))
    check('prepare: failing prepare exits 1', pr.returncode == 1, f'rc={pr.returncode} {pr.stderr[-300:]}')
    check('prepare: lease released on failure', not os.path.exists(lockfile), open(lockfile).read() if os.path.exists(lockfile) else '')
    lock('acquire', owner='owner-B')
    pr = run(['node', script('pr-land-prepare.sh')], stdin=json.dumps([{'repo': 'lwl-repo', 'branch': 'x/y'}]))
    check('prepare: busy lease -> exit 75, foreign lease untouched', pr.returncode == 75 and json.load(open(lockfile))['owner'] == 'owner-B', f'rc={pr.returncode}')
finally:
    for u in UDIDS:
        st = status(u)
        if st.get('pid') and alive(st['pid']) and 'exit' not in st:
            run(['bash', script('ios-rn-build-wait.sh'), '--udid', u, '--kill'])
        for f in (f'/tmp/ios-rn-build-{u}.log', f'/tmp/ios-rn-build-{u}.status', f'/tmp/ios-rn-build-runios-{u}.log'):
            if os.path.exists(f):
                os.remove(f)
    if os.path.exists('/tmp/metro-18999.log'):
        os.remove('/tmp/metro-18999.log')
    for f in os.listdir('/tmp'):
        if f.startswith(f'agent-watch-budget-lwl{RUN_ID}') or f.startswith(f'pr-merge-watch-') and f'lwl-repo-{RUN_ID}' in f:
            os.remove(os.path.join('/tmp', f))
    shutil.rmtree(tmp, ignore_errors=True)

print(f'\n{"FAILED: " + ", ".join(fails) if fails else "all passed"}')
sys.exit(1 if fails else 0)
