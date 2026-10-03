#!/usr/bin/env python3
"""Repo field sync at Complete.

sync-repo-field.sh reads the PRs on a task and its subtasks (lib/task-pr-urls.sh),
drops PRs closed without merging, and hands the repo names to
asana-task-update.sh --set-repos, which maps them through asana-config
custom_fields.repo.github_repo_options, adds AND removes options so Repo matches
exactly, never removes an option the map does not cover, skips what it cannot
map, and records the write in the orch field-write ledger. A task with no PR at
all is left untouched. check-followup-scope.sh
then drops a Repo delta that equals the orch's own write.
"""
import json
import os
import subprocess
import sys
import tempfile

HOME = os.path.expanduser('~')
SYNC = os.path.join(HOME, '.config/agent-watcher/sync-repo-field.sh')
CHECK = os.path.join(HOME, '.config/agent-watcher/check-followup-scope.sh')
GID = '9999999999997'
fails = 0


def check(name, ok, detail=''):
    global fails
    print(('PASS ' if ok else 'FAIL ') + name)
    if not ok:
        fails += 1
        if detail:
            print('     ' + str(detail)[:900])


OPTIONS = [{'gid': 'o-gui', 'name': 'GUI', 'enabled': True}, {'gid': 'o-core', 'name': 'Core', 'enabled': True},
           {'gid': 'o-exch', 'name': 'Exch', 'enabled': True}, {'gid': 'o-accb', 'name': 'Accb', 'enabled': True},
           {'gid': 'o-server', 'name': 'Server', 'enabled': True}]

CURL_STUB = r'''#!/usr/bin/env bash
URL=""; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    -d) BODY="$2"; shift 2 ;;
    -w) shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    https://*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
emit() { if [ -n "${OUT:-}" ]; then printf '%s' "$1" > "$OUT"; printf 200; else printf '%s' "$1"; fi; }
case "$METHOD $URL" in
  "PUT "*/tasks/*) printf '%s' "$BODY" | jq -c . >> "$STUB_PUT_LOG"; emit '{"data":{}}' ;;
  *"/tasks/$STUB_GID/subtasks"*) emit '{"data":[{"gid":"sub1"}]}' ;;
  *"/tasks/sub1/attachments"*) emit "$STUB_SUB_ATT" ;;
  *"/tasks/$STUB_GID/attachments"*) emit "$STUB_ATT" ;;
  *"/tasks/$STUB_GID/stories"*) emit '{"data":[]}' ;;
  *"/tasks/$STUB_GID?"*custom_fields.multi_enum_values*) emit "$STUB_TASK_REPO" ;;
  *"/tasks/$STUB_GID?"*) emit "$STUB_TASK_FIELDS" ;;
  *"/users/me"*) emit '{"data":{"gid":"1"}}' ;;
  *) emit '{"data":[]}' ;;
esac
'''
GH_STUB = r'''#!/usr/bin/env bash
case "$*" in
  "pr view"*) case "$*" in *"$STUB_CLOSED_PR"*) echo CLOSED ;; *) echo OPEN ;; esac ;;
  "api user"*) echo me ;;
  *) exit 1 ;;
esac
'''

tdir = tempfile.mkdtemp(prefix='repo-sync-')
bindir = os.path.join(tdir, 'bin')
os.makedirs(bindir)
for name, body in (('curl', CURL_STUB), ('gh', GH_STUB)):
    p = os.path.join(bindir, name)
    with open(p, 'w') as fh:
        fh.write(body)
    os.chmod(p, 0o755)
put_log = os.path.join(tdir, 'put.log')


def att(*urls):
    return json.dumps({'data': [{'view_url': u} for u in urls]})


def task_repo(current):
    return json.dumps({'data': {'custom_fields': [
        {'gid': 'f-other', 'name': 'Priority', 'resource_subtype': 'enum'},
        {'gid': 'f-repo', 'name': 'Repo', 'resource_subtype': 'multi_enum', 'enum_options': OPTIONS,
         'multi_enum_values': [o for o in OPTIONS if o['name'] in current]}]}})


def env(**kw):
    e = dict(os.environ, PATH=bindir + os.pathsep + os.environ['PATH'], ASANA_TOKEN='fixture',
             XDG_STATE_HOME=tdir, STUB_GID=GID, STUB_PUT_LOG=put_log, STUB_CLOSED_PR='none',
             STUB_ATT=att(), STUB_SUB_ATT=att(), STUB_TASK_REPO=task_repo([]),
             STUB_TASK_FIELDS=json.dumps({'data': {'name': 't', 'completed': False, 'custom_fields': []}}))
    e.pop('AGENT_TASK_GID', None)
    e.update(kw)
    return e


def sync(**kw):
    open(put_log, 'w').close()
    p = subprocess.run(['bash', SYNC, '--task-gid', GID], capture_output=True, text=True, env=env(**kw))
    puts = [json.loads(l) for l in open(put_log) if l.strip()]
    return p, puts


GUI = 'https://github.com/EdgeApp/edge-react-gui/pull/6066'
CORE = 'https://github.com/EdgeApp/edge-core-js/pull/730'
EXCH = 'https://github.com/EdgeApp/edge-exchange-plugins/pull/469'
OTHER = 'https://github.com/EdgeApp/edge-reports-server/pull/12'

