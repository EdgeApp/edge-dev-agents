#!/usr/bin/env python3
"""Contract tests for asana-task-update.sh --assign and pr-create.sh --asana-attach.

Run: python3 ~/.config/agent-watcher/hooks/tests/asana-flags.test.py
     (ASANA_FLAGS_SRC=<dir> tests staged flat copies of asana-task-update.sh and
     pr-create.sh from one directory instead of the installed files)

Covers:
  A. asana-task-update.sh --assign <gid>
     A1 sets the assignee only when the task's projects carry neither legacy
        Reviewer nor Implementor field (no custom_fields in the PUT, no prompt).
     A2 mirrors into both fields when a project carries them, resolving the
        implementor via asana-whoami.sh with a token read from credentials.json.
     A3 a refused PUT exits 1 and prints the HTTP status and Asana's message.
     A4 a refused task read exits 1 with the HTTP status.
     A5 a transport failure exits 1 and names curl's exit code.
     A6 missing reviewer: --skip-assign-if-missing skips (0); otherwise exit 2
        with PROMPT_REVIEWER.
     A7 an explicit --set-reviewer is still sent even off-project.
  B. pr-create.sh --asana-attach
     B1 `--asana-task <gid> --asana-attach` (one-shot references/pr.md, step 5) attaches and
        reports asana_attached true; B2 the reverse flag order does too.
     B3 --asana-attach without --asana-task exits 2 before `gh pr create`.
     B4 no --asana-attach: asana_attached null and no attach call.
     B5 a failed attach reports asana_attached false with a WARN.

Offline under a throwaway HOME: curl and gh are PATH stubs. The curl stub
reproduces the system curl's HTTP/2 behavior (`-f` plus an HTTP 4xx exits 56
with no body). No request reaches app.asana.com or github.com.
"""
import json, os, shutil, subprocess, sys, tempfile

REAL = os.path.expanduser('~')
SRC = os.environ.get('ASANA_FLAGS_SRC')
GID = '9990000000002'
PROJ = '8880000000001'
REVIEWER = '1203334388004673'
IMPLEMENTOR = '1203334386796983'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def src(installed_rel):
    return os.path.join(SRC, os.path.basename(installed_rel)) if SRC else os.path.join(REAL, installed_rel)


TMP = tempfile.mkdtemp(prefix='asana-flags-test-')
HOME = os.path.join(TMP, 'home')
BIN = os.path.join(TMP, 'bin')
LOG = os.path.join(TMP, 'curl.log')
os.makedirs(BIN)


