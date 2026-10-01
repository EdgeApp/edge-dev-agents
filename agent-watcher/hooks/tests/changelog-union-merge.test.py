#!/usr/bin/env python3
"""Contract test for pr-land/scripts/changelog-union-merge.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/changelog-union-merge.test.py
     OLD_MERGE=<path> python3 .../changelog-union-merge.test.py   # also diff vs a prior copy

Released-upstream shapes (upstream cut releases after the branch forked, so the
two sides of a hunk disagree on headings) resolve in the default mode: upstream
kept verbatim, new branch entries placed. A new branch entry under a heading
the upstream side lacks is refused. When OLD_MERGE names a prior copy of the
script, every shape the prior copy resolved must still resolve byte-identically.
"""
import os
import subprocess
import sys
import tempfile

MERGE = os.path.expanduser('~/.cursor/skills/pr-land/scripts/changelog-union-merge.sh')
OLD = os.environ.get('OLD_MERGE')
fails = []


def run(script, text, *flags):
    d = tempfile.mkdtemp()
    p = os.path.join(d, 'CHANGELOG.md')
    open(p, 'w').write(text)
    r = subprocess.run(['bash', script, d, *flags], capture_output=True, text=True)
    return r.returncode, open(p).read(), r.stderr


def doc(*ls):
    return '\n'.join(ls) + '\n'


HEAD = ['# pkg', '', '## Unreleased', '']

CASES = {
    # Branch side holds only its entry; upstream side holds new release sections.
    'released-upstream, entry only': (
        doc(*HEAD, '<<<<<<< HEAD', '## 2.1.0 (2031-02-01)', '', '- fixed: Upstream fix',
            '=======', '- fixed: Branch fix', '>>>>>>> abc (msg)', '', '## 2.0.0 (2031-01-01)', '', '- added: Old'),
        0,
        doc(*HEAD, '- fixed: Branch fix', '', '## 2.1.0 (2031-02-01)', '', '- fixed: Upstream fix',
            '', '## 2.0.0 (2031-01-01)', '', '- added: Old')),
    # The diff aligned a stale branch heading into the hunk; upstream has it below.
    'released-upstream, misaligned branch heading': (
        doc(*HEAD, '<<<<<<< HEAD', '- changed: Upstream change', '- fixed: Upstream fix', '',
            '## 2.1.0 (2031-02-01)', '', '- added: Released', '', '## 2.0.0 (2031-01-01)',
            '=======', '- added: Branch add', '', '## 1.9.0 (2030-12-01)', '>>>>>>> abc (msg)',
            '', '- added: Shared'),
        0,
        doc(*HEAD, '- added: Branch add', '- changed: Upstream change', '- fixed: Upstream fix', '',
            '## 2.1.0 (2031-02-01)', '', '- added: Released', '', '## 2.0.0 (2031-01-01)',
            '', '- added: Shared')),
    # A stale branch re-carrying a released entry adds nothing.
    'released-upstream, entry already upstream': (
        doc(*HEAD, '<<<<<<< HEAD', '## 2.1.0 (2031-02-01)', '', '- fixed: Same',
            '=======', '- fixed: Same', '>>>>>>> abc (msg)', '', '## 2.0.0 (2031-01-01)'),
        0,
        doc(*HEAD, '## 2.1.0 (2031-02-01)', '', '- fixed: Same', '', '## 2.0.0 (2031-01-01)')),
    # A new entry under a released heading upstream does not show: ambiguous.
    'refused, entry under unmatched heading': (
        doc(*HEAD, '<<<<<<< HEAD', '## 2.1.0 (2031-02-01)', '', '- fixed: Upstream',
            '=======', '## 1.9.0 (2030-12-01)', '', '- fixed: Edited release', '>>>>>>> abc (msg)'),
        1, None),
    'refused, non-entry text': (
        doc(*HEAD, '<<<<<<< HEAD', '## 2.1.0 (2031-02-01)', '', '- fixed: Upstream',
            '=======', 'Some prose the branch added', '>>>>>>> abc (msg)'),
        1, None),
}

for name, (text, want_rc, want) in CASES.items():
    rc, out, err = run(MERGE, text)
    if rc != want_rc:
        fails.append('%s: exit %d, want %d (%s)' % (name, rc, want_rc, err.strip()))
    elif want is not None and out != want:
        fails.append('%s: output differs\n--- got\n%s--- want\n%s' % (name, out, want))

# Shapes the prior script already resolved stay byte-identical.
LEGACY = {
    'no headings': (doc(*HEAD, '<<<<<<< HEAD', '- fixed: Up', '=======', '- added: Ours',
                        '>>>>>>> abc (msg)'), ()),
    'same headings': (doc(*HEAD, '<<<<<<< HEAD', '- fixed: Up', '', '## 2.0.0 (2031-01-01)', '',
                          '- added: A', '=======', '- changed: Ours', '', '## 2.0.0 (2031-01-01)', '',
                          '- added: A', '>>>>>>> abc (msg)'), ()),
    'release-merge': (doc(*HEAD, '<<<<<<< HEAD', '## 2.0.0 (staging)', '', '- fixed: S',
                          '=======', '## 2.1.0 (staging)', '', '- added: D', '', '## 2.0.0 (2031-01-01)',
                          '', '- fixed: S', '>>>>>>> abc (msg)'), ('--release-merge',)),
}
if OLD:
    for name, (text, flags) in LEGACY.items():
        old = run(OLD, text, *flags)
        new = run(MERGE, text, *flags)
        if (old[0], old[1]) != (new[0], new[1]):
            fails.append('legacy %s: new script diverges from %s' % (name, OLD))
else:
    for name, (text, flags) in LEGACY.items():
        rc, _out, err = run(MERGE, text, *flags)
        if rc != 0:
            fails.append('legacy %s: exit %d (%s)' % (name, rc, err.strip()))

if fails:
    print('FAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('PASS (%d cases%s)' % (len(CASES) + len(LEGACY), ', legacy diffed vs OLD_MERGE' if OLD else ''))
