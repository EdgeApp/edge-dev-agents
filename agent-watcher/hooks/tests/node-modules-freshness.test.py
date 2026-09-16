#!/usr/bin/env python3
"""Contract tests for node_modules freshness (stale-clone marker, reinstall, refresh).

Run: python3 ~/.config/agent-watcher/hooks/tests/node-modules-freshness.test.py

Everything runs against throwaway fixtures under a temp dir: a fake HOME whose
~/.config/agent-watcher points at the scripts under test, a bare "origin" plus a
main checkout under fake ~/git, and a stub package manager (`npm` and `sfw` on
PATH) that fakes `ci`/`install` by writing node_modules/.package-lock.json. No
real install, network, worktree, launchd, or sim is touched.

Set NMF_SRC=<dir> to test staged copies (layout: <dir>/{setup-task-workspace.sh,
refresh-main-checkouts.sh,install-deps.sh,lib/}); default is the installed tree.
"""
import json, os, shutil, subprocess, sys, tempfile, time

AW = os.path.expanduser('~/.config/agent-watcher')
SRC = os.environ.get('NMF_SRC')
SETUP = os.path.join(SRC or AW, 'setup-task-workspace.sh')
REFRESH = os.path.join(SRC or AW, 'refresh-main-checkouts.sh')
LIBDIR = os.path.join(SRC or AW, 'lib')
INSTALL_DEPS = os.path.join(SRC, 'install-deps.sh') if SRC else os.path.expanduser('~/.cursor/skills/install-deps.sh')
PREP_CMD = os.path.expanduser('~/.cursor/skills/verification-prepare-cmd.sh')
IOS_RN_BUILD = os.environ.get('NMF_IOS_RN_BUILD', os.path.expanduser('~/.cursor/skills/build-and-test/scripts/ios-rn-build.sh'))
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


STUB = r'''#!/usr/bin/env bash
# fake package manager: records each call; `ci` refuses a pre-existing tree the
# way npm ci over an APFS clone does (ENOTEMPTY), so a missing mv-aside fails.
echo "$(basename "$0") $* @ $PWD" >> "$STUB_LOG"
[[ "$(basename "$0")" == sfw ]] && shift
write_hidden() { mkdir -p node_modules && jq 'del(.packages[""])' package-lock.json > node_modules/.package-lock.json; }
case "$1" in
  ci)
    if [[ -e node_modules ]]; then echo "ENOTEMPTY: directory not empty, rmdir node_modules" >&2; exit 66; fi
    if [[ -n "${STUB_CI_FAIL:-}" ]]; then mkdir -p node_modules/partial; echo "boom" >&2; exit 1; fi
    write_hidden ;;
  install)
    [[ -n "${STUB_INSTALL_NOOP:-}" ]] || write_hidden ;;
esac
exit 0
'''


def lock(version, deps, optional=None):
    pk = {'': {'name': 'demo', 'version': version, 'dependencies': {k: '*' for k in deps}}}
    for name, ver in deps.items():
        pk[f'node_modules/{name}'] = {'version': ver, 'resolved': f'https://r/{name}-{ver}.tgz', 'integrity': f'sha512-{name}{ver}'}
    for name, ver in (optional or {}).items():
        pk[f'node_modules/{name}'] = {'version': ver, 'resolved': f'https://r/{name}-{ver}.tgz', 'optional': True, 'os': ['linux']}
    return {'name': 'demo', 'version': version, 'lockfileVersion': 3, 'requires': True, 'packages': pk}


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, indent=2)


def hidden_from(lockobj, drop_optional=True):
    h = json.loads(json.dumps(lockobj))
    del h['packages']['']
    if drop_optional:
        h['packages'] = {k: v for k, v in h['packages'].items() if not v.get('optional')}
    return h


