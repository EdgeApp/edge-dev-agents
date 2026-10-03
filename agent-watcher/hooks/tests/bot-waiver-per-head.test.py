#!/usr/bin/env python3
"""Reviewer-bot outage waiver is scoped to the HEAD watch-pr recorded it on.

check-followup-scope.sh owns the arithmetic: a bot missing on an owned ready
HEAD counts in github_bots_incomplete unless /tmp/agent-bot-unavailable-<gid>
names that bot on that HEAD, in which case it moves to github_bots_waived.
require-followup-scope-on-complete.sh and the completion judge both read that
one count, so they cannot disagree about an outage.
"""
import json
import os
import subprocess
import sys
import tempfile

HOME = os.path.expanduser('~')
CHECK = os.path.join(HOME, '.config/agent-watcher/check-followup-scope.sh')
HOOK = os.path.join(HOME, '.config/agent-watcher/hooks/require-followup-scope-on-complete.sh')
EVIDENCE = os.path.join(HOME, '.config/agent-watcher/completion-evidence.sh')
GID = '9999999999998'
HEAD = 'c8456dc7b40f4ec92ad4ab34bf81c065495a1782'
WAIVER = f'/tmp/agent-bot-unavailable-{GID}'
MARKER = f'/tmp/agent-followup-scope-{GID}.json'

fails = 0


def check(name, ok, detail=''):
    global fails
    print(('PASS ' if ok else 'FAIL ') + name)
    if not ok:
        fails += 1
        if detail:
            print('     ' + str(detail)[:800])


GH_STUB = r'''#!/usr/bin/env bash
case "$*" in
  "api user"*) echo me ;;
  *"reviews("*) echo "${STUB_REVIEW_COUNT:-0}" ;;
  "api graphql"*) cat <<EOF
{"data":{"repository":{"pullRequest":{"state":"OPEN","isDraft":false,"headRefOid":"$STUB_HEAD","author":{"login":"me"},"reviewDecision":null,"reviewThreads":{"nodes":[]}}}}}
EOF
  ;;
  *check-runs*) echo "$STUB_CHECK_RUNS" ;;
  *) exit 1 ;;
esac
'''
CURL_STUB = r'''#!/usr/bin/env bash
URL=""
for a in "$@"; do case "$a" in https://*) URL="$a" ;; esac; done
case "$URL" in
  */users/me*) echo '{"data":{"gid":"1"}}' ;;
  */subtasks*) echo '{"data":[]}' ;;
  */attachments*) echo '{"data":[{"gid":"a1","name":"pr","created_at":"2026-10-01T00:00:00.000Z","view_url":"https://github.com/Org/repo/pull/1"}]}' ;;
  */stories*) echo '{"data":[{"gid":"s1","resource_subtype":"comment_added","created_at":"2026-09-30T00:00:00.000Z","text":"go","created_by":{"name":"Op","gid":"1"}}]}' ;;
  */tasks/*) echo '{"data":{"name":"t","completed":false,"custom_fields":[]}}' ;;
  *) echo '{"data":[]}' ;;
esac
'''

tdir = tempfile.mkdtemp(prefix='bot-waiver-')
bindir = os.path.join(tdir, 'bin')
os.makedirs(bindir)
for name, body in (('gh', GH_STUB), ('curl', CURL_STUB)):
    p = os.path.join(bindir, name)
    with open(p, 'w') as fh:
        fh.write(body)
    os.chmod(p, 0o755)

# Bugbot posted nothing, Cursor Security concluded neutral: neither counts as reviewed.
RUNS = json.dumps([{'name': 'Cursor Security Agent: Security Reviewer', 'started_at': '2026-10-02T22:24:00Z', 'state': 'neutral'},
                   {'name': 'Analyze', 'started_at': '2026-10-02T22:24:00Z', 'state': 'success'}])
ENV = dict(os.environ, PATH=bindir + os.pathsep + os.environ['PATH'], ASANA_TOKEN='fixture',
           STUB_HEAD=HEAD, STUB_CHECK_RUNS=RUNS, XDG_STATE_HOME=tdir)
