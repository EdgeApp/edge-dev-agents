#!/usr/bin/env python3
"""Contract tests for `git-branch-ops.sh self-rewrite` and its two callers.

Run: python3 ~/.config/agent-watcher/hooks/tests/self-rewrite-gate.test.py

The rule under test: an unpublished, non-fixup commit whose removed lines were
introduced by commits already on the remote branch is an amendment of that
work and must be folded before a push in autosquash mode. Properties that are
easy to break later:

  1. Detection keys on PUBLISHED branch lines. Rewriting base-branch lines, or
     lines from a commit that is itself unpublished, is not a self-rewrite.
  2. fixup!/squash! commits are the compliant shape and are never candidates.
  3. A purely additive commit (new surface) is never flagged.
  4. The thresholds hold: fewer than --min-lines removed lines never flags.
  5. --gate exits 2 with the remediation on stderr, and the concession note
     (/tmp/agent-history-concession-<gid>.md) is the only bypass.
  6. git-history-gate.sh runs the check on a raw `git push` only when the
     review-mode oracle says autosquash; preserve mode keeps its own block.

Repos are synthetic (a bare "origin" plus a clone); the oracle and gh are
stubbed via a temp HOME and a PATH shim, so nothing touches the network.
"""
import json, os, shutil, subprocess, sys, tempfile

OPS = os.path.expanduser('~/.cursor/skills/git-branch-ops.sh')
HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/git-history-gate.sh')
GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
               GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
GID = '4242424242'


def sh(cmd, cwd, env=None, check=True):
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                       env=env or GIT_ENV)
    if check and p.returncode != 0:
        raise RuntimeError(f'{cmd}\n{p.stdout}{p.stderr}')
    return p


def write(repo, name, lines):
    with open(os.path.join(repo, name), 'w') as fh:
        fh.write('\n'.join(lines) + '\n')


def commit(repo, msg, *files):
    sh('git add ' + ' '.join(files), repo)
    sh(f'git commit -q -m "{msg}"', repo)
    return sh('git rev-parse HEAD', repo).stdout.strip()


def fresh_repo(tmp):
    """bare origin + clone with master (base) and a pushed feature branch."""
    origin = os.path.join(tmp, 'origin.git')
    repo = os.path.join(tmp, 'repo')
    if os.path.exists(origin):
        shutil.rmtree(origin)
    if os.path.exists(repo):
        shutil.rmtree(repo)
    sh(f'git init -q --bare -b master {origin}', tmp)
    sh(f'git clone -q {origin} {repo}', tmp)
    write(repo, 'base.txt', [f'base {i}' for i in range(20)])
    commit(repo, 'Base file', 'base.txt')
    sh('git push -q origin master', repo)
    sh('git checkout -q -b feature', repo)
    write(repo, 'feat.txt', [f'feat {i}' for i in range(20)])
    a = commit(repo, 'Add the feature surface', 'feat.txt')
    return repo, a


def self_rewrite(repo, *args, env=None):
    p = subprocess.run([OPS, 'self-rewrite', *args], cwd=repo, capture_output=True,
                       text=True, env=env or GIT_ENV)
    out = json.loads(p.stdout.strip() or '{}')
    return p.returncode, out, p.stderr


def hook(cmd, home, path_dir):
    env = dict(GIT_ENV, HOME=home, AGENT_TASK_GID=GID,
               PATH=path_dir + ':' + os.environ['PATH'])
    p = subprocess.run([HOOK], input=json.dumps({'tool_name': 'Bash',
                                                 'tool_input': {'command': cmd}}),
                       capture_output=True, text=True, env=env, timeout=60)
    return p.returncode, p.stderr


failures = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    if not cond:
        failures.append(name)


