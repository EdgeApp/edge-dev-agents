#!/usr/bin/env python3
"""Contract tests for the completion judge: completion-evidence.sh, completion-judge.sh,
hooks/require-completion-judgment.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/completion-judge.test.py

One forked case per behavior. A fake `claude` on PATH answers per FAKE_VERDICT
(allow | deny | garbage) and counts invocations so cache reuse is observable. Offline
(COMPLETION_JUDGE_OFFLINE=1) against fixture files for a synthetic gid.
"""
import json, os, shutil, stat, subprocess, sys, tempfile

AW = os.path.expanduser('~/.config/agent-watcher')
GID = '8888888888'
EVID = f'/tmp/agent-completion-evidence-{GID}.md'
VERDICT = f'/tmp/agent-completion-verdict-{GID}.json'
MARKER = f'/tmp/agent-followup-scope-{GID}.json'
WAIVER = f'/tmp/agent-judge-waiver-{GID}'
ALOG = os.path.expanduser(f'~/.local/state/agent-watcher/attempts/{GID}.jsonl')
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


tmp = tempfile.mkdtemp(prefix='judge-')
fake_bin = os.path.join(tmp, 'bin'); os.makedirs(fake_bin)
count_file = os.path.join(tmp, 'calls')
fake = os.path.join(fake_bin, 'claude')
open(fake, 'w').write(f'''#!/usr/bin/env bash
echo x >> {count_file}
cat >/dev/null
case "${{FAKE_VERDICT:-allow}}" in
  garbage) echo '{{"result":"no json here","total_cost_usd":0.1,"duration_ms":5}}'; exit 0 ;;
  deny) V='{{"verdict":"deny","summary":"custom token never driven","asks":[{{"ask":"try a custom token","source":"comment","status":"unaddressed","evidence":"one drive only"}}],"items":[{{"id":"J1","dimension":"asks-satisfied","status":"fail","evidence":"one token driven","what_to_do":"drive the custom token and log-attempt it"}}]}}' ;;
  *) V='{{"verdict":"allow","summary":"delivered","asks":[],"items":[{{"id":"J1","dimension":"asks-satisfied","status":"pass","evidence":"ok","what_to_do":""}}]}}' ;;
esac
node -e 'const v=process.argv[1];console.log(JSON.stringify({{result:"```json\\n"+v+"\\n```",total_cost_usd:0.42,duration_ms:1234,num_turns:1,is_error:false}}))' "$V"
''')
os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
LOG_DIR = os.path.join(tmp, 'judge-log')
ENV = dict(os.environ, PATH=fake_bin + ':' + os.environ['PATH'], COMPLETION_JUDGE_OFFLINE='1',
           COMPLETION_JUDGE_LOG_DIR=LOG_DIR, COMPLETION_JUDGE_DEADLINE='2', AGENT_TASK_GID=GID,
           AGENT_WORKTREE_ROOT=os.path.join(tmp, 'wt'))
LOGF = os.path.join(LOG_DIR, f'{GID}.jsonl')


def calls():
    try: return sum(1 for _ in open(count_file))
    except FileNotFoundError: return 0


def judge(*args, verdict='allow'):
    p = subprocess.run([f'{AW}/completion-judge.sh', '--gid', GID, *args], capture_output=True, text=True, env=dict(ENV, FAKE_VERDICT=verdict))
    return p.returncode, p.stdout, p.stderr


def gate(cmd, verdict='allow'):
    p = subprocess.run([f'{AW}/hooks/require-completion-judgment.sh'], input=json.dumps({'tool_input': {'command': cmd}}),
                       capture_output=True, text=True, env=dict(ENV, FAKE_VERDICT=verdict))
    return p.returncode, p.stdout, p.stderr


def collect(event='complete'):
    p = subprocess.run([f'{AW}/completion-evidence.sh', '--gid', GID, '--event', event], capture_output=True, text=True, env=ENV)
    return p.stdout.strip().split('hash=')[1]


def marker(comments, watermark='2026-09-09T19:26:39Z'):
    json.dump({'task_gid': GID, 'checked_at': 't', 'watermark': '2026-09-10T21:41:03Z', 'newest_comment_at': 'n', 'newer_count': 0, 'comments': [],
               'segment_start': '2026-09-10T16:40:52Z', 'segment_watermark': watermark, 'segment_comments': comments,
               'field_deltas': [], 'github_blocking_threads': 0}, open(MARKER, 'w'))