ENV.pop('AGENT_TASK_GID', None)


def waiver(head):
    with open(WAIVER, 'w') as fh:
        fh.write(f'reviewer-unavailable: Cursor Bugbot(no check-run), Cursor Security(check-run skipped) '
                 f'posted no check-run/review on ready HEAD {head[:12]} at 2026-10-02T22:25:51Z (other checks complete)\n')


def scope():
    for f in (MARKER,):
        if os.path.exists(f):
            os.remove(f)
    p = subprocess.run(['bash', CHECK, '--task-gid', GID], capture_output=True, text=True, env=ENV)
    m = json.load(open(MARKER)) if os.path.exists(MARKER) else {}
    return p, m


def hook():
    env = dict(ENV, AGENT_TASK_GID=GID)
    payload = json.dumps({'tool_input': {'command': f'~/.config/agent-watcher/update-status.sh {GID} Complete'}})
    return subprocess.run(['bash', HOOK], input=payload, capture_output=True, text=True, env=env)


try:
    # 1. no waiver: both bots count, the gate blocks
    if os.path.exists(WAIVER):
        os.remove(WAIVER)
    p, m = scope()
    check('no waiver: both bots incomplete', m.get('github_bots_incomplete') == 2 and m.get('github_bots_waived') == [], p.stderr or m)
    h = hook()
    check('no waiver: Complete gate blocks', h.returncode == 2 and 'reviewer-bot' in h.stderr, h.stderr)

    # 2. waiver on THIS head: both waived, count zero, the gate passes
    waiver(HEAD)
    p, m = scope()
    check('waiver on this head: count is zero', m.get('github_bots_incomplete') == 0, p.stderr or m)
    check('waiver on this head: both bots listed as waived',
          len(m.get('github_bots_waived', [])) == 2 and all(HEAD[:12] in w for w in m['github_bots_waived']), m.get('github_bots_waived'))
    check('waiver on this head: scope output names the waiver', 'waived for their HEAD' in p.stdout, p.stdout[-600:])
    h = hook()
    check('waiver on this head: Complete gate passes', h.returncode == 0, h.stderr)

    # 3. waiver from an OLDER head: does not cover the new one
    waiver('0f6a3b4579e30ead73267a07eefa3e81067aab69')
    p, m = scope()
    check('stale-head waiver: both bots still count', m.get('github_bots_incomplete') == 2 and m.get('github_bots_waived') == [], m)
    h = hook()
    check('stale-head waiver: Complete gate blocks', h.returncode == 2, h.stderr)

    # 4. the judge's bundle carries the waived list next to the count
    waiver(HEAD)
    scope()
    out = os.path.join(tdir, 'bundle.md')
    subprocess.run(['bash', EVIDENCE, '--gid', GID, '--event', 'complete', '--offline', '--out', out],
                   capture_output=True, text=True, env=ENV)
    body = open(out).read() if os.path.exists(out) else ''
    check('evidence bundle shows zero count and the waived bots',
          'github_bots_incomplete: 0' in body and 'Cursor Bugbot on https://github.com/Org/repo/pull/1' in body,
          [l for l in body.splitlines() if 'bots' in l])
    # 5. same head, but a reviewer review sits on it: every reviewer concluded
    #    without a usable check-run, so the review covers them (no waiver needed)
    os.remove(WAIVER)
    ENV['STUB_REVIEW_COUNT'] = '1'
    p, m = scope()
    check('review on head with no usable check-run: reviewed, nothing incomplete or waived',
          m.get('github_bots_incomplete') == 0 and m.get('github_bots_waived') == [], m)
    ENV['STUB_REVIEW_COUNT'] = '0'
finally:
    for f in (WAIVER, MARKER):
        if os.path.exists(f):
            os.remove(f)

print(f'\n{fails} failure(s)')
sys.exit(1 if fails else 0)
