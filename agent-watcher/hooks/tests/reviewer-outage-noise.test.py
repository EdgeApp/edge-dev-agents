#!/usr/bin/env python3
"""Contract test for lib/reviewer-outage-noise.sh (shared by
require-clean-run-report.sh check 7 and the Asana comment hook).

Run: python3 ~/.config/agent-watcher/hooks/tests/reviewer-outage-noise.test.py

Operator ruling 2026-09-02: a reviewer bot that did not run is one unchecked
Finalize Gate box and nothing else. The pattern must catch the shapes past runs
actually wrote and must NOT catch ordinary sentences about bots reviewing code.
"""
import os, subprocess, sys, tempfile

LIB = os.path.expanduser('~/.config/agent-watcher/hooks/lib/reviewer-outage-noise.sh')
NOISE = [
    'Reviewer bots still have not run on gui#6066. It is a draft, so Travis and the bots do not run as check-runs on it.',
    'Testing gap: Cursor Bugbot did not run on the new HEAD (dc0b8682): no check-run and no review.',
    'The bugbot credit this round was saving went unspent. Worth a re-gate when quota returns.',
    'Cursor Bugbot still has not reviewed PR 6066 at dc0b8682, unchanged since the ready-flip.',
    'Reviewer bot unavailable: cursor posted no check-run on the ready HEAD.',
    'Bugbot is out of quota, so this PR carries no automated review.',
]
CLEAN = [
    'un-draft + re-gate after edge-core-js publishes',
    'Bugbot flagged the null check on line 40 as High; fixed in the fixup.',
    'The reviewer bots completed clean on HEAD; two cursor threads resolved.',
    'Rejected review finding: the merged handleBack drops the exit path.',
    'Reviewer bots bill per push, so the round batches into one push.',
]
fails = []
def run(line):
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as fh:
        fh.write(line + '\n'); path = fh.name
    p = subprocess.run(['bash', '-c', f'. {LIB}; reviewer_noise_hits {path}'], capture_output=True, text=True)
    os.remove(path)
    return p.returncode == 0
for l in NOISE:
    ok = run(l); print(('ok   ' if ok else 'FAIL ') + 'noise: ' + l[:70]); ok or fails.append(l)
for l in CLEAN:
    ok = not run(l); print(('ok   ' if ok else 'FAIL ') + 'clean: ' + l[:70]); ok or fails.append(l)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed'); sys.exit(1 if fails else 0)