def install(rel, body=None, from_path=None):
    dst = os.path.join(HOME, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if from_path:
        shutil.copy(from_path, dst)
    else:
        open(dst, 'w').write(body)
    os.chmod(dst, 0o755)
    return dst


UPDATE = install('.cursor/skills/asana-task-update/scripts/asana-task-update.sh',
                 from_path=src('.cursor/skills/asana-task-update/scripts/asana-task-update.sh'))
install('.cursor/skills/asana-whoami.sh', '#!/bin/bash\n[[ -n "${ASANA_TOKEN:-}" ]] || exit 1\necho 1111\n')

CURL = r'''#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
def opt(flag):
    return args[args.index(flag) + 1] if flag in args else ''
url = next((a for a in args if a.startswith('http')), '')
method = opt('-X') or 'GET'
data = opt('-d')
with open(os.environ['FAKE_CURL_LOG'], 'a') as fh:
    fh.write(json.dumps({'method': method, 'url': url, 'data': data}) + '\n')
path = url.split('/api/1.0', 1)[-1].split('?')[0]
routes = json.load(open(os.environ['FAKE_ROUTES']))
hit = next((r for r in routes if r['method'] == method and re.fullmatch(r['path'], path)), None)
code, body, xit = (hit['code'], json.dumps(hit['body']), hit.get('exit', 0)) if hit else (404, '{"errors":[{"message":"no route"}]}', 0)
if xit:
    sys.stderr.write('curl: (%d) stub transport failure\n' % xit)
    if '-w' in args: sys.stdout.write('000')
    sys.exit(xit)
if any(re.fullmatch(r'-[a-zA-Z]*f[a-zA-Z]*', a) for a in args) and code >= 400:
    sys.exit(56)
if '-o' in args:
    open(opt('-o'), 'w').write(body)
else:
    sys.stdout.write(body)
if '-w' in args:
    sys.stdout.write(str(code))
'''
for name, body in [('curl', CURL)]:
    p = os.path.join(BIN, name)
    open(p, 'w').write(body); os.chmod(p, 0o755)


def routes(put_code=200, put_body=None, task_code=200, project_fields=(), put_exit=0):
    task = {'data': {'gid': GID, 'name': 't', 'memberships': [{'project': {'gid': PROJ}}],
                     'custom_fields': [{'gid': REVIEWER, 'people_value': []},
                                       {'gid': IMPLEMENTOR, 'people_value': []}]}}
    rs = [
        {'method': 'GET', 'path': f'/tasks/{GID}', 'code': task_code,
         'body': task if task_code == 200 else {'errors': [{'message': 'task not found'}]}},
        {'method': 'GET', 'path': f'/projects/{PROJ}/custom_field_settings', 'code': 200,
         'body': {'data': [{'custom_field': {'gid': g}} for g in project_fields]}},
        {'method': 'PUT', 'path': f'/tasks/{GID}', 'code': put_code, 'exit': put_exit,
         'body': put_body if put_body is not None else {'data': {'gid': GID}}},
    ]
    p = os.path.join(TMP, 'routes.json')
    json.dump(rs, open(p, 'w'))
    return p


def calls():
    return [json.loads(l) for l in open(LOG)] if os.path.exists(LOG) else []


def puts():
    return [json.loads(c['data']) for c in calls() if c['method'] == 'PUT']


def update(args, token='stub', **route_kw):
    os.path.exists(LOG) and os.remove(LOG)
    e = {k: v for k, v in os.environ.items() if k not in ('AGENT_TASK_GID', 'ASANA_TOKEN', 'ASANA_GITHUB_SECRET', 'TMUX', 'TMUX_PANE')}
    e.update(HOME=HOME, PATH=BIN + ':' + os.environ['PATH'], FAKE_CURL_LOG=LOG, FAKE_ROUTES=routes(**route_kw))
    if token:
        e['ASANA_TOKEN'] = token
    return subprocess.run([UPDATE, '--task', GID] + args, capture_output=True, text=True, env=e, timeout=60)


# ---------------- A. asana-task-update.sh --assign ----------------
p = update(['--assign', '522823585857811'])
pb = puts()
check('A1 off-project assign exits 0', p.returncode == 0, p.stdout + p.stderr)
check('A1 PUT carries the assignee and no custom_fields',
      len(pb) == 1 and pb[0]['data'] == {'assignee': '522823585857811'}, pb)
check('A1 says the legacy fields were skipped', 'assignee only' in p.stdout and 'PROMPT' not in p.stdout, p.stdout)

cred = os.path.join(HOME, '.config/agent-watcher/credentials.json')
os.makedirs(os.path.dirname(cred), exist_ok=True)
json.dump({'asana_token': 'from-cred'}, open(cred, 'w'))
p = update(['--assign', '522823585857811'], token=None, project_fields=(REVIEWER, IMPLEMENTOR))
pb = puts()
check('A2 on-project assign exits 0', p.returncode == 0, p.stdout + p.stderr)
check('A2 mirrors Reviewer and resolves Implementor via whoami (credentials token exported)',
      len(pb) == 1 and pb[0]['data'].get('assignee') == '522823585857811'
      and pb[0]['data'].get('custom_fields') == {REVIEWER: ['522823585857811'], IMPLEMENTOR: ['1111']}, pb)
os.remove(cred)

p = update(['--assign', '522823585857811'], put_code=400,
           put_body={'errors': [{'message': 'Custom field with ID 123 is not on given object'}]})
check('A3 refused PUT exits 1 (not a bare 56)', p.returncode == 1, f'rc={p.returncode} {p.stderr}')
check('A3 stderr names HTTP status and Asana message',
      'HTTP 400' in p.stderr and 'is not on given object' in p.stderr and 'assignee' in p.stderr, p.stderr)

p = update(['--assign', '522823585857811'], task_code=404)
check('A4 refused task read exits 1 with HTTP status',
      p.returncode == 1 and 'Task read: FAILED (HTTP 404' in p.stderr and not puts(), p.stdout + p.stderr)

p = update(['--assign', '522823585857811'], put_exit=56)
check('A5 transport failure exits 1 and names curl exit',
      p.returncode == 1 and 'curl exit 56' in p.stderr, f'rc={p.returncode} {p.stderr}')

p = update(['--assign', '--skip-assign-if-missing'])
check('A6 missing reviewer with skip exits 0, no PUT', p.returncode == 0 and 'skipped' in p.stdout and not puts(), p.stdout + p.stderr)
p = update(['--assign'])
check('A6 missing reviewer without skip exits 2 PROMPT_REVIEWER', p.returncode == 2 and 'PROMPT_REVIEWER' in p.stdout, p.stdout + p.stderr)

p = update(['--assign', '522823585857811', '--set-reviewer', '777'])
pb = puts()
check('A7 explicit --set-reviewer is sent off-project',
      p.returncode == 0 and len(pb) == 1 and pb[0]['data'].get('custom_fields') == {REVIEWER: ['777']}, pb)

# ---------------- B. pr-create.sh --asana-attach ----------------
PRC = install('.cursor/skills/pr-create/scripts/pr-create.sh', from_path=src('.cursor/skills/pr-create/scripts/pr-create.sh'))
install('.cursor/skills/no-slop/scripts/no-slop-lint.sh', '#!/bin/bash\nexit 0\n')
ATTACH_LOG = os.path.join(TMP, 'attach.log')
GH_LOG = os.path.join(TMP, 'gh.log')
# pr-create resolves asana-task-update.sh under $HOME; replace the copy under test with a logging stub.
install('.cursor/skills/asana-task-update/scripts/asana-task-update.sh',
        '#!/bin/bash\nprintf "%s\\n" "$*" >> "$FAKE_ATTACH_LOG"\nexit "${FAKE_ATTACH_EXIT:-0}"\n')
GH = f'''#!/bin/bash
printf "%s\\n" "$*" >> "{GH_LOG}"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr create") echo "https://github.com/owner/repo/pull/42" ;;
esac
'''
open(os.path.join(BIN, 'gh'), 'w').write(GH); os.chmod(os.path.join(BIN, 'gh'), 0o755)

REPO = os.path.join(TMP, 'work/repo')
BARE = os.path.join(TMP, 'remotes/owner/repo.git')
genv = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
genv.update(HOME=HOME, PATH=BIN + ':' + os.environ['PATH'])


def git(*a, cwd=REPO):
    subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.hooksPath=/dev/null',
                    '-c', 'commit.gpgsign=false'] + list(a), cwd=cwd, env=genv, check=True, capture_output=True)


