#!/usr/bin/env python3
"""Contract tests for lib/reconcile-branch.sh (setup-task-workspace.sh reuse path).

Run: python3 ~/.config/agent-watcher/hooks/tests/reconcile-branch.test.py

A followup reuses the task's retained worktree. If another session rewrote the
PR branch meanwhile, the worktree must land on the remote head (clean tree) or
refuse loudly (dirty tree); local unpushed work and an unchanged remote are left
alone. Synthetic bare origin + a "retained worktree" clone; nothing touches the
network.
"""
import os, shutil, subprocess, sys, tempfile

LIB = os.path.expanduser('~/.config/agent-watcher/lib/reconcile-branch.sh')
ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def sh(cmd, cwd):
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, env=ENV)
    if p.returncode != 0:
        raise RuntimeError(f'{cmd}\n{p.stdout}{p.stderr}')
    return p.stdout.strip()


def reconcile(wt, branch='feature'):
    p = subprocess.run(['bash', '-c', f'. {LIB}; reconcile_branch "$1" "$2"', '_', wt, branch], capture_output=True, text=True, env=ENV)
    return p.returncode, p.stderr.strip()


def head(wt):
    return sh('git rev-parse HEAD', wt)


tmp = tempfile.mkdtemp(prefix='reconcile-')
try:
    origin = os.path.join(tmp, 'origin.git'); wt = os.path.join(tmp, 'wt'); other = os.path.join(tmp, 'other')
    sh(f'git init -q --bare -b master {origin}', tmp)
    sh(f'git clone -q {origin} {wt}', tmp)
    open(os.path.join(wt, 'a.txt'), 'w').write('base\n')
    sh('git add -A && git commit -q -m base && git push -q origin master', wt)
    sh('git checkout -q -b feature', wt)
    open(os.path.join(wt, 'f.txt'), 'w').write('one\n')
    sh('git add -A && git commit -q -m "Add f" && git push -q -u origin feature', wt)
    sh(f'git clone -q {origin} {other} && git -C {other} checkout -q feature', tmp)

    rc, err = reconcile(wt)
    check('same head: no-op, silent', rc == 0 and err == '', f'rc={rc} {err}')

    open(os.path.join(wt, 'g.txt'), 'w').write('local\n')
    sh('git add -A && git commit -q -m "Local unpushed"', wt)
    before = head(wt)
    rc, err = reconcile(wt)
    check('local ahead: kept', rc == 0 and head(wt) == before and 'ahead' in err, f'rc={rc} {err}')
    sh('git reset -q --hard origin/feature', wt)

    # Another session rewrites the branch (amend + force-push).
    open(os.path.join(other, 'f.txt'), 'w').write('one, folded\n')
    sh('git add -A && git commit -q --amend -m "Add f (folded)" && git push -q --force origin feature', other)
    stale = head(wt)
    rc, err = reconcile(wt)
    check('remote rewritten, clean tree: reset to origin with the BRANCH MOVED notice',
          rc == 0 and head(wt) == sh('git rev-parse origin/feature', wt) and head(wt) != stale and 'BRANCH MOVED' in err and stale[:9] in err,
          f'rc={rc} {err}')

    open(os.path.join(other, 'f.txt'), 'w').write('one, folded twice\n')
    sh('git add -A && git commit -q --amend -m "Add f (folded twice)" && git push -q --force origin feature', other)
    open(os.path.join(wt, 'f.txt'), 'w').write('dirty edit\n')
    stale = head(wt)
    rc, err = reconcile(wt)
    check('remote rewritten, dirty tree: NOT reset, WARN', rc == 0 and head(wt) == stale and 'uncommitted' in err, f'rc={rc} {err}')
    sh('git checkout -q -- f.txt', wt)

    sh('git checkout -q master', wt)
    rc, err = reconcile(wt)
    check('worktree on another branch: left as-is with a WARN', rc == 0 and 'not' in err, f'rc={rc} {err}')

    rc, err = reconcile(wt, 'no-such-branch')
    check('fetch failure: rc 1, WARN, nothing touched', rc == 1 and 'fetch' in err, f'rc={rc} {err}')
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
