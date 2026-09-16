#!/usr/bin/env python3
"""Contract tests for run-report re-attach, script comments, and own-story
tolerance at the Complete gate.

Run: python3 ~/.config/agent-watcher/hooks/tests/report-reattach.test.py
     (REATTACH_SRC=<dir> tests staged copies from one flat directory instead)

Covers:
  A. asana-task-update.sh replaces a same-name run report (upload, THEN delete
     older same-name copies); upload failure keeps the old one; delete failure
     warns; an older segment's report is never deleted; plans and other files
     keep their dedupe.
  B. --comment-file posts a marked comment, records its story gid for the run's
     own task, rejects outage narration, and posts before --attach-file.
  C. record-own-asana-story.sh records add_comment story gids (MCP path).
  D. require-followup-scope-on-complete.sh refreshes the marker instead of
     blocking when only the run's own comments postdate the check.
  E. require-clean-run-report.sh extracts the slug from multi-line commands,
     stores the report path, prints the exact re-attach command, and re-numbers
     an iteration stamp whose report was attached in a prior segment.
  F. mark-agent-authored-asana.sh reads stdin before its outage check.

Everything runs offline under a throwaway HOME: curl, gh and tmux are PATH
stubs (curl logs every call and answers from canned JSON), unchanged helpers
are symlinked from the real tree, and the scripts under test are copied in.
No request reaches app.asana.com.
"""
import json, os, shutil, subprocess, sys, tempfile

REAL = os.path.expanduser('~')
AW = os.path.join(REAL, '.config/agent-watcher')
SRC = os.environ.get('REATTACH_SRC')
GID = '9990000000001'
OWN = f'/tmp/agent-own-stories-{GID}'
MARKER = f'/tmp/agent-followup-scope-{GID}.json'
DOCMARK = f'/tmp/agent-report-doc-{GID}'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def src(installed_rel):
    """Path of a script under test: staged flat copy, or the installed file."""
    return os.path.join(SRC, os.path.basename(installed_rel)) if SRC else os.path.join(REAL, installed_rel)


TMP = tempfile.mkdtemp(prefix='reattach-test-')
HOME = os.path.join(TMP, 'home')
BIN = os.path.join(TMP, 'bin')
STATE = os.path.join(TMP, 'state')
LOG = os.path.join(TMP, 'curl.log')
os.makedirs(BIN)
os.makedirs(os.path.join(STATE, 'agent-watcher/versions'))

UNDER_TEST = [
    '.cursor/skills/asana-task-update/scripts/asana-task-update.sh',
    '.config/agent-watcher/hooks/require-followup-scope-on-complete.sh',
    '.config/agent-watcher/hooks/require-clean-run-report.sh',
    '.config/agent-watcher/hooks/mark-agent-authored-asana.sh',
    '.config/agent-watcher/hooks/block-raw-asana-api.sh',
    '.config/agent-watcher/hooks/record-own-asana-story.sh',
]
LINKED = [
    '.config/agent-watcher/lib/attach-names.sh',
    '.config/agent-watcher/orch-run-context.sh',
    '.config/agent-watcher/agent-authored-text.sh',
    '.config/agent-watcher/hooks/strip-cmd-mentions.sh',
    '.config/agent-watcher/hooks/lib/reviewer-outage-noise.sh',
]
for rel in UNDER_TEST:
    dst = os.path.join(HOME, rel); os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy(src(rel), dst); os.chmod(dst, 0o755)
for rel in LINKED:
    dst = os.path.join(HOME, rel); os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.symlink(os.path.join(REAL, rel), dst)

# check-followup-scope.sh stub: records that it ran and writes the marker from
# FAKE_REFRESH_MARKER.
with open(os.path.join(HOME, '.config/agent-watcher/check-followup-scope.sh'), 'w') as fh:
    fh.write('#!/bin/bash\necho ran >> "$FAKE_CHECK_LOG"\ncp "$FAKE_REFRESH_MARKER" /tmp/agent-followup-scope-$2.json\n')
os.chmod(os.path.join(HOME, '.config/agent-watcher/check-followup-scope.sh'), 0o755)

CURL = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
url = next((a for a in args if a.startswith('http')), '')
method = args[args.index('-X') + 1] if '-X' in args else 'GET'
data = args[args.index('-d') + 1] if '-d' in args else ''
form = args[args.index('-F') + 1] if '-F' in args else ''
with open(os.environ['FAKE_CURL_LOG'], 'a') as fh:
    fh.write(json.dumps({'method': method, 'url': url, 'data': data, 'form': form}) + '\n')
