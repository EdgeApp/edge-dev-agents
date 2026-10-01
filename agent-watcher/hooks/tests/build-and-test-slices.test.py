#!/usr/bin/env python3
"""Contract test for the /build-and-test core + phase references split and its gates.

Run: python3 ~/.config/agent-watcher/hooks/tests/build-and-test-slices.test.py
     BUILD_AND_TEST_DIR=<dir> python3 .../build-and-test-slices.test.py   # staged tree

Same budget as pr-land-slices.test.py: a re-attached skill body is truncated at
20,000 characters after compaction, so the core and every rule-bearing slice
stay under it. The pinned pre-split file
(fixtures/build-and-test-pre-split.SKILL.md) is the baseline for rule ids only:
every id it carried must still exist exactly once. Step 0 is split across
build.md (0a-0c) and drive.md (0d-0f), so step ids are not checked for
uniqueness. sim-testing-playbook.md and throwaway-accounts.md are working
knowledge, not rule slices; the playbook has its own read gate.

Gate half, two hooks:
  require-skill-read-for-scripts.sh  build / drive+evidence on the companion
      scripts (every session), funding on a value-moving log-attempt.sh (orch).
  require-playbook-before-drive.sh   drive+evidence on a maestro drive (orch),
      alone or in the same deny as the playbook block.
"""
import glob
import json
import os
import re
import subprocess
import sys

LIMIT = 20000
HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.dirname(HERE)
GATE = os.path.join(HOOKS, 'require-skill-read-for-scripts.sh')
DRIVE_GATE = os.path.join(HOOKS, 'require-playbook-before-drive.sh')
BT = os.environ.get('BUILD_AND_TEST_DIR', os.path.expanduser('~/.cursor/skills/build-and-test'))
REFS = os.path.join(BT, 'references')
SCRIPTS = os.path.join(BT, 'scripts')
FIXTURE = os.path.join(HERE, 'fixtures', 'build-and-test-pre-split.SKILL.md')
SLICES = ['build', 'drive', 'evidence', 'funding']
GID = 'btslicetest'
SID = 'btslicetest-session'
PLAYBOOK_MARKER = '/tmp/agent-playbook-read-' + GID
NUDGE_FLAG = '/tmp/agent-coreplugins-nudge-' + GID

RULE_RE = re.compile(r'<rule id="([^"]+)">', re.S)
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def read(p):
    return open(p, encoding='utf-8').read()


pre = read(FIXTURE)
core = read(os.path.join(BT, 'SKILL.md'))
texts = [('SKILL.md', core)] + [(s + '.md', read(os.path.join(REFS, s + '.md'))) for s in SLICES]

# --- 1. sizes ----------------------------------------------------------------
for name, text in texts:
    check(len(text) < LIMIT, '%s is %d chars, must be under %d' % (name, len(text), LIMIT))

# --- 2. rule ids: every baseline id placed exactly once -----------------------
seen = {}
for name, text in texts:
    for rid in RULE_RE.findall(text):
        check(rid not in seen, 'rule %s appears in both %s and %s' % (rid, seen.get(rid), name))
        seen[rid] = name
for rid in RULE_RE.findall(pre):
    check(rid in seen, 'rule %s was lost in the split' % rid)

# --- 3. step map names every slice, and names each rule in the slice that holds it
step_map = core[core.find('<step-map'):core.find('</step-map>')]
for s in SLICES:
    check('references/%s.md' % s in step_map, 'core step map never names references/%s.md' % s)
for row in step_map.split('\n'):
    m = re.search(r'`references/([a-z-]+)\.md`', row)
    if not m or not row.startswith('|'):
        continue
    for rid in re.findall(r'`([a-z][a-zA-Z-]+)`', row.split('|')[3]):
        check(seen.get(rid) == m.group(1) + '.md',
              'step map lists %s under %s.md, found in %s' % (rid, m.group(1), seen.get(rid)))

# --- 4. gate map entries resolve to real scripts --------------------------------
NEED_RE = re.compile(r"^need\s+'([^']+)'\s+(.*?)\s*$", re.M)
mapped = [(m.group(1), m.group(2).split()) for m in NEED_RE.finditer(read(GATE))
          if any(u.startswith('build-and-test:') for u in m.group(2).split())]