os.makedirs(REPO); os.makedirs(BARE)
git('init', '--bare', '-q', cwd=BARE)
git('init', '-q'); git('checkout', '-q', '-b', 'master')
open(os.path.join(REPO, 'a.txt'), 'w').write('a\n'); git('add', '.'); git('commit', '-qm', 'base')
git('remote', 'add', 'origin', BARE); git('push', '-q', 'origin', 'master'); git('remote', 'set-head', 'origin', 'master')
git('checkout', '-q', '-b', 'jon/feature')
open(os.path.join(REPO, 'b.txt'), 'w').write('b\n'); git('add', '.'); git('commit', '-qm', 'Add b')


def pr_create(extra, attach_exit=0):
    for f in (ATTACH_LOG, GH_LOG):
        os.path.exists(f) and os.remove(f)
    body = os.path.join(TMP, 'pr-body.md')
    open(body, 'w').write('### CHANGELOG\n\n- [ ] Yes\n- [x] No\n\n### Dependencies\n\nnone\n\n### Description\n\nAdds b.\n')
    e = dict(genv, FAKE_ATTACH_LOG=ATTACH_LOG, FAKE_ATTACH_EXIT=str(attach_exit))
    p = subprocess.run([PRC, '--title', 'Add b', '--body-file', body] + extra, cwd=REPO, env=e,
                       capture_output=True, text=True, timeout=120)
    out = None
    try:
        out = json.loads(p.stdout)
    except ValueError:
        pass
    attach = open(ATTACH_LOG).read() if os.path.exists(ATTACH_LOG) else ''
    gh = open(GH_LOG).read() if os.path.exists(GH_LOG) else ''
    return p, out, attach, gh


p, out, attach, gh = pr_create(['--draft', '--asana-task', '4440001', '--asana-attach'])
check('B1 one-shot invocation attaches', p.returncode == 0 and out and out.get('asana_attached') is True, p.stdout + p.stderr)
check('B1 attach call carries task, PR url, number',
      '--task 4440001 --attach-pr --pr-url https://github.com/owner/repo/pull/42' in attach and '--pr-number 42' in attach, attach)

p, out, attach, gh = pr_create(['--asana-attach', '--asana-task', '4440001'])
check('B2 reverse flag order attaches', p.returncode == 0 and out and out.get('asana_attached') is True and '--task 4440001' in attach, p.stdout + p.stderr)

p, out, attach, gh = pr_create(['--asana-attach'])
check('B3 --asana-attach without --asana-task exits 2 before gh pr create',
      p.returncode == 2 and 'requires --asana-task' in p.stderr and 'pr create' not in gh and not attach, f'rc={p.returncode} gh={gh!r} {p.stderr}')

p, out, attach, gh = pr_create(['--asana-task', '4440001'])
check('B4 without --asana-attach: asana_attached null, no attach call',
      p.returncode == 0 and out and out.get('asana_attached') is None and not attach, p.stdout + p.stderr)

p, out, attach, gh = pr_create(['--asana-task', '4440001', '--asana-attach'], attach_exit=1)
check('B5 failed attach reports false with WARN',
      p.returncode == 0 and out and out.get('asana_attached') is False and 'WARN' in p.stderr, p.stdout + p.stderr)

shutil.rmtree(TMP, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
