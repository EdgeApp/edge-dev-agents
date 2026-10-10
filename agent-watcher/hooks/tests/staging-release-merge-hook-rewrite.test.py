#!/usr/bin/env python3
"""Contract test for the merge-commit restore in develop-staging's
staging-release-merge.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/staging-release-merge-hook-rewrite.test.py

The repo's pre-commit hook removes every staged file from the warning list in
eslint.config.mjs. A conflicted release merge stages develop's whole delta, so
the hook strips entries develop still carries. The script must leave the merge
commit carrying the file as it was staged:

  hook-only    staged list equals develop's  -> merge commit equals develop's
  real-drift   staging holds its own list    -> the staged (drifted) file is kept,
               so the parity gate still sees the difference

The block under test is cut out of the script itself, so the test follows the
script. Each case builds a throwaway repo whose pre-commit hook behaves like
update-eslint-warnings.
"""
import os
import subprocess
import sys
import tempfile

SCRIPT = os.path.expanduser('~/.cursor/skills/develop-staging/scripts/staging-release-merge.sh')
fails = []

HOOK = """#!/bin/sh
for f in $(git diff --cached --name-only --diff-filter=ACMR); do
  grep -v "'$f'" eslint.config.mjs > eslint.tmp && mv eslint.tmp eslint.config.mjs
done
git add eslint.config.mjs
"""

LIST = "export default [\n  'src/a.ts',\n  'src/b.ts',\n  'src/c.ts',\n  'src/d.ts'\n]\n"
DRIFTED = "export default [\n  'src/a.ts',\n  'src/b.ts',\n  'src/c.ts'\n]\n"


def block():
    """The lines from the staged-tree snapshot through the end of the restore."""
    lines = open(SCRIPT).read().split('\n')
    start = next((i for i, l in enumerate(lines) if 'STAGED_TREE="$(git' in l), None)
    said = next((i for i, l in enumerate(lines) if 'say "restored $HOOK_REWRITTEN' in l), None)
    if start is None or said is None or said < start:
        return None
    end = next(i for i in range(said, len(lines)) if lines[i] == '  fi')
    return '\n'.join(lines[start:end + 1]) + '\n'


def git(repo, *args, check=True):
    return subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True, check=check)


def build(drift):
    repo = tempfile.mkdtemp()
    git(repo, 'init', '-q', '-b', 'develop', '.')
    git(repo, 'config', 'user.email', 't@example.com')
    git(repo, 'config', 'user.name', 't')
    git(repo, 'config', 'commit.gpgsign', 'false')
    os.mkdir(os.path.join(repo, 'src'))
    for f in 'abcd':
        open(os.path.join(repo, 'src', f + '.ts'), 'w').write('v1\n')
    open(os.path.join(repo, 'eslint.config.mjs'), 'w').write(LIST)
    open(os.path.join(repo, 'other.txt'), 'w').write('base\n')
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m', 'base')
    git(repo, 'branch', 'staging')
    # develop: touches two listed files and the file that will conflict.
    for f in 'ab':
        open(os.path.join(repo, 'src', f + '.ts'), 'w').write('v2\n')
    open(os.path.join(repo, 'other.txt'), 'w').write('develop\n')
    git(repo, 'commit', '-q', '-am', 'develop work')
    git(repo, 'checkout', '-q', 'staging')
    open(os.path.join(repo, 'other.txt'), 'w').write('staging\n')
    git(repo, 'commit', '-q', '-am', 'staging hotfix')
    if drift:
        open(os.path.join(repo, 'eslint.config.mjs'), 'w').write(DRIFTED)
        git(repo, 'commit', '-q', '-am', 'staging-only list edit')
    hook = os.path.join(repo, '.git', 'hooks', 'pre-commit')
    open(hook, 'w').write(HOOK)
    os.chmod(hook, 0o755)
    git(repo, 'merge', '--no-ff', '-m', 'Merge develop into staging', 'develop', check=False)
    git(repo, 'checkout', '--theirs', '--', 'other.txt')
    git(repo, 'add', 'other.txt')
    return repo


def run_block(repo, code):
    harness = (
        'set -euo pipefail\n'
        f'WT="{repo}"; MERGE_LOG="{repo}/.git/merge.log"; : > "$MERGE_LOG"\n'
        'say() { printf ">> %s\\n" "$*"; }\n'
        'die() { printf "!! %s\\n" "$*" >&2; exit 1; }\n'
        + code)
    return subprocess.run(['bash', '-c', harness], capture_output=True, text=True)


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (': ' + detail if detail and not cond else ''))
    if not cond:
        fails.append(name)


code = block()
check('restore block found in the script', code is not None)
if code is None:
    sys.exit(1)

# hook-only: nothing but the hook separates the merge from develop.
repo = build(drift=False)
r = run_block(repo, code)
check('hook-only: block exits 0', r.returncode == 0, r.stderr)
check('hook-only: restore reported', 'restored eslint.config.mjs as staged' in r.stdout, r.stdout)
check('hook-only: merge commit carries develop\'s list',
      git(repo, 'show', 'HEAD:eslint.config.mjs').stdout == LIST)
check('hook-only: still a two-parent merge', len(git(repo, 'show', '-s', '--format=%p', 'HEAD').stdout.split()) == 2)
check('hook-only: worktree clean', git(repo, 'status', '--porcelain').stdout == '')

# real-drift: staging's own list edit auto-merges in and must survive, so the
# parity gate (a diff against develop) still reports it.
repo = build(drift=True)
r = run_block(repo, code)
check('real-drift: block exits 0', r.returncode == 0, r.stderr)
check('real-drift: merge commit carries the staged list, not the hook\'s',
      git(repo, 'show', 'HEAD:eslint.config.mjs').stdout == DRIFTED)
check('real-drift: still differs from develop',
      git(repo, 'diff', '--quiet', 'develop', 'HEAD', '--', 'eslint.config.mjs', check=False).returncode == 1)

# Control: without the block the hook's rewrite reaches the merge commit.
repo = build(drift=False)
subprocess.run(['git', '-C', repo, '-c', 'core.editor=true', 'merge', '--continue'], capture_output=True, text=True)
check('control: the fixture hook strips the list without the block',
      git(repo, 'show', 'HEAD:eslint.config.mjs').stdout != LIST)

print()
print('FAILED: ' + ', '.join(fails) if fails else 'all passed')
sys.exit(1 if fails else 0)