check(mapped, 'no build-and-test:<slice> entries in %s' % GATE)
by_script = {}
for script_re, units in mapped:
    for n in re.sub(r'\\\.sh.*$', '', script_re).strip('()').split('|'):
        check(os.path.exists(os.path.join(SCRIPTS, n + '.sh')),
              'gate entry %r names %s.sh, not in %s' % (script_re, n, SCRIPTS))
        by_script[n] = [u.split(':', 1)[1] for u in units if u.startswith('build-and-test:')]


# --- helpers -------------------------------------------------------------------
def clear():
    for key in (GID, 'sess-' + SID):
        for f in glob.glob('/tmp/agent-skill-read-%s-*' % key):
            os.remove(f)
    for f in (PLAYBOOK_MARKER, NUDGE_FLAG):
        if os.path.exists(f):
            os.remove(f)


def mark(unit, orch=True):
    open('/tmp/agent-skill-read-%s-%s' % (GID if orch else 'sess-' + SID, unit), 'w').close()


def run(gate, payload, orch):
    payload = dict(payload, session_id=SID)
    env = {k: v for k, v in os.environ.items()
           if k not in ('AGENT_TASK_GID', 'SKILL_READ_KEY', 'AGENT_DELIVERABLE')}
    if orch:
        env['AGENT_TASK_GID'] = GID
    p = subprocess.run(['bash', gate], input=json.dumps(payload),
                       capture_output=True, text=True, env=env)
    return p.returncode, p.stderr


def bash(cmd):
    return {'tool_name': 'Bash', 'tool_input': {'command': cmd}}


def delivered(err, sl):
    return ('/build-and-test %s phase contract' % sl in err
            and read(os.path.join(REFS, sl + '.md')).strip() in err)


def premark(orch, *units):
    """Satisfy the units a call needs that this test is not about."""
    for u in ('build-and-test', 'one-shot:testing') + units:
        mark(u, orch)


# --- 5. companion scripts deliver their slices, orch and plain ------------------
for orch in (True, False):
    label = 'orch' if orch else 'plain session'
    for script, slices in sorted(by_script.items()):
        clear()
        premark(orch)
        cmd = '~/.cursor/skills/build-and-test/scripts/%s.sh' % script
        rc, err = run(GATE, bash(cmd), orch)
        check(rc == 2, '%s: %s.sh with no slice: rc=%d, want 2' % (label, script, rc))
        for sl in SLICES:
            check(delivered(err, sl) == (sl in slices),
                  '%s: %s.sh delivery of %s slice: got %s, want %s'
                  % (label, script, sl, delivered(err, sl), sl in slices))
        rc, err = run(GATE, bash(cmd), orch)
        check(rc == 0, '%s: retry of %s.sh: rc=%d, want 0\n%s' % (label, script, rc, err[:300]))
    # --help executes no step.
    clear()
    premark(orch)
    rc, _ = run(GATE, bash('~/.cursor/skills/build-and-test/scripts/ios-rn-build.sh --help'), orch)
    check(rc == 0, '%s: ios-rn-build.sh --help was gated (rc=%d)' % (label, rc))
    # A command that only mentions a script path executes nothing.
    rc, _ = run(GATE, bash('grep -n sim ~/.cursor/skills/build-and-test/scripts/select-ios-sim.sh'), orch)
    check(rc == 0, '%s: a grep of select-ios-sim.sh was gated (rc=%d)' % (label, rc))

# --- 6. funding backstop: value-moving log-attempt.sh, orch only ----------------
LA = '~/.config/agent-watcher/log-attempt.sh --gid 1 --action "x" --result success --category %s'
for cat, want in [('swap', True), ('send', True), ('sweep', True), ('"swap"', True),
                  ('test-drive', False), ('repro', False)]:
    clear()
    rc, err = run(GATE, bash(LA % cat), True)
    check((rc == 2 and delivered(err, 'funding')) == want,
          'orch: log-attempt --category %s: rc=%d funding delivered=%s, want gated=%s'
          % (cat, rc, delivered(err, 'funding'), want))
    if want:
        rc, _ = run(GATE, bash(LA % cat), True)
        check(rc == 0, 'orch: retry of log-attempt --category %s: rc=%d, want 0' % (cat, rc))
