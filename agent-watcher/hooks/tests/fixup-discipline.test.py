#!/usr/bin/env python3
"""Contract tests for the fixup discipline: body-required fixups, condense to one
fixup per target, and the TDD stamp fold.

Run: python3 ~/.config/agent-watcher/hooks/tests/fixup-discipline.test.py

  1. lint-commit.sh bounces a bodyless fixup (both forms) and commits one with a
     body via --fixup <sha> -m "<why>".
  2. git-branch-ops.sh condense-fixups folds same-target fixups into the group's
     first fixup: bodies concatenated, nested "fixup! fixup!" subjects normalized,
     target commits and the final tree untouched, orphans left alone, idempotent.
  3. tdd-stamp.sh --fold stamps a fresh doc and folds it into the branch's first
     commit; a second --fold with nothing changed is a no-op.
pr-finalize-fixups.sh wires 2 and 3 into every push but needs a live PR for its
review-mode oracle, so it is exercised by real runs, not here.
"""
import os, shutil, subprocess, sys, tempfile

SK = os.path.expanduser('~/.cursor/skills')
LC = f'{SK}/lint-commit.sh'
OPS = f'{SK}/git-branch-ops.sh'
STAMP = f'{SK}/tdd/scripts/tdd-stamp.sh'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def sh(cmd, cwd):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)


def git(cmd, cwd):
    return sh('git ' + cmd, cwd).stdout.strip()


tmp = tempfile.mkdtemp(prefix='fixup-')
try:
    # ---- repo with a bare origin so the default-upstream resolution works ----
    remote = os.path.join(tmp, 'remote.git'); repo = os.path.join(tmp, 'repo')
    sh(f'git init -q --bare -b master {remote}', tmp)
    os.makedirs(repo)
    sh('git init -q -b master && git commit -q --allow-empty -m Base', repo)
    sh(f'git remote add origin {remote} && git push -q origin master && git remote set-head origin master', repo)
    sh('git checkout -q -b feat', repo)
    sh('echo a > a.txt && git add a.txt && git commit -q -m "Add feature A"', repo); A = git('rev-parse HEAD', repo)
    sh('echo b > b.txt && git add b.txt && git commit -q -m "Add feature B"', repo); B = git('rev-parse HEAD', repo)
    sh('echo c > c.txt && git add c.txt && git commit -q -m "Add feature C"', repo)

    # ---- 1. lint-commit body gate ----
    sh('echo a2 >> a.txt', repo)
    p = sh(f'{LC} --fixup {A} --no-reorder a.txt', repo)
    check('bodyless --fixup is bounced', p.returncode == 1 and 'needs a body' in p.stderr, p.stderr[:120])
    p = sh(f'{LC} -m "fixup! Add feature A" --no-reorder a.txt', repo)
    check('bodyless -m "fixup! ..." is bounced', p.returncode == 1 and 'needs a body' in p.stderr, p.stderr[:120])
    p = sh(f'{LC} --fixup {A} -m "Append a2 for the first A finding" --no-reorder a.txt', repo)
    check('--fixup with -m body commits', p.returncode == 0 and git('log -1 --format=%B', repo) == 'fixup! Add feature A\n\nAppend a2 for the first A finding', p.stderr[:120])
    sh('echo a3 >> a.txt', repo)
    p = sh(f'{LC} --fixup {A} -m "A body line deliberately longer than fifty characters is fine here" --no-reorder a.txt', repo)
    check('--fixup body is not subject-length gated', p.returncode == 0 and git('log -1 --format=%s', repo) == 'fixup! Add feature A', p.stderr[:120])

    # ---- 2. condense ----
    sh(f'echo b2 >> b.txt && git add b.txt && git commit -q --fixup {B} -m "Fix B once"', repo)
    F1 = git('log --format=%H --grep="^fixup! Add feature A" -1 --reverse', repo)
    sh(f'echo a4 >> a.txt && git add a.txt && git commit -q --fixup {F1} -m "Nested fix for A"', repo)
    sh('echo o > o.txt && git add o.txt && git commit -q -m "fixup! Not on this branch" -m "orphan"', repo)
    tree = git('rev-parse HEAD^{tree}', repo)
    patch_b = git(f'show --format= {B}', repo)
    p = sh(f'{OPS} condense-fixups', repo)
    check('condense-fixups exits 0', p.returncode == 0, p.stderr[-300:])
    check('reports 2 condensed in one group', '"condensed":2' in p.stdout and '"fixups":3' in p.stdout, p.stdout)
    subjects = git('log --format=%s', repo).split('\n')
    check('one fixup for A, nested subject normalized', subjects.count('fixup! Add feature A') == 1 and not any(s.startswith('fixup! fixup!') for s in subjects), subjects)
    check('single fixup for B untouched', subjects.count('fixup! Add feature B') == 1)
    check('orphan fixup left alone', 'fixup! Not on this branch' in subjects)
    # Slotting A's fixups after A rewrites everything behind them (same as
    # slot-fixup.sh), so B's sha moves but its patch does not; A is untouched.
    check('target commits untouched', git(f'log --format=%H --grep="^Add feature A$" -1', repo) == A
          and git(f'show --format= {git("log --format=%H --grep=^Add.feature.B$ -1", repo)}', repo) == patch_b)
    check('final tree identical', git('rev-parse HEAD^{tree}', repo) == tree)
    body = git('log --format=%B --grep="^fixup! Add feature A" -1', repo)
    check('bodies concatenated in order', body.index('Append a2') < body.index('deliberately longer') < body.index('Nested fix'), body)
    idx = {s: i for i, s in enumerate(reversed(subjects))}
    check('condensed fixup sits right after its target', idx['fixup! Add feature A'] == idx['Add feature A'] + 1, subjects)
    p = sh(f'{OPS} condense-fixups', repo)
    check('idempotent: second run condenses nothing', p.returncode == 0 and '"condensed":0' in p.stdout, p.stdout)

    # ---- 3. tdd-stamp --fold ----
    os.makedirs(os.path.join(repo, 'src/docs'))
    open(os.path.join(repo, 'src/docs/design.md'), 'w').write('# Design\n\n| Status | Phase |\n|---|---|\n| current | 1 |\n\nBody.\n')
    p = sh(f'{STAMP} . src/docs/design.md --fold', repo)
    first = git('rev-list --reverse origin/master..HEAD', repo).split()[0]
    check('--fold stamps and folds the doc into the first commit', p.returncode == 0 and 'src/docs/design.md' in git(f'show --name-only --format= {first}', repo), p.stderr[-200:])
    check('stamp is current after the fold', sh(f'{STAMP} . src/docs/design.md --check', repo).returncode == 0)
    p = sh(f'{STAMP} . src/docs/design.md --fold', repo)
    check('--fold with nothing to do is a no-op', p.returncode == 0 and 'nothing to fold' in p.stdout, p.stdout)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
