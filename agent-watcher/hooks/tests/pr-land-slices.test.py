#!/usr/bin/env python3
"""Contract test for the /pr-land core + phase references split and its gates.

Run: python3 ~/.config/agent-watcher/hooks/tests/pr-land-slices.test.py
     PR_LAND_DIR=<dir> python3 .../pr-land-slices.test.py   # test a staged tree

Same budget as one-shot-slices.test.py: a re-attached skill body is truncated at
20,000 characters after compaction, so the core and every slice stay under it.
The pinned pre-split file (fixtures/pr-land-pre-split.SKILL.md) is the baseline
for ids only: every rule id and step id it carried must still exist exactly
once. Bodies are edited freely after the split.

Gate half: /pr-land runs in orch and by hand, so its slice entries in
require-skill-read-for-scripts.sh apply in every session. A mapped call with the
slice absent blocks and delivers the slice, in an orch payload and in a plain
session payload alike.
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

LIMIT = 20000
HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.dirname(HERE)
GATE = os.path.join(HOOKS, 'require-skill-read-for-scripts.sh')
PR_LAND = os.environ.get('PR_LAND_DIR', os.path.expanduser('~/.cursor/skills/pr-land'))
REFS = os.path.join(PR_LAND, 'references')
SCRIPTS = os.path.join(PR_LAND, 'scripts')
FIXTURE = os.path.join(HERE, 'fixtures', 'pr-land-pre-split.SKILL.md')
GID = 'prlandslicetest'
SID = 'prlandslicetest-session'

RULE_RE = re.compile(r'<rule id="([^"]+)">', re.S)
STEP_RE = re.compile(r'^<step id="([^"]+)"', re.M)
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def read(p):
    return open(p, encoding='utf-8').read()


pre = read(FIXTURE)
core = read(os.path.join(PR_LAND, 'SKILL.md'))
ref_files = sorted(f for f in os.listdir(REFS) if f.endswith('.md'))
texts = [('SKILL.md', core)] + [(f, read(os.path.join(REFS, f))) for f in ref_files]

# --- 1. sizes ----------------------------------------------------------------
for name, text in texts:
    check(len(text) < LIMIT, '%s is %d chars, must be under %d' % (name, len(text), LIMIT))

# --- 2. rule ids: every baseline id placed exactly once -----------------------
seen = {}
for name, text in texts:
    for rid in RULE_RE.findall(text):
        check(rid not in seen, 'rule %s appears in both %s and %s'
              % (rid, seen.get(rid), name))
        seen[rid] = name
for rid in RULE_RE.findall(pre):
    check(rid in seen, 'rule %s was lost in the split' % rid)

# --- 3. step ids: every baseline id in exactly one file -----------------------
for sid in STEP_RE.findall(pre):
    hits = [n for n, t in texts if re.search(r'^<step id="%s"' % re.escape(sid), t, re.M)]
    check(len(hits) == 1, 'step %s appears in %d files (%s), expected 1'
          % (sid, len(hits), ', '.join(hits) or 'none'))

# --- 4. step map and references agree ------------------------------------------
cited = set(re.findall(r'references/([a-z-]+)\.md', core))
# A subagent brief is not a phase slice: the landing session must not read it, so
# the step map must not name it. Such a file opens with "Brief for".
briefs = {f[:-3] for f, t in texts if t.startswith('Brief for')}
for f in sorted(briefs & cited):
    fails.append('references/%s.md is a subagent brief, but the core step map names it as a phase reference' % f)
for f in sorted({f[:-3] for f in ref_files} - cited - briefs):
    fails.append('references/%s.md exists but the core step map never names it' % f)
for f in sorted(cited - {f[:-3] for f in ref_files}):
    fails.append('core step map points at references/%s.md, which does not exist' % f)

# --- 5. gate map: every pr-land entry resolves, every slice is covered ---------
NEED_RE = re.compile(r"^need\s+'([^']+)'\s+(.*?)\s*$", re.M)
gate_src = read(GATE)
mapped = [(m.group(1), m.group(2).split()) for m in NEED_RE.finditer(gate_src)
          if any(u.startswith('pr-land:') for u in m.group(2).split())]
check(mapped, 'no pr-land:<slice> entries in %s' % GATE)
covered = {}
for script_re, units in mapped:
    s = re.sub(r'\\\.sh.*$', '', script_re).strip('()')
    names = s.split('|')
    for n in names:
        check(os.path.exists(os.path.join(SCRIPTS, n + '.sh')),
              'gate entry %r names %s.sh, not in %s' % (script_re, n, SCRIPTS))
    for u in units:
        covered.setdefault(u.split(':', 1)[1], names[0])
for sl in sorted(cited - set(covered)):
    fails.append('references/%s.md has no gate entry' % sl)
for sl in sorted(set(covered) - cited):
    fails.append('a gate requires pr-land:%s, which the core step map never names' % sl)


# --- 6. block delivers the slice, in orch and plain sessions -------------------
def clear_markers():
    for key in (GID, 'sess-' + SID):
        for f in glob.glob('/tmp/agent-skill-read-%s-*' % key):
            try:
                os.remove(f)
            except OSError:
                pass


def run_gate(command, orch, transcript=None):
    payload = {'tool_input': {'command': command}, 'session_id': SID}
    if transcript:
        payload['transcript_path'] = transcript
    env = {k: v for k, v in os.environ.items() if k != 'AGENT_TASK_GID'}
    if orch:
        env['AGENT_TASK_GID'] = GID
    p = subprocess.run(['bash', GATE], input=json.dumps(payload),
                       capture_output=True, text=True, env=env)
    return p.returncode, p.stderr


def core_transcript():
    """A transcript proving the core SKILL.md was Read in full."""
    lines = core.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    tf = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False)
    tf.write(json.dumps({'type': 'user', 'toolUseResult': {'file': {
        'filePath': os.path.join(PR_LAND, 'SKILL.md'),
        'content': '\n'.join(lines), 'startLine': 1, 'numLines': len(lines)}}}) + '\n')
    tf.close()
    return tf.name


transcript = core_transcript()
for orch in (True, False):
    label = 'orch' if orch else 'plain session'
    for sl, script in sorted(covered.items()):
        clear_markers()
        cmd = '~/.cursor/skills/pr-land/scripts/%s.sh --repo x' % script
        rc, err = run_gate(cmd, orch, transcript)
        check(rc == 2, '%s: %s.sh with no %s slice: rc=%d, want 2' % (label, script, sl, rc))
        body = read(os.path.join(REFS, sl + '.md')).strip()
        check(body in err, '%s: blocking %s.sh did not deliver references/%s.md'
              % (label, script, sl))
        check('/pr-land %s phase contract' % sl in err,
              '%s: block did not label the pr-land %s slice' % (label, sl))
        # The retry passes: delivery wrote the marker.
        rc, err = run_gate(cmd, orch, transcript)
        check(rc == 0, '%s: retry of %s.sh after delivery: rc=%d, want 0\n%s'
              % (label, script, rc, err[:300]))

    # Core-only scripts and the shared staging-cherry-pick need no slice.
    clear_markers()
    for cmd in ['~/.cursor/skills/pr-land/scripts/pr-land-discover.sh 4.52',
                '~/.cursor/skills/staging-cherry-pick/scripts/staging-cherry-pick.sh --dry-run']:
        _rc, err = run_gate(cmd, orch, transcript)
        check(not re.search(r'/pr-land [a-z-]+ phase contract', err),
              '%s: %s pulled in a pr-land phase slice' % (label, cmd.split('/')[-1].split()[0]))
os.unlink(transcript)
clear_markers()

# --- report ------------------------------------------------------------------
for name, text in texts:
    print('  %-24s %6d chars' % (name, len(text)))
print('rules: %d baseline, %d placed; gate slices: %s'
      % (len(RULE_RE.findall(pre)), len(seen), ', '.join(sorted(covered))))
if fails:
    print('\nFAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('\nPASS')
