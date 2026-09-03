#!/usr/bin/env python3
"""Contract tests for require-tdd-current.sh and tdd-stamp.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/require-tdd-current.test.py

The doc rides in the branch's FIRST commit, so freshness cannot come from
history position. Properties:
  1. tdd-stamp.sh writes one fingerprint comment after the metadata table and
     replaces it on re-stamp; --check reports current / stale / no-stamp.
  2. A stamped doc folded into the first commit passes the Complete gate even
     though code commits come after it.
  3. A code change after the stamp blocks Complete; re-stamping (and folding)
     clears it.
  4. An unstamped doc keeps the legacy last-commit comparison.
  5. The waiver note bypasses the block.
The Asana field lookup is stubbed with a temp HOME that carries a fake
asana-field-value.sh; the worktree layout mirrors ~/git/.agent-worktrees/<gid>/<repo>.
"""
import json, os, shutil, subprocess, sys, tempfile

HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/require-tdd-current.sh')
STAMP = os.path.expanduser('~/.cursor/skills/tdd/scripts/tdd-stamp.sh')
GID = '5151515151'
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
               GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
failures = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    if not cond:
        failures.append(name)


def sh(cmd, cwd, check_rc=True):
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, env=GIT_ENV)
    if check_rc and p.returncode != 0:
        raise RuntimeError(f'{cmd}\n{p.stdout}{p.stderr}')
    return p


def write(repo, name, text):
    os.makedirs(os.path.dirname(os.path.join(repo, name)), exist_ok=True)
    with open(os.path.join(repo, name), 'w') as fh:
        fh.write(text)


tmp = tempfile.mkdtemp(prefix='tdd-current-')
try:
    home = os.path.join(tmp, 'home')
    os.makedirs(os.path.join(home, '.cursor/skills/tdd/scripts'))
    os.symlink(os.path.expanduser('~/.config'), os.path.join(home, '.config'))
    os.symlink(STAMP, os.path.join(home, '.cursor/skills/tdd/scripts/tdd-stamp.sh'))
    fv = os.path.join(home, '.cursor/skills/asana-field-value.sh')
    with open(fv, 'w') as fh:
        fh.write('#!/bin/bash\necho tdd\n')
    os.chmod(fv, 0o755)
    repo = os.path.join(home, 'git/.agent-worktrees', GID, 'repo')
    os.makedirs(repo)
    sh('git init -q -b master', repo)
    write(repo, 'src/a.ts', 'export const a = 1\n')
    sh('git add -A && git commit -q -m "Base"', repo)
    sh('git checkout -q -b feature', repo)
    write(repo, 'src/feat.ts', 'export const feat = 1\n')
    sh('git add -A && git commit -q -m "Add the feature"', repo)
    first = sh('git rev-parse HEAD', repo).stdout.strip()
    write(repo, 'src/more.ts', 'export const more = 2\n')
    sh('git add -A && git commit -q -m "Add more"', repo)

    def hook(cmd='~/.config/agent-watcher/update-status.sh 5151515151 Complete'):
        env = dict(GIT_ENV, HOME=home, AGENT_TASK_GID=GID)
        p = subprocess.run([HOOK], input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': cmd}}),
                           capture_output=True, text=True, env=env, timeout=60)
        return p.returncode, p.stderr

    # stamp + fold into first commit
    doc = 'src/docs/feature.md'
    write(repo, doc, '# Feature\n\n| | |\n|---|---|\n| Status | Implemented |\n\n## Contents\n\nbody\n')
    p = sh(f'{STAMP} {repo} {doc}', repo)
    body = open(os.path.join(repo, doc)).read()
    check('stamp inserted after the metadata table', body.count('tdd-code-fingerprint') == 1 and body.index('tdd-code-fingerprint') > body.index('| Status'), body)
    sh(f'{STAMP} {repo} {doc}', repo)
    check('re-stamp replaces, never duplicates', open(os.path.join(repo, doc)).read().count('tdd-code-fingerprint') == 1)
    rc = subprocess.run([STAMP, repo, doc, '--check'], capture_output=True, text=True, env=GIT_ENV).returncode
    check('--check reports current after stamping', rc == 0)
    sh(f'git add -A && git commit -q --fixup {first}', repo)
    sh(f'GIT_SEQUENCE_EDITOR=: git rebase -q -i --autosquash master', repo)
    check('doc folded into the first commit', doc in sh(f'git show --name-only --format= {sh("git rev-list --reverse master..HEAD", repo).stdout.split()[0]}', repo).stdout)
    rc, err = hook()
    check('stamped doc in the first commit passes Complete gate', rc == 0, err[:300])

    write(repo, 'src/later.ts', 'export const later = 3\n')
    sh('git add -A && git commit -q -m "Later code"', repo)
    rc, err = hook()
    check('code change after the stamp blocks Complete', rc == 2 and 'different code tree' in err, f'rc={rc} {err[:200]}')
    rc = subprocess.run([STAMP, repo, doc, '--check'], capture_output=True, text=True, env=GIT_ENV).returncode
    check('--check reports stale', rc == 1)
    waiver = f'/tmp/agent-tdd-current-waiver-{GID}.md'
    open(waiver, 'w').write('no doc change owed: test\n')
    rc, err = hook()
    check('waiver note bypasses', rc == 0)
    os.remove(waiver)
    sh(f'{STAMP} {repo} {doc}', repo)
    first = sh('git rev-list --reverse master..HEAD', repo).stdout.split()[0]
    sh(f'git add -A && git commit -q --fixup {first} && GIT_SEQUENCE_EDITOR=: git rebase -q -i --autosquash master', repo)
    rc, err = hook()
    check('re-stamp + fold clears the block', rc == 0, err[:200])

    # legacy: unstamped doc, doc commit last -> pass; code after -> block
    sh('git checkout -q -b legacy master', repo)
    write(repo, 'src/x.ts', 'x\n'); sh('git add -A && git commit -q -m "code"', repo)
    write(repo, doc, '# Legacy\n\n| | |\n|---|---|\n| Status | x |\n'); sh('git add -A && git commit -q -m "doc"', repo)
    sh('git branch -q -u master', repo)
    rc, err = hook()
    check('unstamped doc newer than code passes (legacy)', rc == 0, err[:200])
    write(repo, 'src/y.ts', 'y\n'); sh('git add -A && GIT_COMMITTER_DATE="$(date -v+10S 2>/dev/null || date -d "+10 seconds")" git commit -q -m "code2"', repo)
    rc, err = hook()
    check('unstamped doc older than code blocks (legacy)', rc == 2 and 'older than the code' in err, f'rc={rc} {err[:200]}')
    rc, err = hook('git status')
    check('non-Complete command untouched', rc == 0)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(failures)} failure(s)' if failures else '\nall passed')
sys.exit(1 if failures else 0)
