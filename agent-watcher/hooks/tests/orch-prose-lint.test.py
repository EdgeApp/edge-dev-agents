#!/usr/bin/env python3
"""Contract test for ~/.cursor/skills/orch-prose-lint.sh (shared by the
run-report attach gate, pr-create.sh, pr-prose-edit.sh, tdd-lint.sh,
asana-task-update.sh and the Asana MCP hook).

Run: python3 ~/.config/agent-watcher/hooks/tests/orch-prose-lint.test.py

Passing-suite totals must block; failures, new cases and counts before an
unrelated noun must not. The MCP hook is exercised with its orch-context test
stubbed out, since a test process is never an in-flight run.
"""
import json, os, re, subprocess, sys, tempfile

H = os.path.expanduser
LINT = H('~/.cursor/skills/orch-prose-lint.sh')
HOOK = H('~/.config/agent-watcher/hooks/mark-agent-authored-asana.sh')
N = '731'
TOTALS = [
    f'Mocha suite: {N} passing.',
    '| jest | 1,204 passed |',
    f'Tests: {N} passed, {N} total',
    f'All {N} tests pass.',
    '2 failing, 729 ' + 'passing',
    f'{N} passing in 4s',
    f'`{N} passing`',
]
CLEAN = [
    'The 3 new cases pass.',
    'New case `retries once on a 429` covers the retry path. No failures.',
    'verify-repo.sh clean.',
    '2 failing: `sends max` (expected 0, got 1) and `parses memo`.',
    'It passed 3 args and 2 passing lanes exist.',
]
fails = []
def lint(text):
    with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as f:
        f.write(text + '\n')
    r = subprocess.run([LINT, f.name], capture_output=True, text=True)
    os.unlink(f.name)
    return r
for t in TOTALS:
    r = lint(t)
    ok = r.returncode == 1 and r.stdout.startswith('HARD 1: ')
    print(('ok   ' if ok else 'FAIL ') + 'blocks: ' + t)
    ok or fails.append(t)
for t in CLEAN:
    r = lint(t)
    ok = r.returncode == 0 and r.stdout == ''
    print(('ok   ' if ok else 'FAIL ') + 'passes: ' + t)
    ok or fails.append(t)
r = lint('```\n  ' + N + ' passing (4s)\n```')
ok = r.returncode == 1 and r.stdout.startswith('HARD 2: ')
print(('ok   ' if ok else 'FAIL ') + 'blocks a fenced suite summary')
ok or fails.append('fence')
ok = subprocess.run([LINT], capture_output=True).returncode == 2
print(('ok   ' if ok else 'FAIL ') + 'no file is a usage error (exit 2)')
ok or fails.append('usage')

# MCP hook: same lint, deny shape. Stub the orch-context early exit.
src = open(HOOK).read()
stub, n = re.subn(r'^"\$\(dirname "\$0"\)/\.\./orch-run-context\.sh" \|\| exit 0$', ':', src, flags=re.M)
assert n == 1, 'orch-context line moved; update the stub'
with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False) as f:
    f.write(stub)
def hook(text):
    p = json.dumps({'tool_name': 'mcp__claude_ai_Asana__add_comment', 'tool_input': {'task_id': '1', 'text': text}})
    return subprocess.run(['bash', f.name], input=p, capture_output=True, text=True).stdout
out = hook(TOTALS[0])
ok = '"deny"' in out and 'orch-prose-lint.sh' in out
print(('ok   ' if ok else 'FAIL ') + 'MCP hook denies a comment carrying a total')
ok or fails.append('hook-deny')
out = hook(CLEAN[1])
ok = '"deny"' not in out and '"allow"' in out
print(('ok   ' if ok else 'FAIL ') + 'MCP hook still marks and allows a clean comment')
ok or fails.append('hook-allow')
os.unlink(f.name)

print('\nall passed' if not fails else f'\n{len(fails)} FAILED')
sys.exit(1 if fails else 0)