clear()
rc, err = run(GATE, bash(LA % 'swap'), False)
check(rc == 0, 'plain session: log-attempt --category swap was gated (rc=%d)' % rc)
clear()
rc, err = run(GATE, bash('echo "log-attempt.sh --category swap"'), True)
check(rc == 0, 'orch: an echo quoting log-attempt.sh was gated (rc=%d)' % rc)

# --- 7. maestro drives: drive + evidence through the playbook gate --------------
CLI = bash('maestro --device ABC --driver-host-port 9182 test /tmp/flow.yaml')
MCP = {'tool_name': 'mcp__maestro__run', 'tool_input': {'yaml': '- tapOn: x'}}
for name, payload in (('maestro CLI', CLI), ('maestro MCP', MCP)):
    # Playbook read, slices owed: deny delivers both slices, no playbook block.
    clear()
    open(PLAYBOOK_MARKER, 'w').close()
    rc, err = run(DRIVE_GATE, payload, True)
    check(rc == 2 and delivered(err, 'drive') and delivered(err, 'evidence'),
          '%s: playbook read, slices owed: rc=%d, want 2 with both slices' % (name, rc))
    check('no maestro drive before the sim-testing playbook' not in err,
          '%s: playbook block shown although the playbook marker exists' % name)
    rc, err = run(DRIVE_GATE, payload, True)
    check(rc == 0, '%s: retry after slice delivery: rc=%d, want 0\n%s' % (name, rc, err[:300]))

    # Nothing read: one deny carries the playbook block and both slices; the
    # retry then owes only the playbook.
    clear()
    rc, err = run(DRIVE_GATE, payload, True)
    check(rc == 2 and 'no maestro drive before the sim-testing playbook' in err
          and delivered(err, 'drive') and delivered(err, 'evidence'),
          '%s: nothing read: rc=%d, want 2 with playbook block and both slices' % (name, rc))
    rc, err = run(DRIVE_GATE, payload, True)
    check(rc == 2 and 'phase contract' not in err,
          '%s: second deny re-delivered slices or passed (rc=%d)' % (name, rc))
    open(PLAYBOOK_MARKER, 'w').close()
    rc, err = run(DRIVE_GATE, payload, True)
    check(rc == 0, '%s: playbook and slices satisfied: rc=%d, want 0' % (name, rc))

    # Slices read, playbook not: the playbook block alone.
    clear()
    mark('build-and-test:drive')
    mark('build-and-test:evidence')
    rc, err = run(DRIVE_GATE, payload, True)
    check(rc == 2 and 'phase contract' not in err,
          '%s: slices read, playbook owed: rc=%d, want 2 without slices' % (name, rc))

    # Plain session: the hook is orch-only.
    clear()
    rc, err = run(DRIVE_GATE, payload, False)
    check(rc == 0, '%s: plain session was gated (rc=%d)' % (name, rc))

# Non-drives pass with nothing read.
clear()
for name, payload in [
        ('maestro --version', bash('maestro --version')),
        ('ls of the maestro dir', bash('ls ~/.cursor/skills/build-and-test/maestro')),
        ('unrelated command', bash('git status')),
        ('MCP inspect_screen', {'tool_name': 'mcp__maestro__inspect_screen', 'tool_input': {}}),
        ('MCP take_screenshot', {'tool_name': 'mcp__maestro__take_screenshot', 'tool_input': {}}),
        ('MCP list_devices', {'tool_name': 'mcp__maestro__list_devices', 'tool_input': {}})]:
    rc, err = run(DRIVE_GATE, payload, True)
    check(rc == 0, '%s was gated as a drive (rc=%d)' % (name, rc))
clear()

# --- report ------------------------------------------------------------------
for name, text in texts:
    print('  %-14s %6d chars' % (name, len(text)))
print('rules: %d baseline, %d placed; script gates: %s'
      % (len(RULE_RE.findall(pre)), len(seen),
         ', '.join('%s->%s' % (k, '+'.join(v)) for k, v in sorted(by_script.items()))))
if fails:
    print('\nFAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('\nPASS')
