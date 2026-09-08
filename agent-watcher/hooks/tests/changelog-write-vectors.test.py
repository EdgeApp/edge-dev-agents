#!/usr/bin/env python3
"""Contract tests for the CHANGELOG entry-shape boundaries.

Run: python3 ~/.config/agent-watcher/hooks/tests/changelog-write-vectors.test.py

A 2026-09-07 run rewrote CHANGELOG.md through `python3 - <<'PY' ... open(p,'w')`
and every write gate missed it (the path lives inside the script body). Two
boundaries now cover it:
  1. md-write-target.sh's inline-interpreter vector, used by lint-md-on-write.sh
     and require-skill-for-file.sh: the invocation must be a real command (visible
     in the mention-stripped view); the path is then read from the raw command.
     A heredoc that merely QUOTES such a script (a test file, a report) is not a
     write.
  2. lint-commit.sh lints the STAGED CHANGELOG diff before every commit, so no
     write vector at all is the last line.
Fixture files are named data-* so this test's own writes never trip the gate.
"""
import json, os, shutil, subprocess, sys, tempfile

HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/lint-md-on-write.sh')
LIB = os.path.expanduser('~/.config/agent-watcher/hooks/lib/md-write-target.sh')
LC = os.path.expanduser('~/.cursor/skills/lint-commit.sh')
LONG = ('- added: `edge://exchange/[buy|sell|swap]` deep links (and their `https://deep.edge.app` equivalents) '
        'that open the buy, sell or swap flow with the asset(s) pre-selected, and an optional `promoId` that '
        'attributes the resulting conversion for that visit.')
SHORT = '- added: Exchange deep links with promo attribution'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def target(cmd, cwd='/repo', ext=None):
    args = f'"{ext}"' if ext else ''
    p = subprocess.run(['bash', '-c', f'. {LIB}; bash_write_target "$1" "$2" {args}', '_', cmd, cwd],
                       capture_output=True, text=True)
    return p.stdout.strip()


def hook(cmd, cwd='/Users/eddy/git/edge-react-gui'):
    p = subprocess.run([HOOK], input=json.dumps({'tool_name': 'Bash', 'cwd': cwd, 'tool_input': {'command': cmd}}),
                       capture_output=True, text=True, timeout=60)
    return p.returncode, p.stderr


def py_write(entry):
    return ("cd /Users/eddy/git/edge-react-gui && python3 - <<'PY'\n"
            "p='CHANGELOG.md'\n"
            "s=open(p).read()\n"
            "open(p,'w').write(s.replace('## Unreleased (develop)\\n', '## Unreleased (develop)\\n\\n" + entry + "\\n'))\n"
            "PY")


check('extractor: python heredoc write -> CHANGELOG.md',
      target(py_write(LONG), '/Users/eddy/git/edge-react-gui').endswith('/CHANGELOG.md'))
check('extractor: node -e writeFileSync -> docs/x.md',
      target("node -e \"require('fs').writeFileSync('docs/x.md','y')\"") == '/repo/docs/x.md')
check('extractor: python read-only open() is not a write',
      target("python3 -c \"print(open('CHANGELOG.md').read())\"") == '')
check('extractor: exact basename filter',
      target(py_write(LONG), '/r', 'CHANGELOG.md') == '/r/CHANGELOG.md' and target(py_write(LONG), '/r', 'README.md') == '')
rc, err = hook(py_write(LONG))
check("gate: the run's exact python-heredoc write is BLOCKED", rc == 2 and '253 chars' in err, f'rc={rc} {err[:120]}')
rc, err = hook(py_write(SHORT))
check('gate: same vector with a conforming entry passes', rc == 0, f'rc={rc} {err[:120]}')
quoted = "cat > /tmp/data-example.txt <<'EOF'\n" + py_write(LONG) + "\nEOF"
rc, err = hook(quoted)
check('gate: a heredoc that only QUOTES such a script is not a write', rc == 0, f'rc={rc} {err[:120]}')

tmp = tempfile.mkdtemp(prefix='cl-commit-')
try:
    env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')

    def sh(c):
        return subprocess.run(c, shell=True, cwd=tmp, capture_output=True, text=True, env=env)

    sh('git init -q -b master')
    open(os.path.join(tmp, 'data-base.txt'), 'w').write('# Changelog\n\n## Unreleased\n\n- fixed: old entry\n')
    sh('cp data-base.txt CHANGELOG.md && git add CHANGELOG.md && git commit -q -m init')
    open(os.path.join(tmp, 'data-long.txt'), 'w').write('# Changelog\n\n## Unreleased\n\n' + LONG + '\n- fixed: old entry\n')
    sh('cp data-long.txt CHANGELOG.md')
    p = sh(f'{LC} -m "Add deep links" CHANGELOG.md')
    commits = sh('git log --oneline').stdout.count('\n')
    check('lint-commit: long staged entry aborts before the commit',
          p.returncode == 1 and 'entry shape' in p.stderr and commits == 1, f'rc={p.returncode} commits={commits} {p.stderr[-200:]}')
    open(os.path.join(tmp, 'data-short.txt'), 'w').write('# Changelog\n\n## Unreleased\n\n' + SHORT + '\n- fixed: old entry\n')
    sh('cp data-short.txt CHANGELOG.md')
    p = sh(f'{LC} -m "Add deep links" CHANGELOG.md')
    commits = sh('git log --oneline').stdout.count('\n')
    check('lint-commit: conforming entry commits', p.returncode == 0 and commits == 2, f'rc={p.returncode} commits={commits} {p.stderr[-200:]}')
finally:
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