# realpath: macOS $TMPDIR (/var/folders) is a symlink into /private/var, and git
# worktree list prints resolved paths, so an unresolved fixture root never matches
# setup's reuse check (it tries worktree add again and fails on the existing branch).
tmp = os.path.realpath(tempfile.mkdtemp(prefix='nmf-', dir=os.environ.get('NMF_TMP')))
home = os.path.join(tmp, 'home')
state = os.path.join(tmp, 'state')
stubdir = os.path.join(tmp, 'bin')
stublog = os.path.join(tmp, 'stub.log')
aw = os.path.join(home, '.config/agent-watcher')
os.makedirs(os.path.join(aw, 'lib'))
os.makedirs(stubdir)
for f in ('setup-task-workspace.sh', 'refresh-main-checkouts.sh'):
    os.symlink(SETUP if f.startswith('setup') else REFRESH, os.path.join(aw, f))
for f in ('node-modules-freshness.sh', 'node-modules-reinstall.sh'):
    os.symlink(os.path.join(LIBDIR, f), os.path.join(aw, 'lib', f))
with open(os.path.join(aw, 'lib/launchd-env.sh'), 'w') as f:
    f.write('# test stub: keep the stub PATH\n')
for name in ('npm', 'sfw'):
    p = os.path.join(stubdir, name)
    with open(p, 'w') as f:
        f.write(STUB)
    os.chmod(p, 0o755)
skills = os.path.join(tmp, 'skills')
os.makedirs(skills)
os.symlink(INSTALL_DEPS, os.path.join(skills, 'install-deps.sh'))
os.symlink(PREP_CMD, os.path.join(skills, 'verification-prepare-cmd.sh'))
gitcfg = os.path.join(tmp, 'gitconfig')
with open(gitcfg, 'w') as f:
    f.write('[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = master\n[advice]\n\tdetachedHead = false\n')
clean_path = ':'.join(p for p in os.environ['PATH'].split(':') if p != os.path.expanduser('~/.agent-shims'))
ENV = dict(os.environ, HOME=home, XDG_STATE_HOME=state, PATH=f'{stubdir}:{clean_path}', STUB_LOG=stublog,
           GIT_CONFIG_GLOBAL=gitcfg, GIT_CONFIG_NOSYSTEM='1', NODE_MODULES_TRASH=os.path.join(tmp, 'trash'),
           TMPDIR=tmp, SETUP_REINSTALL_WAIT='40', NM_LOCK_WAIT='30')
ENV.pop('AGENT_TASK_GID', None)


def run(cmd, cwd=None, env=None, timeout=180):
    return subprocess.run(cmd, cwd=cwd, env=env or ENV, capture_output=True, text=True, timeout=timeout)


def git(*args, cwd):
    p = run(['git', *args], cwd=cwd)
    assert p.returncode == 0, (args, p.stderr)
    return p.stdout.strip()


def stub_calls(kind):
    try:
        return [l for l in open(stublog).read().splitlines() if f' {kind}' in l.split('@')[0]]
    except FileNotFoundError:
        return []


def reset_stub():
    open(stublog, 'w').close()




BASE_LOCK = lock('1.0.0', {'a': '1.0.0', 'b': '2.0.0'}, optional={'esb-linux': '0.1.0'})
origin = os.path.join(tmp, 'origin.git')
main = os.path.join(home, 'git', 'demo')
pusher = os.path.join(tmp, 'pusher')


def commit_lock(lockobj, msg):
    write_json(os.path.join(pusher, 'package-lock.json'), lockobj)
    git('add', '-A', cwd=pusher)
    git('commit', '-qm', msg, cwd=pusher)
    git('push', '-q', 'origin', 'master', cwd=pusher)


def install_main_tree():
    """Make the main checkout's node_modules match its lockfile (as a real install would)."""
    nm = os.path.join(main, 'node_modules')
    shutil.rmtree(nm, ignore_errors=True)
    write_json(os.path.join(nm, '.package-lock.json'), hidden_from(json.load(open(os.path.join(main, 'package-lock.json')))))
    os.makedirs(os.path.join(nm, 'a'), exist_ok=True)