# 1. parent + subtask PRs, Repo empty: all mapped repos added, unmapped skipped
p, puts = sync(STUB_ATT=att(GUI, OTHER), STUB_SUB_ATT=att(CORE))
vals = puts[0]['data']['custom_fields'].get('f-repo') if puts else None
check('adds GUI and Core from task and subtask PRs', sorted(vals or []) == ['o-core', 'o-gui'], p.stdout + p.stderr)
check('unmapped repo is reported and skipped', 'edge-reports-server' in p.stdout and 'skipped' in p.stdout, p.stdout)
check('only the Repo field is written', puts and list(puts[0]['data']['custom_fields']) == ['f-repo'], puts)

# 2. stale managed option removed, unmanaged option (not in the map) kept
p, puts = sync(STUB_ATT=att(GUI), STUB_TASK_REPO=task_repo(['Accb', 'Core', 'Server']))
vals = puts[0]['data']['custom_fields'].get('f-repo') if puts else None
check('removes Accb and Core, keeps unmanaged Server, adds GUI', sorted(vals or []) == ['o-gui', 'o-server'], p.stdout + p.stderr)
check('output names both directions', 'added [GUI]' in p.stdout and 'Accb' in p.stdout and 'Core' in p.stdout, p.stdout)

# 3. already complete: no write
p, puts = sync(STUB_ATT=att(GUI), STUB_TASK_REPO=task_repo(['GUI']))
check('nothing to add: no PUT, says unchanged', not puts and 'unchanged' in p.stdout, p.stdout + str(puts))

# 4. a PR closed without merging adds nothing
p, puts = sync(STUB_ATT=att(GUI, EXCH), STUB_CLOSED_PR='edge-exchange-plugins')
vals = puts[0]['data']['custom_fields'].get('f-repo') if puts else None
check('closed-unmerged PR is ignored', sorted(vals or []) == ['o-gui'], p.stdout + str(puts))

# 4b. every PR closed unmerged: no repo changed, managed options come off
p, puts = sync(STUB_ATT=att(EXCH), STUB_CLOSED_PR='edge-exchange-plugins', STUB_TASK_REPO=task_repo(['Exch', 'Server']))
vals = puts[0]['data']['custom_fields'].get('f-repo') if puts else None
check('all PRs closed: managed option removed, unmanaged kept', vals == ['o-server'], p.stdout + p.stderr + str(puts))

# 5. no PRs at all: the field is left exactly as a person set it
p, puts = sync(STUB_TASK_REPO=task_repo(['GUI']))
check('no PRs: nothing written, exit 0', not puts and p.returncode == 0 and 'left as is' in p.stdout, p.stdout)

# 6. ledger + delta filter: the orch's own Repo write is not operator intent
ledger = os.path.join(tdir, 'agent-watcher', 'orch-field-writes', f'{GID}.jsonl')
os.remove(ledger) if os.path.exists(ledger) else None
sync(STUB_ATT=att(GUI), STUB_SUB_ATT=att(CORE))
rows = [json.loads(l) for l in open(ledger)] if os.path.exists(ledger) else []
check('write recorded in the field-write ledger', rows and rows[-1]['field'] == 'Repo'
      and sorted(rows[-1]['values']) == ['Core', 'GUI'], rows)

vdir = os.path.join(tdir, 'agent-watcher', 'versions')
os.makedirs(vdir, exist_ok=True)
with open(os.path.join(vdir, f'{GID}.jsonl'), 'w') as fh:
    fh.write(json.dumps({'ts': '2026-10-01T00:00:00Z', 'fields': {'name': 't', 'completed': False, 'Repo': None, 'Priority': 'Low'}}) + '\n')


def deltas(repo_now, prio_now='Low'):
    fields = {'data': {'name': 't', 'completed': False, 'custom_fields': [
        {'gid': '1213919399225909', 'name': 'Repo', 'display_value': repo_now},
        {'gid': '1213843686985522', 'name': 'Priority', 'display_value': prio_now},
        {'gid': '1190660107346181', 'name': 'Status', 'display_value': 'foreign board'}]}}
    marker = f'/tmp/agent-followup-scope-{GID}.json'
    subprocess.run(['bash', CHECK, '--task-gid', GID], capture_output=True, text=True,
                   env=env(STUB_TASK_FIELDS=json.dumps(fields)))
    m = json.load(open(marker)) if os.path.exists(marker) else {}
    os.remove(marker) if os.path.exists(marker) else None
    return {d['field'] for d in m.get('field_deltas', [])}, m.get('field_delta_status')


d, st = deltas('Core, GUI')
check("Repo equal to the orch's write: not a delta", 'Repo' not in d and st == 'ok', (d, st))
d, st = deltas('GUI, Core', prio_now='High')
check('order-insensitive, and a real operator change still shows', 'Repo' not in d and 'Priority' in d, (d, st))
d, st = deltas('Core, GUI, Accb')
check('operator added a repo on top: delta shows', 'Repo' in d, (d, st))
check("another board's same-named field never shows as a delta", 'Status' not in d, (d, st))

# an orch write that emptied the field reads back as null: still the orch's own
with open(ledger, 'a') as fh:
    fh.write(json.dumps({'field': 'Repo', 'values': [], 'ts': '2026-10-02T00:00:00Z'}) + '\n')
with open(os.path.join(vdir, f'{GID}.jsonl'), 'w') as fh:
    fh.write(json.dumps({'ts': '2026-10-01T00:00:00Z', 'fields': {'name': 't', 'completed': False, 'Repo': 'GUI', 'Priority': 'Low'}}) + '\n')
d, st = deltas(None)
check("emptied by the orch (GUI -> null): not a delta", 'Repo' not in d and st == 'ok', (d, st))

print(f'\n{fails} failure(s)')
sys.exit(1 if fails else 0)
