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
  4. git-branch-ops.sh fold-before folds only fixups AUTHORED before the cutoff,
     compared as instants (an offset timestamp that sorts earlier as a string
     but is later in time stays), leaving newer fixups and the tree intact.
  5. condense-fixups falls back to one group per target in original order when
     the per-kind regroup conflicts (interleaved human/auto edits of one line).
pr-finalize-fixups.sh wires 2, 3 and 4 into every push but needs a live PR for its
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

    # ---- 4. fold-before: author-date cutoff, compared as instants ----
    r4 = os.path.join(tmp, 'r4'); os.makedirs(r4)
    sh(f'git init -q -b master && git commit -q --allow-empty -m Base && git remote add origin {remote} && git checkout -q -b f4', r4)
    sh('echo t > t.txt && git add t.txt && git commit -q -m "Add T"', r4)
    sh('echo u > u.txt && git add u.txt && git commit -q -m "Add U"', r4)
    def fx(cwd, f, line, subj, date):
        sh(f'echo {line} >> {f} && git add {f} && GIT_AUTHOR_DATE={date} git commit -q -m "fixup! {subj}" -m "{line}"', cwd)
    fx(r4, 't.txt', 't1', 'Add T', '2026-01-01T00:00:00Z')
    fx(r4, 'u.txt', 'u1', 'Add U', '2026-01-02T00:00:00Z')
    fx(r4, 't.txt', 't2', 'Add T', '2026-01-03T00:00:00-07:00')
    fx(r4, 't.txt', 't3', 'Add T', '2026-01-04T00:00:00Z')
    base4 = git('rev-parse HEAD~6', r4); tree4 = git('rev-parse HEAD^{tree}', r4)
    p = sh(f'{OPS} fold-before --before 2026-01-03T05:00:00Z --base {base4}', r4)
    check('fold-before exits 0 and folds 2', p.returncode == 0 and '"folded":2' in p.stdout, p.stdout + p.stderr[-300:])
    s4 = git(f'log --reverse --format=%s {base4}..HEAD', r4).split('\n')
    check('offset-dated and newer fixups stay, in order', s4 == ['Add T', 'Add U', 'fixup! Add T', 'fixup! Add T'], s4)
    check('older fixups landed in their targets', git('show HEAD~3:t.txt', r4) == 't\nt1' and git('show HEAD~2:u.txt', r4) == 'u\nu1')
    check('fold-before keeps the tree', git('rev-parse HEAD^{tree}', r4) == tree4)
    p = sh(f'{OPS} fold-before --before 2026-01-03T05:00:00Z --base {base4}', r4)
    check('fold-before idempotent', p.returncode == 0 and '"folded":0' in p.stdout, p.stdout)
    p = sh(f'{OPS} fold-before --before not-a-date --base {base4}', r4)
    check('fold-before rejects an unparseable cutoff', p.returncode != 0)

    # ---- 5. condense fallback on a per-kind regroup conflict ----
    r5 = os.path.join(tmp, 'r5'); os.makedirs(r5)
    sh(f'git init -q -b master && git commit -q --allow-empty -m Base && git remote add origin {remote} && git checkout -q -b f5', r5)
    sh('echo x=1 > x.txt && git add x.txt && git commit -q -m "Add X"', r5)
    for val, kind in (('2', 'human'), ('3', 'auto'), ('4', 'human')):
        sh(f'echo x={val} > x.txt && git add x.txt && git commit -q -m "fixup! Add X" -m "set {val}" -m "Fixup-for: {kind}"', r5)
    base5 = git('rev-parse HEAD~4', r5); tree5 = git('rev-parse HEAD^{tree}', r5)
    p = sh(f'{OPS} condense-fixups --base {base5}', r5)
    check('condense falls back instead of failing', p.returncode == 0 and '"fallback":"one-per-target"' in p.stdout, p.stdout + p.stderr[-300:])
    s5 = git(f'log --format=%s {base5}..HEAD', r5).split('\n')
    check('one fixup left for X, kind human', s5 == ['fixup! Add X', 'Add X'] and git('log -1 --format=%b', r5).strip().endswith('Fixup-for: human'), s5)
    check('fallback keeps the tree', git('rev-parse HEAD^{tree}', r5) == tree5)
    check('no rebase left in progress', not os.path.isdir(os.path.join(r5, '.git/rebase-merge')))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