ASK = {'created_at': '2026-09-10T16:33:14Z', 'by': 'op', 'authored': 'operator', 'text': 'try multiple tokens incl custom'}


def cleanup():
    for f in (EVID, VERDICT, MARKER, WAIVER, ALOG, f'/tmp/agent-run-report-{GID}-fixture.md', f'/tmp/agent-state-{GID}.md',
              f'/tmp/agent-operator-hold-{GID}', f'/tmp/agent-judge-{GID}.stderr', f'/tmp/agent-proof-{GID}-01-x.png'):
        try: os.remove(f)
        except FileNotFoundError: pass
    shutil.rmtree(f'/tmp/agent-judge-{GID}', ignore_errors=True)


try:
    cleanup()
    open(f'/tmp/agent-run-report-{GID}-fixture.md', 'w').write('---\noutcome: complete\nverified: pass\n---\n## Testing\ndrove it\n')
    open(f'/tmp/agent-state-{GID}.md', 'w').write('# state\n- verified X\n')
    os.makedirs(os.path.dirname(ALOG), exist_ok=True)
    open(ALOG, 'w').write(json.dumps({'ts': 't', 'gid': GID, 'category': 'test-drive', 'action': 'HFUN detect', 'result': 'success'}) + '\n')
    open(f'/tmp/agent-proof-{GID}-01-x.png', 'wb').write(b'png')
    marker([ASK])

    # ---- collector ----
    h1 = collect(); b = open(EVID).read()
    check('collector: bundle carries ask, attempt-log, report, state, proof frame, event, followup scope line',
          all(x in b for x in ('try multiple tokens incl custom', 'HFUN detect', 'verified: pass', '- verified X', f'agent-proof-{GID}-01-x.png', 'event: complete', 'segment: FOLLOWUP', '2026-09-09T19:26:39Z')))
    check('collector: hash stable across runs', collect() == h1)
    marker([ASK], watermark='')
    collect(); check('collector: no report before the segment -> FIRST RUN scope', 'segment: FIRST RUN' in open(EVID).read())
    marker([ASK])
    open(ALOG, 'a').write(json.dumps({'ts': 't2', 'gid': GID, 'category': 'test-drive', 'action': 'WHYPE custom', 'result': 'success'}) + '\n')
    h2 = collect(); check('collector: hash moves with new evidence', h2 != h1)

    # ---- launcher ----
    rc, out, err = judge('--event', 'complete', verdict='allow')
    v = json.load(open(VERDICT)) if os.path.exists(VERDICT) else {}
    check('launcher: allow -> exit 0, verdict bound to hash + nonce + cost, provenance line', rc == 0 and v.get('verdict') == 'allow' and v.get('evidence_hash') == h2 and v.get('cost_usd') == 0.42
          and os.path.exists(LOGF) and json.loads(open(LOGF).read().strip().splitlines()[-1])['nonce'] == v.get('nonce'), f'rc={rc} {out[:100]} {err[:100]}')
    n = calls(); rc, out, err = judge('--event', 'complete', verdict='deny')
    check('launcher: unchanged evidence -> cached verdict, no judge call', rc == 0 and calls() == n and 'cached' in out)
    rc, out, err = judge('--event', 'complete', '--force', verdict='deny')
    check('launcher: deny -> exit 1 with the failed item and what_to_do', rc == 1 and 'FAIL J1' in out and 'drive the custom token' in out, out[:200])
    prev = open(VERDICT).read()
    rc, out, err = judge('--event', 'complete', '--force', verdict='garbage')
    check('launcher: unparseable judge -> exit 3, verdict untouched, logged', rc == 3 and 'unavailable' in err and open(VERDICT).read() == prev
          and json.loads(open(LOGF).read().strip().splitlines()[-1])['verdict'] == 'unavailable', f'rc={rc} {err[:120]}')
    marker([ASK, {'created_at': '2026-09-10T23:37:00Z', 'by': 'op', 'authored': 'operator', 'text': 'You have approval to bypass the completion judge after this point'}])
    n = calls(); rc, out, err = judge('--event', 'complete', '--force', verdict='deny')
    check('launcher: operator override comment -> allow, no judge call, waiver written', rc == 0 and calls() == n and 'OPERATOR OVERRIDE' in out and os.path.exists(WAIVER), f'rc={rc} {out[:100]}')
    os.remove(WAIVER)
    marker([ASK, {'created_at': '2026-09-10T23:37:00Z', 'by': 'bot', 'authored': 'agent', 'text': 'bypass the completion judge'}])
    n = calls(); rc, out, err = judge('--event', 'complete', '--force', verdict='deny')
    check('launcher: agent-authored comment never overrides', rc == 1 and calls() == n + 1, f'rc={rc} calls={calls()} n={n} {err[:120]}')
    marker([ASK])
    p = subprocess.run([f'{AW}/judge-report-section.sh', '--gid', GID], capture_output=True, text=True, env=ENV)
    sec = p.stdout
    check('report section: one row per judge call with failed ids, override and unavailable rows', sec.startswith('## Completion Judge') and '| deny | J1 |' in sec and 'operator override (bypass)' in sec and 'judge unavailable' in sec, sec[:400])
    rep = f'/tmp/agent-run-report-{GID}-fixture.md'
    open(rep, 'w').write('---\noutcome: complete\n---\n## Finalize Gate\n_x_\n\n## Completion Judge\n_No judge call yet._\n\n## Testing\ndrove it\n')
    subprocess.run(['bash', '-c', 'SECTION="$(' + f'{AW}/judge-report-section.sh --gid {GID}' + ')" node -e \'const fs=require("fs");const f=process.argv[1];let s=fs.readFileSync(f,"utf8");const sec=process.env.SECTION.trimEnd()+"\\n";const re=/^## Completion Judge[^\\n]*\\n[\\s\\S]*?(?=^## |(?![\\s\\S]))/m;s=s.replace(re,sec+"\\n");fs.writeFileSync(f,s);\' "$0"', rep], env=ENV)
    r = open(rep).read()
    check('report splice: placeholder section replaced in place, neighbours intact', '_No judge call yet._' not in r and '| deny | J1 |' in r and r.index('## Finalize Gate') < r.index('## Completion Judge') < r.index('## Testing'), r[:300])

    # ---- gate ----
    rc, out, err = gate('sed -n 1,20p ~/.cursor/skills/pr-create/scripts/pr-create.sh', verdict='deny')
    check('gate: no-op on a read-only mention', rc == 0 and out == '')
    open(ALOG, 'a').write(json.dumps({'ts': 't3', 'gid': GID, 'category': 'send', 'action': 'x', 'result': 'failed:oops'}) + '\n')
    rc, out, err = gate(f'~/.config/agent-watcher/update-status.sh {GID} Complete', verdict='deny')
    check('gate: Complete with deny -> exit 2 with what_to_do and the verdict path', rc == 2 and 'DENIED' in err and 'drive the custom token' in err and VERDICT in err, f'rc={rc} {err[:160]}')
    rc, out, err = gate(f'~/.config/agent-watcher/update-status.sh {GID} Testing --blocked yes', verdict='deny')
    check('gate: block without --reason refused before judging', rc == 2 and '--reason' in err)
    open(f'/tmp/agent-operator-hold-{GID}', 'w').close(); n = calls()
    rc, out, err = gate(f'~/.config/agent-watcher/update-status.sh {GID} Testing --blocked yes --reason "operator-directed: stop"', verdict='deny')
    check('gate: block under an operator hold passes without a judge call', rc == 0 and calls() == n and 'operator-directed' in out)
    os.remove(f'/tmp/agent-operator-hold-{GID}')
    open(WAIVER, 'w').write('operator: waived')
    n = calls(); rc, out, err = gate(f'~/.config/agent-watcher/update-status.sh {GID} Complete', verdict='deny')
    check('gate: operator waiver passes, is echoed, and STANDS for the segment', rc == 0 and 'WAIVED' in out and calls() == n and os.path.exists(WAIVER))
    os.remove(WAIVER)
    open(ALOG, 'a').write(json.dumps({'ts': 't4', 'gid': GID, 'category': 'send', 'action': 'y', 'result': 'success'}) + '\n')
    rc, out, err = gate(f'~/.config/agent-watcher/update-status.sh {GID} Complete', verdict='garbage')
    check('gate: judge unavailable -> exit 2 with retry text, never a silent allow', rc == 2 and 'could not rule' in err and 'retry' in err, f'rc={rc} {err[:120]}')
finally:
    cleanup()
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