tmp = tempfile.mkdtemp(prefix='self-rewrite-')
try:
    # ---- script contract -------------------------------------------------
    repo, a = fresh_repo(tmp)
    rc, out, _ = self_rewrite(repo)
    check('no upstream yet -> no-upstream, nothing flagged',
          out.get('status') == 'no-upstream' and out.get('flagged') == [], out)

    sh('git push -q -u origin feature', repo)
    write(repo, 'other.txt', [f'other {i}' for i in range(10)])
    commit(repo, 'Add a second surface', 'other.txt')
    rc, out, _ = self_rewrite(repo)
    check('additive commit is a candidate but not flagged',
          out.get('candidates') == 1 and out.get('flagged') == [], out)

    write(repo, 'feat.txt', [f'feat {i} reworked' if i < 10 else f'feat {i}' for i in range(20)])
    b = commit(repo, 'Rework the feature surface', 'feat.txt')
    rc, out, _ = self_rewrite(repo)
    flagged = out.get('flagged', [])
    check('rewrite of published branch lines is flagged with its target',
          len(flagged) == 1 and flagged[0]['removed'] == 10 and flagged[0]['published'] == 10
          and flagged[0]['targets'] and flagged[0]['targets'][0].endswith('Add the feature surface'),
          out)
    check('unflagged status stays 0 without --gate', rc == 0)

    rc, out, err = self_rewrite(repo, '--gate', env=dict(GIT_ENV, AGENT_TASK_GID=GID))
    check('--gate exits 2 with the remediation', rc == 2 and 'fold target' in err and 'lint-commit.sh --fixup' in err, err[:200])
    note = f'/tmp/agent-history-concession-{GID}.md'
    with open(note, 'w') as fh:
        fh.write('kept separate on purpose: test\n')
    rc, out, err = self_rewrite(repo, '--gate', env=dict(GIT_ENV, AGENT_TASK_GID=GID))
    check('concession note is the bypass', rc == 0, err[:200])
    os.remove(note)

    sh('git reset -q --hard HEAD~1', repo)
    write(repo, 'feat.txt', [f'feat {i} reworked' if i < 10 else f'feat {i}' for i in range(20)])
    commit(repo, 'fixup! Add the feature surface', 'feat.txt')
    rc, out, _ = self_rewrite(repo)
    check('fixup! commit is not a candidate', out.get('candidates') == 1 and out.get('flagged') == [], out)

    sh('git reset -q --hard HEAD~1', repo)
    write(repo, 'feat.txt', [f'feat {i} reworked' if i < 3 else f'feat {i}' for i in range(20)])
    commit(repo, 'Touch three lines', 'feat.txt')
    rc, out, _ = self_rewrite(repo)
    check('below --min-lines is not flagged', out.get('flagged') == [], out)

    sh('git reset -q --hard HEAD~1', repo)
    write(repo, 'base.txt', [f'base {i} edited' for i in range(20)])
    commit(repo, 'Edit base-branch lines', 'base.txt')
    rc, out, _ = self_rewrite(repo)
    check('rewriting base-branch lines is not a self-rewrite', out.get('flagged') == [], out)

    sh('git reset -q --hard HEAD~1', repo)
    write(repo, 'new.txt', [f'new {i}' for i in range(10)])
    commit(repo, 'Add new file', 'new.txt')
    write(repo, 'new.txt', [f'new {i} again' for i in range(10)])
    commit(repo, 'Rework the unpublished file', 'new.txt')
    rc, out, _ = self_rewrite(repo)
    check('rewriting an UNPUBLISHED commit is not flagged (fold happens locally anyway)',
          out.get('candidates') == 3 and out.get('flagged') == [], out)

    # ---- hook wiring ------------------------------------------------------
    home = os.path.join(tmp, 'home')
    os.makedirs(os.path.join(home, '.cursor/skills/pr-address/scripts'))
    os.symlink(os.path.expanduser('~/.config'), os.path.join(home, '.config'))
    os.symlink(OPS, os.path.join(home, '.cursor/skills/git-branch-ops.sh'))
    oracle = os.path.join(home, '.cursor/skills/pr-address/scripts/pr-address.sh')
    mode_file = os.path.join(tmp, 'mode')
    with open(oracle, 'w') as fh:
        fh.write('#!/bin/bash\nprintf \'{"mode":"%s"}\\n\' "$(cat ' + mode_file + ')"\n')
    os.chmod(oracle, 0o755)
    shim = os.path.join(tmp, 'bin')
    os.makedirs(shim)
    with open(os.path.join(shim, 'gh'), 'w') as fh:
        fh.write('#!/bin/bash\necho \'{"number":7,"headRepositoryOwner":{"login":"o"},"headRepository":{"name":"r"}}\'\n')
    os.chmod(os.path.join(shim, 'gh'), 0o755)

    sh('git reset -q --hard origin/feature', repo)
    write(repo, 'feat.txt', [f'feat {i} reworked' if i < 10 else f'feat {i}' for i in range(20)])
    commit(repo, 'Rework the feature surface', 'feat.txt')
    with open(mode_file, 'w') as fh:
        fh.write('autosquash')
    rc, err = hook(f'cd {repo} && git push origin feature', home, shim)
    check('raw push in autosquash mode with a self-rewrite is blocked',
          rc == 2 and 'rewrite lines already published' in err, f'rc={rc} {err[:200]}')
    with open(mode_file, 'w') as fh:
        fh.write('preserve')
    rc, err = hook(f'cd {repo} && git push origin feature', home, shim)
    check('preserve mode keeps its own push block (no self-rewrite text)',
          rc == 2 and 'PRESERVE' in err and 'rewrite lines already published' not in err, f'rc={rc} {err[:200]}')
    with open(mode_file, 'w') as fh:
        fh.write('autosquash')
    sh('git reset -q --hard HEAD~1', repo)
    write(repo, 'other.txt', [f'other {i}' for i in range(10)])
    commit(repo, 'Add a second surface', 'other.txt')
    rc, err = hook(f'cd {repo} && git push origin feature', home, shim)
    check('raw push of an additive commit passes', rc == 0, f'rc={rc} {err[:200]}')
    rc, err = hook(f'cd {repo} && git status', home, shim)
    check('non-push command is untouched', rc == 0, f'rc={rc} {err[:200]}')
    with open(mode_file, 'w') as fh:
        fh.write('preserve')
    approval = f'/tmp/agent-history-rewrite-approved-{GID}.md'
    with open(approval, 'w') as fh:
        fh.write('operator comment gid 1: rewrite approved\n')
    rc, err = hook(f'cd {repo} && git push --force-with-lease origin feature', home, shim)
    check('preserve mode + operator rewrite approval allows the push', rc == 0, f'rc={rc} {err[:200]}')
    rc, err = hook(f'cd {repo} && git rebase -i --autosquash origin/master', home, shim)
    check('preserve mode + operator rewrite approval allows the autosquash', rc == 0, f'rc={rc} {err[:200]}')
    os.remove(approval)
    rc, err = hook(f'cd {repo} && git rebase -i --autosquash origin/master', home, shim)
    check('without the approval the preserve squash block returns', rc == 2, f'rc={rc}')

    # ---- fold-mode (lint-commit's post-fixup decision) ----------------------
    def fold_mode(gid=GID):
        env = dict(GIT_ENV, HOME=home, PATH=shim + ':' + os.environ['PATH'])
        if gid:
            env['AGENT_TASK_GID'] = gid
        p = subprocess.run([OPS, 'fold-mode'], cwd=repo, capture_output=True, text=True, env=env)
        return json.loads(p.stdout.strip())
    with open(mode_file, 'w') as fh:
        fh.write('preserve')
    d = fold_mode()
    check('fold-mode: preserve -> keep the fixup', d['fold'] is False and d['mode'] == 'preserve', d)
    with open(approval, 'w') as fh:
        fh.write('operator comment gid 1: rewrite approved\n')
    d = fold_mode()
    check('fold-mode: preserve + operator approval -> fold', d['fold'] is True and d['mode'] == 'preserve', d)
    os.remove(approval)
    with open(mode_file, 'w') as fh:
        fh.write('autosquash')
    d = fold_mode()
    check('fold-mode: autosquash -> fold', d['fold'] is True and d['mode'] == 'autosquash', d)
    with open(os.path.join(shim, 'gh'), 'w') as fh:
        fh.write('#!/bin/bash\nexit 1\n')
    d = fold_mode()
    check('fold-mode: no PR -> fold (fail open)', d['fold'] is True and d['mode'] == 'no-pr', d)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print(f'\n{len(failures)} failure(s)' if failures else '\nall passed')
sys.exit(1 if failures else 0)