path = url.split('app.asana.com/api/1.0', 1)[-1].split('?')[0]
def out(o): sys.stdout.write(json.dumps(o)); sys.exit(0)
if method == 'GET' and path.endswith('/attachments'):
    out(json.load(open(os.environ['FAKE_ATTACH_JSON'])))
if method == 'POST' and path.endswith('/attachments'):
    if os.environ.get('FAKE_UPLOAD_FAIL'): sys.exit(22)
    out({'data': {'gid': 'NEW1', 'name': 'uploaded'}})
if method == 'DELETE' and '/attachments/' in path:
    if os.environ.get('FAKE_DELETE_FAIL'): sys.exit(22)
    out({'data': {}})
if method == 'POST' and path.endswith('/stories'):
    out({'data': {'gid': '5550001', 'text': json.loads(data)['data']['text']}})
if method == 'GET' and path.endswith('/stories'):
    out(json.load(open(os.environ['FAKE_STORIES_JSON'])))
sys.exit(22)
'''
for name, body in [('curl', CURL),
                   ('gh', '#!/bin/bash\nexit 0\n'),
                   ('tmux', f'#!/bin/bash\necho claude-asana-{GID}\n')]:
    p = os.path.join(BIN, name)
    open(p, 'w').write(body); os.chmod(p, 0o755)


def jfile(name, obj):
    p = os.path.join(TMP, name)
    json.dump(obj, open(p, 'w'))
    return p


def env(orch=True, **extra):
    e = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE', 'AGENT_TASK_GID')}
    e.update(HOME=HOME, PATH=BIN + ':' + os.environ['PATH'], XDG_STATE_HOME=STATE,
             ASANA_TOKEN='stub', AGENT_TASK_GID=GID, FAKE_CURL_LOG=LOG,
             FAKE_CHECK_LOG=os.path.join(TMP, 'check.log'))
    if orch:
        e.update(TMUX='/tmp/fake,1,0', TMUX_PANE='%1')
    e.update({k: str(v) for k, v in extra.items()})
    return e


def calls():
    if not os.path.exists(LOG):
        return []
    return [json.loads(l) for l in open(LOG)]


def reset():
    for p in (LOG, OWN, MARKER, DOCMARK, os.path.join(TMP, 'check.log')):
        if os.path.exists(p):
            os.remove(p)


def set_segment(ts):
    p = os.path.join(STATE, f'agent-watcher/versions/{GID}.jsonl')
    if ts is None:
        os.path.exists(p) and os.remove(p)
    else:
        open(p, 'w').write(json.dumps({'ts': '2026-09-01T00:00:00Z'}) + '\n' + json.dumps({'ts': ts}) + '\n')


UPDATE = os.path.join(HOME, '.cursor/skills/asana-task-update/scripts/asana-task-update.sh')
REPORT_FILE = os.path.join(TMP, 'agent-run-report.md')
open(REPORT_FILE, 'w').write('# report\n')


def update(args, **kw):
    return subprocess.run([UPDATE, '--task', GID] + args, capture_output=True, text=True,
                          env=env(**kw), timeout=60)


# ---------------- A. report replace ----------------
SEG = '2026-09-15T10:00:00Z'
set_segment(SEG)
att = lambda *rows: jfile('att.json', {'data': [{'gid': g, 'name': n, 'created_at': c} for g, n, c in rows]})

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', '3-agent-run-report.md'],
           FAKE_ATTACH_JSON=att(('OLD1', '3-agent-run-report.md', '2026-09-15T11:00:00.123Z'),
                                ('P1', '2-agent-run-report.md', '2026-09-14T11:00:00.000Z')))
c = calls(); methods = [(x['method'], x['url'].rsplit('/', 1)[-1]) for x in c]
check('A1 in-segment same-name report is replaced', p.returncode == 0 and 'replaced OLD1->NEW1' in p.stdout, p.stdout + p.stderr)
check('A1 upload precedes delete', ('POST', 'attachments') in methods and ('DELETE', 'OLD1') in methods
      and methods.index(('POST', 'attachments')) < methods.index(('DELETE', 'OLD1')), methods)
check('A1 other reports untouched', ('DELETE', 'P1') not in methods, methods)

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', '3-agent-run-report.md'], FAKE_UPLOAD_FAIL=1,
           FAKE_ATTACH_JSON=att(('OLD1', '3-agent-run-report.md', '2026-09-15T11:00:00.123Z')))
check('A2 upload failure exits 1 and keeps the old report',
      p.returncode == 1 and not any(x['method'] == 'DELETE' for x in calls()) and 'still attached' in p.stderr, p.stdout + p.stderr)

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', '3-agent-run-report.md'], FAKE_DELETE_FAIL=1,
           FAKE_ATTACH_JSON=att(('OLD1', '3-agent-run-report.md', '2026-09-15T11:00:00.123Z')))
check('A3 delete failure warns and exits 0', p.returncode == 0 and 'WARN' in p.stderr and 'OLD1' in p.stderr, p.stdout + p.stderr)

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', '3-agent-run-report.md'],
           FAKE_ATTACH_JSON=att(('OLD1', '3-agent-run-report.md', '2026-09-15T09:59:59.999Z')))
check('A4 older-segment report is not replaced and says why',
      p.returncode == 0 and not any(x['method'] in ('POST', 'DELETE') for x in calls()) and 'before this segment started' in p.stdout,
      p.stdout + p.stderr)

reset(); set_segment(None)
p = update(['--attach-file', REPORT_FILE, '--attach-name', '3-agent-run-report.md'],
           FAKE_ATTACH_JSON=att(('OLD1', '3-agent-run-report.md', '2026-09-15T11:00:00.000Z')))
check('A5 no segment stamp: no replace, says why',
      p.returncode == 0 and not any(x['method'] in ('POST', 'DELETE') for x in calls()) and 'no segment start' in p.stdout, p.stdout + p.stderr)
set_segment(SEG)

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', 'plan-foo.md'],
           FAKE_ATTACH_JSON=att(('PL1', '1-plan-foo.md', '2026-09-15T11:00:00.000Z')))
check('A6 plan keeps suffix dedupe', p.returncode == 0 and 'dedupe' in p.stdout and not any(x['method'] in ('POST', 'DELETE') for x in calls()), p.stdout + p.stderr)

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', 'shot.md'],
           FAKE_ATTACH_JSON=att(('S1', 'shot.md', '2026-09-15T11:00:00.000Z')))
check('A7 other file keeps exact-name dedupe', p.returncode == 0 and 'dedupe' in p.stdout and not any(x['method'] in ('POST', 'DELETE') for x in calls()), p.stdout + p.stderr)

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', '4-agent-run-report.md'],
           FAKE_ATTACH_JSON=att(('OLD1', '3-agent-run-report.md', '2026-09-15T11:00:00.000Z')))
check('A8 new report name uploads without deleting',
      p.returncode == 0 and any(x['method'] == 'POST' for x in calls()) and not any(x['method'] == 'DELETE' for x in calls()), p.stdout + p.stderr)

reset()
p = update(['--attach-file', REPORT_FILE, '--attach-name', '3-agent-run-report.md'],
           FAKE_ATTACH_JSON=att(('D1', '3-agent-run-report.md', '2026-09-15T11:00:00.000Z'),
                                ('D2', '3-agent-run-report.md', '2026-09-15T12:00:00.000Z')))
check('A9 duplicate in-segment copies are all deleted', p.returncode == 0 and 'replaced D1,D2->NEW1' in p.stdout, p.stdout + p.stderr)

# ---------------- B. --comment-file ----------------
CM = os.path.join(TMP, 'comment.md')
open(CM, 'w').write('- testing gap: send not driven\n')

reset()
p = update(['--comment-file', CM])
posts = [x for x in calls() if x['method'] == 'POST' and x['url'].endswith('/stories')]
text = json.loads(posts[0]['data'])['data']['text'] if posts else ''
check('B1 comment posted and marked', p.returncode == 0 and text.startswith('🥋') and text.rstrip().endswith('👊'), p.stdout + p.stderr + text)
check('B1 story gid recorded for own task', os.path.exists(OWN) and open(OWN).read().split() == ['5550001'])

reset()
p = update(['--comment-file', CM], orch=False)
posts = [x for x in calls() if x['method'] == 'POST' and x['url'].endswith('/stories')]
text = json.loads(posts[0]['data'])['data']['text'] if posts else ''
check('B2 operator context: posted unmarked, not recorded', p.returncode == 0 and posts and not text.startswith('🥋') and not os.path.exists(OWN), p.stdout + p.stderr)

reset()
NOISY = os.path.join(TMP, 'noisy.md')
open(NOISY, 'w').write('- Bugbot is out of quota, so this PR carries no automated review.\n')
p = update(['--comment-file', NOISY])
check('B3 outage narration rejected before posting',
      p.returncode == 1 and not any(x['method'] == 'POST' for x in calls()) and 'REJECTED' in p.stderr, p.stdout + p.stderr)

reset()
p = update(['--comment-file', CM, '--attach-file', REPORT_FILE, '--attach-name', '5-agent-run-report.md'],
           FAKE_ATTACH_JSON=att())
order = [x['url'].rsplit('/', 1)[-1].split('?')[0] for x in calls() if x['method'] == 'POST']
check('B4 comment posts before the attachment', order == ['stories', 'attachments'], order)

reset()
p = update(['--comment-file', os.path.join(TMP, 'missing.md')])
check('B5 missing comment file exits 1', p.returncode == 1 and not calls(), p.stderr)

p = subprocess.run([os.path.join(HOME, '.config/agent-watcher/hooks/block-raw-asana-api.sh')],
                   input=json.dumps({'tool_input': {'command': 'curl -X POST https://app.asana.com/api/1.0/tasks/1/stories -d x'}}),
                   capture_output=True, text=True, env=env(), timeout=30)
check('B6 raw-API block points at --comment-file', p.returncode == 2 and '--comment-file' in p.stderr, p.stderr)

# ---------------- C. MCP own-story hook ----------------
REC = os.path.join(HOME, '.config/agent-watcher/hooks/record-own-asana-story.sh')
payload = json.dumps({'data': {'gid': '777', 'text': 'x'}})
for label, resp in [('object', {'data': {'gid': '777'}}), ('string', payload),
                    ('content blocks', [{'type': 'text', 'text': payload}])]:
    reset()
    subprocess.run([REC], input=json.dumps({'tool_name': 'mcp__claude_ai_Asana__add_comment',
                                           'tool_input': {'task_id': GID, 'text': 'x'}, 'tool_response': resp}),
                   capture_output=True, text=True, env=env(), timeout=30)
    check(f'C1 records story gid ({label} response)', os.path.exists(OWN) and open(OWN).read().split() == ['777'])

reset()
subprocess.run([REC], input=json.dumps({'tool_name': 'mcp__claude_ai_Asana__add_comment',
                                       'tool_input': {'task_id': '123', 'text': 'x'}, 'tool_response': {'data': {'gid': '777'}}}),
               capture_output=True, text=True, env=env(), timeout=30)
check('C2 comment on another task is not recorded', not os.path.exists(OWN))
reset()
subprocess.run([REC], input=json.dumps({'tool_name': 'mcp__claude_ai_Asana__add_comment',
                                       'tool_input': {'task_id': GID, 'text': 'x'}, 'tool_response': {'data': {'gid': '777'}}}),
               capture_output=True, text=True, env=env(orch=False), timeout=30)
check('C3 operator-context session is not recorded', not os.path.exists(OWN))

# ---------------- D. Complete gate own-story tolerance ----------------
GATE = os.path.join(HOME, '.config/agent-watcher/hooks/require-followup-scope-on-complete.sh')
COMPLETE = json.dumps({'tool_input': {'command': f'~/.config/agent-watcher/update-status.sh {GID} Complete'}})
base_marker = {'newest_comment_at': '2026-09-15T10:00:00.000Z', 'agent_comments_after_watermark': 0,
               'github_blocking_threads': 0, 'github_unanswered_bodies': 0, 'github_bots_incomplete': 0}
stories = lambda *rows: jfile('stories.json', {'data': [{'gid': g, 'created_at': c, 'resource_subtype': 'comment_added'} for g, c in rows]})
CHECKLOG = os.path.join(TMP, 'check.log')


def gate(refresh=None, **kw):
    rm = jfile('refresh.json', refresh or dict(base_marker, newest_comment_at='2026-09-15T11:00:00.000Z'))
    return subprocess.run([GATE], input=COMPLETE, capture_output=True, text=True,
                          env=env(FAKE_REFRESH_MARKER=rm, **kw), timeout=60)


reset(); json.dump(base_marker, open(MARKER, 'w')); open(OWN, 'w').write('S2\n')
p = gate(FAKE_STORIES_JSON=stories(('S1', '2026-09-15T10:00:00.000Z'), ('S2', '2026-09-15T11:00:00.000Z')))
check('D1 only own comments newer: marker refreshed, allowed', p.returncode == 0 and os.path.exists(CHECKLOG), p.stderr)

reset(); json.dump(base_marker, open(MARKER, 'w')); open(OWN, 'w').write('S2\n')
p = gate(FAKE_STORIES_JSON=stories(('S2', '2026-09-15T11:00:00.000Z'), ('S3', '2026-09-15T11:30:00.000Z')))
check('D2 a foreign newer comment still blocks', p.returncode == 2 and 'stale' in p.stderr and not os.path.exists(CHECKLOG), p.stderr)
check('D2 block says to run the check on its own', 'OWN Bash command' in p.stderr, p.stderr)

reset(); json.dump(base_marker, open(MARKER, 'w'))
p = gate(FAKE_STORIES_JSON=stories(('S2', '2026-09-15T11:00:00.000Z')))
check('D3 no own-stories file keeps the plain block', p.returncode == 2 and not os.path.exists(CHECKLOG), p.stderr)

reset(); json.dump(base_marker, open(MARKER, 'w')); open(OWN, 'w').write('S2\n')
p = gate(FAKE_STORIES_JSON=stories(('S1', '2026-09-15T10:00:00.000Z')))
check('D4 fresh marker passes without a refresh', p.returncode == 0 and not os.path.exists(CHECKLOG), p.stderr)

reset(); json.dump(base_marker, open(MARKER, 'w')); open(OWN, 'w').write('S2\n')
p = gate(refresh=dict(base_marker, newest_comment_at='2026-09-15T11:00:00.000Z', agent_comments_after_watermark=1),
         FAKE_STORIES_JSON=stories(('S2', '2026-09-15T11:00:00.000Z')))
check('D5 refreshed marker still enforces watermark ordering', p.returncode == 2 and 'Re-attach the report' in p.stderr, p.stderr)

reset()
p = gate(FAKE_STORIES_JSON=stories())
check('D6 missing marker block says to run the check on its own', p.returncode == 2 and 'OWN Bash command' in p.stderr, p.stderr)

# ---------------- E. report gate slug + doc marker ----------------
RGATE = os.path.join(HOME, '.config/agent-watcher/hooks/require-clean-run-report.sh')
UPD = '~/.cursor/skills/asana-task-update/scripts/asana-task-update.sh'


def report(path, iteration=None):
    fm = f'iteration: "{iteration}"\n' if iteration else ''
    open(path, 'w').write(f'---\n{fm}outcome: complete\n---\n\n# Run report {iteration or 1}: x\n\n_iteration stamp_\n\n## Summary\n\nDone.\n')


def rgate(cmd, sess='sess-1', **kw):
    return subprocess.run([RGATE], input=json.dumps({'session_id': sess, 'tool_input': {'command': cmd}}),
                          capture_output=True, text=True, env=env(FAKE_ATTACH_JSON=att(), **kw), timeout=60)


R1 = os.path.join(TMP, f'agent-run-report-{GID}-alpha.md')
report(R1, iteration=3)
reset()
multi = f'cd /tmp\n{UPD} \\\n  --task {GID} \\\n  --attach-file {R1} \\\n  --attach-name agent-run-report.md\necho done'
p = rgate(multi)
mark = open(DOCMARK).read().strip() if os.path.exists(DOCMARK) else ''
check('E1 multi-line attach: slug from the path, marker stores session|slug|path', p.returncode == 0 and mark == f'sess-1|alpha|{R1}', repr(mark) + p.stderr)
out = json.loads(p.stdout) if p.stdout.strip() else {}
newcmd = out.get('hookSpecificOutput', {}).get('updatedInput', {}).get('command', '')
check('E1 multi-line attach name normalized, other lines kept',
      '--attach-name 3-agent-run-report.md' in newcmd and newcmd.startswith('cd /tmp\n') and newcmd.endswith('echo done'), repr(newcmd))

R2 = os.path.join(TMP, f'agent-run-report-{GID}-beta.md')
report(R2, iteration=3)
p = rgate(f'{UPD} --task {GID} --attach-file {R2} --attach-name agent-run-report.md')
want = f'{UPD} --task {GID} --attach-file {R1} --attach-name agent-run-report.md'
check('E2 second doc blocked with the exact re-attach command', p.returncode == 2 and want in p.stderr and 'REPLACES' in p.stderr, p.stderr)

p = rgate(f'{UPD} --task {GID} --attach-file {R1} --attach-name agent-run-report.md')
check('E3 re-attaching the same doc passes', p.returncode == 0, p.stderr)

p = rgate(f'{UPD} --task {GID} --attach-file {R2} --attach-name agent-run-report.md', sess='sess-2')
check('E4 new session (followup segment) passes', p.returncode == 0, p.stderr)

reset(); open(DOCMARK, 'w').write('sess-1 alpha\n')
p = rgate(f'{UPD} --task {GID} --attach-file {R2} --attach-name agent-run-report.md')
check('E5 legacy marker still blocks a second doc', p.returncode == 2 and 'second doc' in p.stderr, p.stderr)

# Stale iteration: a stamp whose N report predates this segment is re-numbered.
def rgate_att(cmd, attach_json, sess):
    return subprocess.run([RGATE], input=json.dumps({'session_id': sess, 'tool_input': {'command': cmd}}),
                          capture_output=True, text=True, env=env(FAKE_ATTACH_JSON=attach_json), timeout=60)


def new_name(p):
    o = json.loads(p.stdout) if p.stdout.strip() else {}
    c = o.get('hookSpecificOutput', {}).get('updatedInput', {}).get('command', '')
    return c.split('--attach-name ', 1)[1].split()[0] if '--attach-name ' in c else ''


R3 = os.path.join(TMP, f'agent-run-report-{GID}-gamma.md')
reset(); report(R3, iteration=3)
prior = att(('P3', '3-agent-run-report.md', '2026-09-14T09:00:00.000Z'))
p = rgate_att(f'{UPD} --task {GID} --attach-file {R3} --attach-name agent-run-report.md', prior, 'sess-stale')
fm = open(R3).read()
check('E6 stale iteration from a prior segment gets a new N',
      new_name(p) == '4-agent-run-report.md' and 'iteration: "4"' in fm and '# Run report 4:' in fm and 'stale' in p.stderr,
      new_name(p) + ' | ' + p.stderr[-300:])
reset()
p = update(['--attach-file', R3, '--attach-name', '4-agent-run-report.md'], FAKE_ATTACH_JSON=prior)
check('E6 re-numbered report uploads without deleting the prior one',
      p.returncode == 0 and any(x['method'] == 'POST' for x in calls()) and not any(x['method'] == 'DELETE' for x in calls()), p.stdout + p.stderr)

R4 = os.path.join(TMP, f'agent-run-report-{GID}-delta.md')
reset(); report(R4, iteration=3)
same = att(('S3', '3-agent-run-report.md', '2026-09-15T10:30:00.000Z'))
p = rgate_att(f'{UPD} --task {GID} --attach-file {R4} --attach-name agent-run-report.md', same, 'sess-same')
check('E7 same-segment iteration keeps N',
      new_name(p) == '3-agent-run-report.md' and 'iteration: "3"' in open(R4).read() and 'stale' not in p.stderr, new_name(p) + ' | ' + p.stderr[-300:])
reset()
p = update(['--attach-file', R4, '--attach-name', '3-agent-run-report.md'], FAKE_ATTACH_JSON=same)
check('E7 same-segment re-attach replaces', p.returncode == 0 and 'replaced S3->NEW1' in p.stdout, p.stdout + p.stderr)

# ---------------- F. MCP marking hook reads stdin first ----------------
MARK = os.path.join(HOME, '.config/agent-watcher/hooks/mark-agent-authored-asana.sh')


def mark_hook(tool, tin):
    return subprocess.run([MARK], input=json.dumps({'tool_name': tool, 'tool_input': tin}),
                          capture_output=True, text=True, env=env(), timeout=30)


p = mark_hook('mcp__claude_ai_Asana__add_comment', {'task_id': GID, 'text': 'Bugbot is out of quota, so this PR carries no automated review.'})
check('F1 outage narration on add_comment is denied', '"deny"' in p.stdout, p.stdout + p.stderr)
p = mark_hook('mcp__claude_ai_Asana__add_comment', {'task_id': GID, 'text': 'testing gap: send not driven'})
ui = json.loads(p.stdout).get('hookSpecificOutput', {}).get('updatedInput', {}) if p.stdout.strip() else {}
check('F2 clean comment is marked', ui.get('text', '').startswith('🥋'), p.stdout + p.stderr)
p = mark_hook('mcp__claude_ai_Asana__search_tasks', {'text': 'bugbot out of quota'})
check('F3 read tools pass untouched', p.returncode == 0 and not p.stdout.strip(), p.stdout + p.stderr)

reset()
shutil.rmtree(TMP, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
