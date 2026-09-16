#!/usr/bin/env python3
"""Contract test for the /one-shot phase-slice gates.

Run: python3 ~/.config/agent-watcher/hooks/tests/one-shot-slice-gates.test.py

one-shot-slices.test.py proves the SPLIT is faithful (every rule survived, the
core fits the re-attach budget). This file proves the split is still ENFORCED:
after the split only the core is in context by default, so each phase's rules
reach a segment through require-skill-read-for-scripts.sh, which requires the
owning reference slice at that phase's first companion-script call the same way
it requires a SKILL.md.

Checks:
  1. every script named in the gate map resolves to a file on disk
  2. every reference file the core step map names has a gate-map entry
  3. a mapped call with the slice absent blocks, and the block body carries the
     slice text (slices are small, so they take the deliver-in-full branch)
  4. the same call passes when a transcript proves the slice is in context
  5. an unmapped script requires nothing
  6. the followup slice is injected at session start only when the task already
     carries a run-report attachment
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HOOKS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE = os.path.join(HOOKS, 'require-skill-read-for-scripts.sh')
SLACK_GATE = os.path.join(HOOKS, 'slack-prose-gate.sh')
INJECT = os.path.join(HOOKS, 'inject-run-context.sh')
ONE_SHOT = os.path.expanduser('~/.cursor/skills/one-shot')
REFS = os.path.join(ONE_SHOT, 'references')
SEARCH_ROOTS = [os.path.expanduser('~/.cursor/skills'),
                os.path.expanduser('~/.config/agent-watcher')]
GID = 'slicegatetest'

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def read(p):
    return open(p, encoding='utf-8').read()


def run_gate(command, transcript=None, gid=GID):
    """Pipe one synthetic Bash PreToolUse payload through the gate."""
    payload = {'tool_input': {'command': command}}
    if transcript:
        payload['transcript_path'] = transcript
    env = dict(os.environ, AGENT_TASK_GID=gid)
    p = subprocess.run(['bash', GATE], input=json.dumps(payload),
                       capture_output=True, text=True, env=env)
    return p.returncode, p.stderr


def clear_markers(gid=GID):
    import glob
    for f in glob.glob('/tmp/agent-skill-read-%s-*' % gid):
        try:
            os.remove(f)
        except OSError:
            pass


# --- parse the gate map out of the hook ---------------------------------------
gate_src = read(GATE)
NEED_RE = re.compile(r"^need\s+'([^']+)'\s+(.*?)\s*$", re.M)
mapped = []          # (script-regex, [units])
for m in NEED_RE.finditer(gate_src):
    units = [u for u in m.group(2).split() if not u.startswith('#')]
    mapped.append((m.group(1), units))
check(mapped, 'no `need` entries parsed out of %s' % GATE)

# Units required outside the `need` table: argument-sensitive entries here, the
# Slack send path, and the session-start followup injection.
extra_units = set(re.findall(r'one-shot:[a-z]+', gate_src))
extra_units |= set(re.findall(r'one-shot:[a-z]+', read(SLACK_GATE)))
extra_units |= set(re.findall(r'one-shot:[a-z]+', read(INJECT)))

# --- 1. every mapped script exists --------------------------------------------
def globs_for(script_re):
    """Filename glob(s) the script regex can match."""
    s = re.sub(r'\(\[\[:space:\]\]\|\$\)$', '', script_re)
    s = s.replace('\\.', '.').replace('[a-z-]+', '*')
    alt = re.match(r'^\((.+?)\)(.*)$', s)
    if alt:
        return [a + alt.group(2) for a in alt.group(1).split('|')]
    return [s]


def resolve(glob_pat):
    import fnmatch
    for root in SEARCH_ROOTS:
        for dirpath, _dirs, files in os.walk(root):
            if '/node_modules' in dirpath or '/retired' in dirpath:
                continue
            for f in files:
                if fnmatch.fnmatch(f, glob_pat):
                    return os.path.join(dirpath, f)
    return None


for script_re, units in mapped:
    for g in globs_for(script_re):
        check(resolve(g) is not None,
              'gate map entry %r names %r, which resolves to no file on disk'
              % (script_re, g))

# --- 2. every reference the core step map names has a gate-map entry ----------
core = read(os.path.join(ONE_SHOT, 'SKILL.md'))
cited = set(re.findall(r'references/([a-z]+)\.md', core))
check(cited, 'the core step map names no reference files')
covered = {u.split(':', 1)[1] for _re, units in mapped for u in units
           if u.startswith('one-shot:')}
covered |= {u.split(':', 1)[1] for u in extra_units}
for slice_name in sorted(cited - covered):
    fails.append('references/%s.md is in the core step map but no gate requires it'
                 % slice_name)
for slice_name in sorted(covered - cited):
    fails.append('a gate requires one-shot:%s, which the core step map never names'
                 % slice_name)

# --- 3. absent slice blocks, and the block delivers the slice body ------------
clear_markers()
rc, err = run_gate('~/.config/agent-watcher/set-tested.sh 123 "iOS Sim"')
check(rc == 2, 'set-tested.sh with no testing slice in context: rc=%d, want 2' % rc)
testing_body = read(os.path.join(REFS, 'testing.md')).strip()
check(testing_body and testing_body in err,
      'the block body does not carry references/testing.md verbatim '
      '(delivered %d bytes)' % len(err))
check('one-shot testing phase contract' in err,
      'the block body does not label the slice it delivered')
check(os.path.exists('/tmp/agent-skill-read-%s-one-shot:testing' % GID),
      'delivering the slice did not write its read marker')

# --- 4. slice proven in the transcript passes --------------------------------
clear_markers()
lines = read(os.path.join(REFS, 'testing.md')).split('\n')
if lines and lines[-1] == '':
    lines.pop()
with tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False) as tf:
    tf.write(json.dumps({'type': 'user', 'toolUseResult': {'file': {
        'filePath': os.path.join(REFS, 'testing.md'),
        'content': '\n'.join(lines), 'startLine': 1, 'numLines': len(lines)}}}) + '\n')
    transcript = tf.name
rc, err = run_gate('~/.config/agent-watcher/set-tested.sh 123 "iOS Sim"',
                   transcript=transcript)
check(rc == 0, 'set-tested.sh with the slice proven in the transcript: rc=%d, want 0'
      % rc)
# A partial read must still block: the gate delivers whole contracts only.
with open(transcript, 'w') as fh:
    fh.write(json.dumps({'type': 'user', 'toolUseResult': {'file': {
        'filePath': os.path.join(REFS, 'testing.md'),
        'content': '\n'.join(lines[:3]), 'startLine': 1, 'numLines': 3}}}) + '\n')
clear_markers()
rc, _err = run_gate('~/.config/agent-watcher/set-tested.sh 123 "iOS Sim"',
                    transcript=transcript)
check(rc == 2, 'a partial read of the slice was credited (rc=%d, want 2)' % rc)
os.unlink(transcript)

# --- 5. an unmapped script requires nothing ----------------------------------
clear_markers()
for cmd in ['~/.config/agent-watcher/log-attempt.sh --gid 1 --note x',
            '~/.config/agent-watcher/update-status.sh 123 Planning',
            '~/.cursor/skills/build-and-test/scripts/select-ios-sim.sh']:
    rc, err = run_gate(cmd)
    if 'select-ios-sim' in cmd:
        # owned by build-and-test, but not a drive: no one-shot phase slice
        check(not re.search(r'^===== /one-shot \w+ phase contract', err, re.M),
              'select-ios-sim.sh pulled in a one-shot phase slice')
    else:
        check(rc == 0, 'unmapped %r blocked (rc=%d)' % (cmd.split('/')[-1], rc))

# --- 6. followup injection fires only with a prior run report -----------------
def inject_with(attachments):
    """Run inject-run-context.sh with a stub curl serving canned Asana JSON."""
    d = tempfile.mkdtemp()
    atts = os.path.join(d, 'attachments.json')
    with open(atts, 'w') as fh:
        json.dump(attachments, fh)
    stub = os.path.join(d, 'curl')
    with open(stub, 'w') as fh:
        fh.write('#!/usr/bin/env bash\n'
                 'for a in "$@"; do case "$a" in https://*) URL="$a";; esac; done\n'
                 'case "$URL" in\n'
                 '  *attachments*created_at*) cat "%s" ;;\n'
                 '  *attachments*) echo \'{"data":[]}\' ;;\n'
                 '  *stories*) echo \'{"data":[]}\' ;;\n'
                 '  *users/me*) echo \'{"data":{"gid":"1"}}\' ;;\n'
                 '  *) echo \'{"data":{"name":"t","custom_fields":[]}}\' ;;\n'
                 'esac\n' % atts)
    os.chmod(stub, 0o755)
    env = dict(os.environ, AGENT_TASK_GID=GID,
               PATH=d + os.pathsep + os.environ['PATH'])
    p = subprocess.run(['bash', INJECT], input='{"source":"startup"}',
                       capture_output=True, text=True, env=env)
    return p.stdout


followup_body = read(os.path.join(REFS, 'followup.md')).strip()
MARKER = '/tmp/agent-skill-read-%s-one-shot:followup' % GID

clear_markers()
out = inject_with({'data': []})
check(followup_body not in out,
      'the followup slice was injected on a task with no run report')
check(not os.path.exists(MARKER),
      'the followup read marker was written with no run report')

clear_markers()
out = inject_with({'data': [{'name': '1-agent-run-report.md',
                             'created_at': '2026-09-01T00:00:00.000Z'}]})
check(followup_body in out,
      'the followup slice was NOT injected on a task that already has a run report')
check(os.path.exists(MARKER),
      'the followup injection did not pre-write its read marker')
clear_markers()

# --- report -------------------------------------------------------------------
print('gate map: %d script entries, slices covered: %s'
      % (len(mapped), ', '.join(sorted(covered))))
if fails:
    print('\nFAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('\nPASS')
