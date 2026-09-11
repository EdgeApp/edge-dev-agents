#!/usr/bin/env python3
"""Contract tests for the fixup discipline: body-required fixups, condense to one
fixup per target, and the TDD stamp fold.

Run: python3 ~/.config/agent-watcher/hooks/tests/fixup-discipline.test.py

  1. lint-commit.sh bounces a bodyless or kind-less fixup (both forms) and commits
     one with --fixup <sha> --for human|auto -m "<why>", writing the Fixup-for trailer.
  2. git-branch-ops.sh condense-fixups folds same-target, same-kind fixups into the
     group's first fixup: human and auto stay separate commits, legacy untagged
     fixups form their own group, bodies concatenated, nested "fixup! fixup!"
     subjects normalized, target commits and the final tree untouched, orphans
     left alone, idempotent.
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

    # ---- 1. lint-commit body + kind gate ----
    sh('echo a2 >> a.txt', repo)
    p = sh(f'{LC} --fixup {A} --no-reorder a.txt', repo)
    check('bodyless --fixup is bounced', p.returncode == 1 and 'needs a body' in p.stderr, p.stderr[:120])
    p = sh(f'{LC} -m "fixup! Add feature A" --no-reorder a.txt', repo)
    check('bodyless -m "fixup! ..." is bounced', p.returncode == 1 and 'needs a body' in p.stderr, p.stderr[:120])
    p = sh(f'{LC} --fixup {A} -m "Append a2 for the first A comment" --no-reorder a.txt', repo)
    check('fixup without --for is bounced', p.returncode == 1 and '--for human' in p.stderr, p.stderr[:120])
    p = sh(f'{LC} --fixup {A} --for human -m "Append a2 for the first A comment" --no-reorder a.txt', repo)
    check('--fixup --for human -m body commits with the trailer', p.returncode == 0 and git('log -1 --format=%B', repo) == 'fixup! Add feature A\n\nAppend a2 for the first A comment\n\nFixup-for: human', git('log -1 --format=%B', repo))
    sh('echo a3 >> a.txt', repo)
    p = sh(f'{LC} --fixup {A} --for human -m "A body line deliberately longer than fifty characters is fine here" --no-reorder a.txt', repo)
    check('--fixup body is not subject-length gated', p.returncode == 0 and git('log -1 --format=%s', repo) == 'fixup! Add feature A', p.stderr[:120])
    sh('echo a4 >> a.txt', repo)
    p = sh(f'{LC} --for auto -m "fixup! Add feature A\n\nBot finding one" --no-reorder a.txt', repo)
    check('-m "fixup! ..." form takes --for too', p.returncode == 0 and git('log -1 --format=%B', repo).endswith('Bot finding one\n\nFixup-for: auto'), git('log -1 --format=%B', repo))

    # ---- 2. condense: one fixup per target AND kind ----
    sh(f'echo b2 >> b.txt && git add b.txt && git commit -q --fixup {B} -m "Fix B once (legacy, no trailer)"', repo)
    F_AUTO = git('rev-parse HEAD~1', repo)
    sh(f'echo a5 >> a.txt && git add a.txt && git commit -q --fixup {F_AUTO} -m "Nested bot fix for A" -m "Fixup-for: auto"', repo)
    sh('echo o > o.txt && git add o.txt && git commit -q -m "fixup! Not on this branch" -m "orphan"', repo)
    tree = git('rev-parse HEAD^{tree}', repo)
    patch_b = git(f'show --format= {B}', repo)
    p = sh(f'{OPS} condense-fixups', repo)
    check('condense-fixups exits 0', p.returncode == 0, p.stderr[-300:])
    check('reports two groups for A (human x2, auto x2), 2 condensed', '"condensed":2' in p.stdout and '"for":"human","fixups":2' in p.stdout and '"for":"auto","fixups":2' in p.stdout, p.stdout)
    subjects = git('log --format=%s', repo).split('\n')
    check('two fixups for A remain, no nested subject', subjects.count('fixup! Add feature A') == 2 and not any(s.startswith('fixup! fixup!') for s in subjects), subjects)
    kinds = [git(f'log -1 --format=%b {h}', repo).split('Fixup-for: ')[-1].strip() for h in git('log --format=%H --grep="^fixup! Add feature A"', repo).split()]
    check('one human and one auto fixup for A, each with its trailer', sorted(kinds) == ['auto', 'human'], kinds)
    check('single legacy fixup for B untouched, still untagged', subjects.count('fixup! Add feature B') == 1 and 'Fixup-for' not in git('log --format=%b --grep="^fixup! Add feature B" -1', repo))
    check('orphan fixup left alone', 'fixup! Not on this branch' in subjects)
    # Slotting A's fixups after A rewrites everything behind them (same as
    # slot-fixup.sh), so B's sha moves but its patch does not; A is untouched.
    check('target commits untouched', git(f'log --format=%H --grep="^Add feature A$" -1', repo) == A
          and git(f'show --format= {git("log --format=%H --grep=^Add.feature.B$ -1", repo)}', repo) == patch_b)
    check('final tree identical', git('rev-parse HEAD^{tree}', repo) == tree)
    human = [git(f'log -1 --format=%B {h}', repo) for h in git('log --format=%H --grep="^fixup! Add feature A"', repo).split()]
    human = next(m for m in human if m.endswith('Fixup-for: human'))
    check('human bodies concatenated in order, one trailer', human.index('Append a2') < human.index('deliberately longer') and human.count('Fixup-for') == 1, human)
    idx = {s: i for i, s in enumerate(reversed(subjects))}
    check('condensed fixups sit right after their target', [s for s in reversed(subjects)][idx['Add feature A'] + 1:idx['Add feature A'] + 3] == ['fixup! Add feature A'] * 2, subjects)
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
