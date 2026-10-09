#!/usr/bin/env python3
"""Contract test for ~/.cursor/skills/dep-publish-sanction.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/dep-publish-sanction.test.py

Covers the log classifier on saved Travis output (three trimmed real job logs
plus an install failure built from npm's real ETARGET text) and the
apply / check / clear contract against stubbed gh, npm and curl. Nothing here
touches GitHub, npm or Travis.
"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, 'fixtures')
SCRIPT = os.path.expanduser('~/.cursor/skills/dep-publish-sanction.sh')
LABEL = 'awaiting-dep-publish'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name)
    if not cond:
        fails.append(name)
        if detail:
            print('     ' + str(detail)[:300])


# ---------------------------------------------------------------- classifier
def classify(log_text=None, fixture=None, dep='edge-core-js', kind='travis'):
    path = os.path.join(FIX, fixture) if fixture else None
    tmp = None
    if log_text is not None:
        tmp = tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False)
        tmp.write(log_text); tmp.close(); path = tmp.name
    p = subprocess.run([SCRIPT, 'classify', '--log-file', path, '--dep', dep, '--kind', kind],
                       capture_output=True, text=True)
    if tmp:
        os.remove(tmp.name)
    return p.stdout.strip()


out = classify(fixture='travis-tsc-missing-api.fixture.txt')
check('travis: tsc the only failed step, diagnostics do not name the package -> types',
      out.startswith('missing-package types 3 TypeScript'), out)
out = classify(fixture='travis-tsc-missing-export.fixture.txt', dep='edge-core-js,edge-exchange-plugins')
check('travis: tsc failed on a missing export -> types', out.startswith('missing-package types'), out)
out = classify(fixture='travis-test-failure.fixture.txt')
check('travis: a failed test command is never excused', out.startswith('other `npm test` failed'), out)
out = classify(fixture='travis-install-etarget.fixture.txt', dep='edge-info-server')
check('travis: install step with ETARGET naming the package -> install',
      out.startswith('missing-package install'), out)
out = classify(fixture='travis-install-etarget.fixture.txt', dep='edge-core-js')
check('travis: install ETARGET naming a different package -> other', out.startswith('other `npm ci` failed'), out)
out = classify(log_text='npm error code ECONNRESET\nThe command "npm ci" failed and exited with 1 during .\n', dep='edge-info-server')
check('travis: install failed with no registry error -> other', out.startswith('other'), out)
out = classify(log_text='src/a.ts(1,1): error TS2339: Property x does not exist\nThe command "npx tsc" exited with 2.\n'
                        'FAIL src/a.test.ts\nThe command "npm test" exited with 1.\n')
check('travis: tsc and tests both failed -> other', out.startswith('other `npm test` failed'), out)
out = classify(log_text='The command "npx tsc" exited with 2.\n')
check('travis: tsc failed with no diagnostic -> other', out.startswith('other `npx tsc` failed with no TypeScript'), out)
out = classify(log_text='Done. Your build exited with 1.\n')
check('travis: no failed command in the log -> other', out.startswith('other the job log reports no failed command'), out)
out = classify(log_text='The command "yarn build" exited with 1.\nerror TS2339: x\n')
check('travis: a failed build command -> other', out.startswith('other `yarn build` failed'), out)
out = classify(log_text='verify\ttsc\t2031-01-01T00:00:00Z src/a.ts(1,1): error TS2305: Module has no exported member\n', kind='actions')
check('actions: failed step with a TypeScript diagnostic -> types', out.startswith('missing-package types'), out)
out = classify(log_text='verify\ttest\t2031-01-01T00:00:00Z FAIL src/a.test.ts\nverify\ttest\tx Tests:       1 failed, 3 passed\n'
                        'verify\ttsc\tx error TS2305: y\n', kind='actions')
check('actions: failing tests in the failed step -> other', out.startswith('other the failed step reports failing tests'), out)
out = classify(log_text='verify\tlint\tx some output\n', kind='actions')
check('actions: nothing recognizable -> other', out.startswith('other no registry error'), out)

# ------------------------------------------------------- apply / check / clear
work = tempfile.mkdtemp(prefix='dps-test-')
stub = os.path.join(work, 'bin'); os.makedirs(stub)
STATE = os.path.join(work, 'pr.json')
LOG = os.path.join(work, 'gh.log')

GH = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
state_path = os.environ['STUB_STATE']
st = json.load(open(state_path))
open(os.environ['STUB_GH_LOG'], 'a').write(' '.join(a) + '\n')
def save(): json.dump(st, open(state_path, 'w'))
if a[:2] == ['api', 'user']:
    print(os.environ.get('STUB_ME', 'me')); sys.exit(0)
if a[0] == 'api' and '/labels/' in a[1]:
    sys.exit(0 if os.environ.get('STUB_LABEL_EXISTS', '1') == '1' else 1)
if a[:2] == ['pr', 'view']:
    print(json.dumps({'state': st['state'], 'body': st['body'], 'author': {'login': st['author']},
                      'labels': [{'name': n} for n in st['labels']]})); sys.exit(0)
if a[:2] == ['pr', 'checks']:
    print(os.environ.get('STUB_CHECKS', '[]')); sys.exit(0)
if a[:2] == ['pr', 'edit']:
    if '--body-file' in a: st['body'] = open(a[a.index('--body-file') + 1]).read()
    if '--add-label' in a:
        l = a[a.index('--add-label') + 1]
        if l not in st['labels']: st['labels'].append(l)
    if '--remove-label' in a:
        l = a[a.index('--remove-label') + 1]
        st['labels'] = [x for x in st['labels'] if x != l]
    save(); sys.exit(0)
if a[:2] == ['run', 'view']:
    f = os.environ.get('STUB_ACTIONS_LOG', '')
    if f: sys.stdout.write(open(f).read())
    sys.exit(0)
sys.exit(1)
'''
NPM = r'''#!/usr/bin/env bash
# `npm view <pkg> versions --json`
if [ "${STUB_NPM_FAIL:-0}" = 1 ]; then exit 1; fi
echo "${STUB_NPM_VERSIONS:-[\"1.0.0\",\"1.1.0\"]}"
'''
CURL = r'''#!/usr/bin/env bash
URL=""
for a in "$@"; do case "$a" in http*) URL="$a" ;; esac; done
case "$URL" in
  */build/*/jobs) if [ -n "${STUB_TRAVIS_JOBS:-}" ]; then echo "$STUB_TRAVIS_JOBS"; else echo '{"jobs":[{"id":11,"state":"failed"}]}'; fi ;;
  */job/*/log.txt) cat "$STUB_TRAVIS_LOG" ;;
  *) exit 22 ;;
esac
'''
for name, body in (('gh', GH), ('npm-stub', NPM), ('curl', CURL)):
    p = os.path.join(stub, name)
    open(p, 'w').write(body); os.chmod(p, 0o755)

TRAVIS_LINK = 'https://app.travis-ci.com/github/EdgeApp/edge-react-gui/builds/123'
ACTIONS_LINK = 'https://github.com/EdgeApp/edge-react-gui/actions/runs/456/job/789'
TRAVIS_FAIL = json.dumps([{'name': 'Travis CI - Pull Request', 'bucket': 'fail', 'link': TRAVIS_LINK},
                          {'name': 'Cursor Bugbot', 'bucket': 'pass', 'link': ''}])


def reset(body='### Description\n\nAdds b.\n', labels=(), author='me', state='OPEN'):
    json.dump({'state': state, 'body': body, 'labels': list(labels), 'author': author}, open(STATE, 'w'))
    if os.path.exists(LOG):
        os.remove(LOG)


def run(args, **env):
    e = dict(os.environ, PATH=stub + os.pathsep + os.environ['PATH'], STUB_STATE=STATE, STUB_GH_LOG=LOG,
             DPS_NPM=os.path.join(stub, 'npm-stub'), DPS_TRAVIS_API='https://travis.invalid')
    e.update({k: str(v) for k, v in env.items()})
    return subprocess.run([SCRIPT] + args + ['--repo', 'EdgeApp/edge-react-gui', '--pr', '42'],
                          capture_output=True, text=True, env=e)


def st():
    return json.load(open(STATE))


def ghlog():
    return open(LOG).read() if os.path.exists(LOG) else ''


BLOCK = '<!-- agent-dep-publish:start -->\nAwaiting publish: edge-core-js@1.2.0\n<!-- agent-dep-publish:end -->'
# What apply writes: the awaited version plus the registry's latest at that moment.
BLOCK_APPLIED = ('<!-- agent-dep-publish:start -->\nAwaiting publish: edge-core-js@1.2.0 (npm latest when applied: 1.1.0)\n'
                 '<!-- agent-dep-publish:end -->')

# apply
reset()
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.2.0'], STUB_LABEL_EXISTS=0)
check('apply: label missing in the repo -> exit 2, nothing edited',
      p.returncode == 2 and 'NEEDS OPERATOR' in p.stderr and 'pr edit' not in ghlog(), p.stderr)
reset()
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.1.0'])
check('apply: version already on npm -> exit 3, nothing edited',
      p.returncode == 3 and 'REFUSED' in p.stderr and 'pr edit' not in ghlog(), p.stderr)
reset()
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.0.5'])
check('apply: registry already moved past the version -> exit 3', p.returncode == 3 and 'superseded' in p.stderr, p.stderr)
reset(author='someone-else')
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.2.0'])
check('apply: not the PR author -> exit 1, nothing edited', p.returncode == 1 and 'pr edit' not in ghlog(), p.stderr)
reset(state='MERGED')
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.2.0'])
check('apply: PR not open -> exit 1', p.returncode == 1, p.stderr)
reset()
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.2.0'], STUB_NPM_FAIL=1)
check('apply: npm unreachable -> exit 1, nothing edited', p.returncode == 1 and 'pr edit' not in ghlog(), p.stderr)
reset()
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.2.0'])
check('apply: adds the label and the body block, keeps the prose',
      p.returncode == 0 and LABEL in st()['labels'] and BLOCK_APPLIED in st()['body']
      and st()['body'].startswith('### Description\n\nAdds b.'), p.stdout + p.stderr + st()['body'])
p = run(['apply', '--dep', 'edge-exchange-plugins', '--version', '2.0.0'], STUB_NPM_VERSIONS='["1.9.0"]')
check('apply: a second dependency adds a line',
      p.returncode == 0 and ('Awaiting publish: edge-core-js@1.2.0 (npm latest when applied: 1.1.0)\n'
                             'Awaiting publish: edge-exchange-plugins@2.0.0 (npm latest when applied: 1.9.0)') in st()['body']
      and st()['body'].count('agent-dep-publish:start') == 1, st()['body'])
p = run(['apply', '--dep', 'edge-core-js', '--version', '1.3.0'])
check('apply: the same dependency again replaces its line',
      p.returncode == 0 and 'edge-core-js@1.3.0' in st()['body'] and 'edge-core-js@1.2.0' not in st()['body']
      and 'edge-exchange-plugins@2.0.0' in st()['body'], st()['body'])

# check
reset(body='x\n\n' + BLOCK + '\n')
p = run(['check'])
check('check: no label -> none, exit 5', p.returncode == 5 and p.stdout.startswith('SANCTION: none'), p.stdout)
reset(labels=[LABEL])
p = run(['check'])
check('check: label without a body line -> none, exit 5', p.returncode == 5 and 'Awaiting publish' in p.stdout, p.stdout)
reset(body='x\n\n' + BLOCK + '\n', labels=[LABEL])
p = run(['check'], STUB_NPM_VERSIONS='["1.1.0","1.2.0"]', STUB_CHECKS=TRAVIS_FAIL)
check('check: awaited version published -> expired, exit 3',
      p.returncode == 3 and p.stdout.startswith('SANCTION: expired published="edge-core-js@1.2.0"'), p.stdout)
p = run(['check'], STUB_NPM_VERSIONS='["1.1.0","1.4.0"]', STUB_CHECKS=TRAVIS_FAIL)
check('check: registry moved past the awaited version -> expired', p.returncode == 3, p.stdout)
reset(body='x\n\n' + BLOCK_APPLIED + '\n', labels=[LABEL])
p = run(['check'], STUB_NPM_VERSIONS='["1.0.0","1.1.0","1.1.1"]', STUB_CHECKS=TRAVIS_FAIL)
check('check: a publish under a LOWER version than predicted still expires it (latest moved past the one recorded at apply)',
      p.returncode == 3 and p.stdout.startswith('SANCTION: expired'), p.stdout)
p = run(['check'], STUB_CHECKS='[]')
check('check: registry unchanged since apply -> valid',
      p.returncode == 0 and 'awaiting="edge-core-js@1.2.0"' in p.stdout, p.stdout)
reset(body='x\n\n' + BLOCK + '\n', labels=[LABEL])
p = run(['check'], STUB_NPM_FAIL=1)
check('check: npm unreachable -> exit 1, no verdict', p.returncode == 1 and 'SANCTION' not in p.stdout, p.stdout)
p = run(['check'], STUB_CHECKS=TRAVIS_FAIL, STUB_TRAVIS_LOG=os.path.join(FIX, 'travis-tsc-missing-api.fixture.txt'))
check('check: failing Travis is a tsc-only failure -> valid, exit 0',
      p.returncode == 0 and p.stdout.strip() == 'SANCTION: valid awaiting="edge-core-js@1.2.0" excused="Travis CI - Pull Request" kind=types',
      p.stdout + p.stderr)
p = run(['check'], STUB_CHECKS=TRAVIS_FAIL, STUB_TRAVIS_LOG=os.path.join(FIX, 'travis-test-failure.fixture.txt'))
check('check: failing Travis is a test failure -> unconfirmed, exit 4',
      p.returncode == 4 and p.stdout.startswith('SANCTION: unconfirmed check="Travis CI - Pull Request"'), p.stdout)
p = run(['check'], STUB_CHECKS=TRAVIS_FAIL, STUB_TRAVIS_JOBS='{"jobs":[{"id":11,"state":"passed"}]}')
check('check: Travis build with no failed job to read -> unconfirmed', p.returncode == 4, p.stdout)
p = run(['check'], STUB_CHECKS=json.dumps([{'name': 'Socket Security', 'bucket': 'fail', 'link': 'https://socket.dev'}]))
check('check: a failing check with no CI log -> unconfirmed', p.returncode == 4 and 'no CI log' in p.stdout, p.stdout)
p = run(['check'], STUB_CHECKS=json.dumps([{'name': 'Cursor Bugbot', 'bucket': 'fail', 'link': 'https://cursor.com/x'}]))
check('check: a failing reviewer-bot check is never excused', p.returncode == 4, p.stdout)
wip = json.dumps([{'name': 'block-wip-pr', 'bucket': 'fail', 'link': ACTIONS_LINK},
                  {'name': 'Travis CI - Pull Request', 'bucket': 'fail', 'link': TRAVIS_LINK}])
p = run(['check', '--ignore-prefix', 'block-wip-pr'], STUB_CHECKS=wip,
        STUB_TRAVIS_LOG=os.path.join(FIX, 'travis-tsc-missing-api.fixture.txt'))
check('check: --ignore-prefix leaves a named check to the caller',
      p.returncode == 0 and 'excused="Travis CI - Pull Request"' in p.stdout, p.stdout)
p = run(['check'], STUB_CHECKS=wip, STUB_TRAVIS_LOG=os.path.join(FIX, 'travis-tsc-missing-api.fixture.txt'))
check('check: without it the wip-guard failure is unconfirmed', p.returncode == 4 and 'block-wip-pr' in p.stdout, p.stdout)
alog = os.path.join(work, 'actions.log')
open(alog, 'w').write('verify\ttsc\t2031-01-01T00:00:00Z src/a.ts(1,1): error TS2339: Property x does not exist\n')
p = run(['check'], STUB_CHECKS=json.dumps([{'name': 'verify', 'bucket': 'fail', 'link': ACTIONS_LINK}]), STUB_ACTIONS_LOG=alog)
check('check: failing Actions job with a TypeScript diagnostic -> valid', p.returncode == 0 and 'kind=types' in p.stdout, p.stdout)
p = run(['check'], STUB_CHECKS='[]')
check('check: nothing failing -> valid with nothing excused',
      p.returncode == 0 and 'excused="" kind=none' in p.stdout, p.stdout)
two = 'x\n\n<!-- agent-dep-publish:start -->\nAwaiting publish: edge-core-js@1.1.0\nAwaiting publish: edge-info-server@9.0.0\n<!-- agent-dep-publish:end -->\n'
reset(body=two, labels=[LABEL])
p = run(['check'], STUB_CHECKS='[]')
check('check: one of two dependencies published -> still valid, waiting on the other',
      p.returncode == 0 and 'awaiting="edge-info-server@9.0.0"' in p.stdout, p.stdout + p.stderr)

# clear
reset(body='### Description\n\nAdds b.\n\n' + BLOCK + '\n', labels=[LABEL, 'bug'])
p = run(['clear'])
check('clear: removes the label and the body block, keeps the rest',
      p.returncode == 0 and st()['labels'] == ['bug'] and 'agent-dep-publish' not in st()['body']
      and st()['body'].strip() == '### Description\n\nAdds b.', st())
reset()
p = run(['clear'])
check('clear: nothing to clear is a no-op', p.returncode == 0 and 'pr edit' not in ghlog(), ghlog())

p = subprocess.run([SCRIPT, 'check'], capture_output=True, text=True)
check('usage: missing --repo/--pr exits 2', p.returncode == 2, p.stderr)

shutil.rmtree(work, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