try:
    run(['git', 'init', '-q', '--bare', '-b', 'master', origin])
    git('clone', '-q', origin, pusher, cwd=tmp)
    write_json(os.path.join(pusher, 'package.json'), {'name': 'demo', 'version': '1.0.0'})
    with open(os.path.join(pusher, '.gitignore'), 'w') as f:
        f.write('node_modules/\n.stale-node-modules\n')
    commit_lock(BASE_LOCK, 'base')
    os.makedirs(os.path.dirname(main))
    git('clone', '-q', origin, main, cwd=tmp)
    install_main_tree()

    # ---------------- normalization (lib, one process) ----------------
    lib = os.path.join(LIBDIR, 'node-modules-freshness.sh')
    fx = os.path.join(tmp, 'norm')
    write_json(os.path.join(fx, 'v1.json'), BASE_LOCK)
    write_json(os.path.join(fx, 'v2.json'), lock('1.0.1', {'a': '1.0.0', 'b': '2.0.0'}, optional={'esb-linux': '0.1.0'}))
    write_json(os.path.join(fx, 'hidden.json'), hidden_from(BASE_LOCK))
    write_json(os.path.join(fx, 'dep.json'), lock('1.0.0', {'a': '1.0.0', 'b': '2.1.0'}))
    p = run(['bash', '-c', '. "$1"; for f in v1 v2 hidden dep; do nm_lockfile_hash "$2/$f.json"; echo; done', '_', lib, fx])
    h = p.stdout.split()
    check('norm: four hashes computed', len(h) == 4, p.stderr)
    if len(h) == 4:
        check('norm: version-only lockfile diff hashes equal', h[0] == h[1])
        check('norm: hidden lockfile (no root, no skipped optional) equals its lockfile', h[0] == h[2])
        check('norm: real dep change hashes differ', h[0] != h[3])

    # ---------------- setup: version-only diff on a fresh worktree ----------------
    commit_lock(lock('1.0.1', {'a': '1.0.0', 'b': '2.0.0'}, optional={'esb-linux': '0.1.0'}), 'bump version only')
    reset_stub()
    p = run(['bash', os.path.join(aw, 'setup-task-workspace.sh'), '--task-gid', '101', '--repo', 'demo', '--base', 'origin/master'])
    wt1 = os.path.join(home, 'git/.agent-worktrees/101/demo')
    check('setup version-only: exit 0, path on stdout', p.returncode == 0 and p.stdout.strip().endswith(wt1), p.stderr[-800:])
    check('setup version-only: no marker written', not os.path.exists(os.path.join(wt1, '.stale-node-modules')), p.stderr[-400:])
    check('setup version-only: no install ran', stub_calls('ci') == [], open(stublog).read())
    check('setup version-only: clone handshake released', not [f for f in os.listdir(os.path.join(state, 'agent-watcher/main-clone')) if '.clone.' in f])

    # ---------------- setup: real dep diff (mismatch -> mv aside -> ci once -> cleared) ----------------
    commit_lock(lock('1.0.1', {'a': '1.0.0', 'b': '2.1.0'}), 'bump b')
    reset_stub()
    p = run(['bash', os.path.join(aw, 'setup-task-workspace.sh'), '--task-gid', '102', '--repo', 'demo', '--base', 'origin/master'])
    wt2 = os.path.join(home, 'git/.agent-worktrees/102/demo')
    check('setup dep diff: exit 0, stdout is only the path', p.returncode == 0 and p.stdout.strip() == wt2, p.stdout + p.stderr[-800:])
    check('setup dep diff: STALE reported', 'STALE node_modules' in p.stderr, p.stderr[-600:])
    cis = stub_calls('ci')
    check('setup dep diff: sfw npm ci called exactly once, in the worktree', len(cis) == 1 and cis[0].startswith('sfw npm ci') and cis[0].endswith('@ ' + wt2), cis)
    check('setup dep diff: marker cleared after install', not os.path.exists(os.path.join(wt2, '.stale-node-modules')), p.stderr[-600:])
    check('setup dep diff: installed tree now matches branch lockfile',
          json.load(open(os.path.join(wt2, 'node_modules/.package-lock.json')))['packages']['node_modules/b']['version'] == '2.1.0')
    check('setup dep diff: old tree moved aside to trash (not left in repo)',
          not [d for d in os.listdir(wt2) if d.startswith('node_modules.')])
    check('setup dep diff: install lock released', not os.path.exists(os.path.join(state, 'agent-watcher/npm-install.lock')))

    # ---------------- setup: reuse path runs the check ----------------
    write_json(os.path.join(wt1, 'package-lock.json'), lock('1.0.1', {'a': '1.1.0', 'b': '2.0.0'}))
    reset_stub()
    p = run(['bash', os.path.join(aw, 'setup-task-workspace.sh'), '--task-gid', '101', '--repo', 'demo', '--base', 'origin/master'])
    check('setup reuse: took the reuse path', 'reusing' in p.stderr and p.returncode == 0, p.stderr[-600:])
    check('setup reuse: mismatch detected and reinstalled once', len(stub_calls('ci')) == 1, open(stublog).read())
    check('setup reuse: marker cleared', not os.path.exists(os.path.join(wt1, '.stale-node-modules')))

    # ---------------- setup: install failure keeps marker and restores the tree ----------------
    write_json(os.path.join(wt1, 'package-lock.json'), lock('1.0.1', {'a': '1.2.0', 'b': '2.0.0'}))
    reset_stub()
    p = run(['bash', os.path.join(aw, 'setup-task-workspace.sh'), '--task-gid', '101', '--repo', 'demo'], env=dict(ENV, STUB_CI_FAIL='1'))
    marker = os.path.join(wt1, '.stale-node-modules')
    mk = open(marker).read() if os.path.exists(marker) else ''
    check('setup ci failure: exit 0 (setup not blocked)', p.returncode == 0, p.stderr[-600:])
    check('setup ci failure: marker kept with status=failed and hash pair', 'status=failed' in mk and 'want=' in mk and 'have=' in mk, mk)
    check('setup ci failure: previous tree restored',
          json.load(open(os.path.join(wt1, 'node_modules/.package-lock.json')))['packages']['node_modules/a']['version'] == '1.1.0')
    check('setup ci failure: failure surfaced on stderr', 'did not finish clean' in p.stderr, p.stderr[-600:])

    # ---------------- install-deps clears the marker ----------------
    reset_stub()
    p = run(['bash', os.path.join(skills, 'install-deps.sh'), wt1], env=dict(ENV, STUB_INSTALL_NOOP='1'))
    check('install-deps no-op install: marker kept', p.returncode == 0 and os.path.exists(marker), p.stderr[-400:])
    p = run(['bash', os.path.join(skills, 'install-deps.sh'), wt1])
    check('install-deps: npm install ran', len(stub_calls('install')) == 2, open(stublog).read())
    check('install-deps: marker cleared once hashes match', p.returncode == 0 and not os.path.exists(marker), p.stderr[-400:])

    # ---------------- ios-rn-build helpers (extracted functions, no build) ----------------
    script = r'''. "$1"; d="$2"
nm_install_skippable "$d" && echo skip=yes || echo skip=no
printf 'x\nstatus=stale\n' > "$d/.stale-node-modules"
nm_build_gate "$d" 5 && echo gate1=pass || echo gate1=block
[[ -f "$d/.stale-node-modules" ]] && echo marker1=kept || echo marker1=gone
cp "$d/package-lock.json" "$d/pl.bak"
jq '.packages["node_modules/a"].version="9.9.9"' "$d/pl.bak" > "$d/package-lock.json"
nm_install_skippable "$d" && echo skip2=yes || echo skip2=no
printf 'x\nstatus=stale\n' > "$d/.stale-node-modules"
nm_build_gate "$d" 5 && echo gate2=pass || echo gate2=block
mv "$d/pl.bak" "$d/package-lock.json"
'''
    p = run(['bash', '-c', script, '_', lib, wt1])
    out = p.stdout.split()
    check('ios-rn-build helper: fresh tree -> install skippable', 'skip=yes' in out, p.stdout + p.stderr)
    check('ios-rn-build helper: marker on a fresh tree -> gate passes and clears it', 'gate1=pass' in out and 'marker1=gone' in out, p.stdout)
    check('ios-rn-build helper: stale tree -> install not skippable', 'skip2=no' in out, p.stdout)
    check('ios-rn-build helper: marker on a stale tree -> gate blocks', 'gate2=block' in out, p.stdout)
    os.path.exists(marker) and os.remove(marker)
    src = open(IOS_RN_BUILD).read()
    check('ios-rn-build wiring: gate and install-skip call the lib helpers',
          'nm_build_gate' in src and 'nm_install_skippable' in src, IOS_RN_BUILD)

    # ---------------- refresh: stamp not written when every repo was held ----------------
    stamp = os.path.join(state, 'agent-watcher/main-checkouts-refresh.stamp')
    with open(os.path.join(main, 'scratch.txt'), 'w') as f:
        f.write('operator work\n')
    reset_stub()
    p = run(['bash', os.path.join(aw, 'refresh-main-checkouts.sh'), '--require-idle', 'demo'])
    check('refresh all held (dirty): HOLD reported', 'demo: HOLD (dirty' in p.stdout, p.stdout + p.stderr)
    check('refresh all held (dirty): no stamp', not os.path.exists(stamp), p.stdout)
    os.remove(os.path.join(main, 'scratch.txt'))

    # clone in progress holds the repo (live pid registered), no stamp, no install
    clone_file = os.path.join(state, 'agent-watcher/main-clone', f'demo.clone.{os.getpid()}')
    open(clone_file, 'w').close()
    p = run(['bash', os.path.join(aw, 'refresh-main-checkouts.sh'), '--require-idle', 'demo'])
    check('refresh clone live: HOLD for cloning', 'cloning' in p.stdout, p.stdout + p.stderr)
    check('refresh clone live: no fast-forward, no install, no stamp',
          git('rev-list', '--count', 'HEAD..origin/master', cwd=main) != '0' and stub_calls('ci') == [] and not os.path.exists(stamp), p.stdout)
    os.remove(clone_file)

    # install failure: recorded, previous tree kept, no stamp
    p = run(['bash', os.path.join(aw, 'refresh-main-checkouts.sh'), '--require-idle', 'demo'], env=dict(ENV, STUB_CI_FAIL='1'))
    fail_rec = os.path.join(state, 'agent-watcher/main-checkouts-install-failed/demo')
    check('refresh ci failure: fast-forwarded, failure recorded, no stamp',
          'FAILED' in p.stdout and os.path.exists(fail_rec) and not os.path.exists(stamp), p.stdout + p.stderr)
    check('refresh ci failure: no marker file dirtying the main checkout', not os.path.exists(os.path.join(main, '.stale-node-modules')))
    check('refresh ci failure: previous node_modules restored', os.path.isdir(os.path.join(main, 'node_modules/a')))

    # next sweep retries (no new commits) and succeeds -> stamp
    reset_stub()
    p = run(['bash', os.path.join(aw, 'refresh-main-checkouts.sh'), '--require-idle', '--min-interval', '21600', 'demo'])
    check('refresh retry: reinstall retried on the next sweep and succeeded',
          len(stub_calls('ci')) == 1 and 'reinstalled OK' in p.stdout and not os.path.exists(fail_rec), p.stdout + p.stderr)
    check('refresh retry: stamp written after a complete sweep', os.path.exists(stamp), p.stdout)

    # version-only pull: fast-forward, no install
    os.remove(stamp)
    commit_lock(lock('1.0.2', {'a': '1.0.0', 'b': '2.1.0'}), 'bump version only again')
    reset_stub()
    p = run(['bash', os.path.join(aw, 'refresh-main-checkouts.sh'), 'demo'])
    check('refresh version-only pull: FF without install, stamped',
          "FF'd" in p.stdout and stub_calls('ci') == [] and os.path.exists(stamp), p.stdout + p.stderr)
finally:
    subprocess.run(['bash', '-c', 'sleep 1; chmod -R u+w "$1" 2>/dev/null; true', '_', tmp])
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
