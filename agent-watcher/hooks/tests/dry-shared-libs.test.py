#!/usr/bin/env python3
"""The shared definitions that replaced per-script copies.

  hooks/lib/completion-event.sh   one completion-event classifier
  lib/agent-authored.jq           one agent-comment marker test
  lib/task-fields.sh              one field registry, snapshot and delta rule
  ~/.cursor/skills/git-default-branch.sh   one default-branch resolver
  pr-create/scripts/hacked-frames.sh       one HACKED frame rule
  lib/judge-log.sh                one judge log dir and override line
  lib/worktree-root.sh / .js      one worktree root
"""
import json
import os
import subprocess
import sys
import tempfile

HOME = os.path.expanduser('~')
AW = os.path.join(HOME, '.config/agent-watcher')
fails = 0


def check(name, ok, detail=''):
    global fails
    print(('PASS ' if ok else 'FAIL ') + name)
    if not ok:
        fails += 1
        if detail:
            print('     ' + str(detail)[:700])


def sh(script, env=None, inp=None):
    return subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                          env=dict(os.environ, **(env or {})), input=inp)


# ------------------------------------------------ completion-event classifier
CASES = [
    ('~/.config/agent-watcher/update-status.sh 123 Complete', 'complete'),
    ('~/.config/agent-watcher/update-status.sh 123 Complete --blocked yes --reason "x"', 'block'),
    ('~/.config/agent-watcher/update-status.sh 123 Testing --blocked yes --reason x', 'block'),
    ('~/.config/agent-watcher/update-status.sh 123 Complete --blocked no', 'complete'),
    ('~/.config/agent-watcher/update-status.sh 123 Developing', 'status'),
    ('echo "update-status.sh 123 Complete"', ''),
    ('~/.cursor/skills/pr-create/scripts/pr-create.sh --title x', 'pr-create'),
    ('~/.config/agent-watcher/update-status.sh 999 Complete', ''),
]
for cmd, want in CASES:
    p = sh(f'source {AW}/hooks/lib/completion-event.sh; completion_event "$C" 123', {'C': cmd})
    check(f'classify [{want or "none"}]: {cmd[-45:]}', p.stdout.strip() == want, p.stdout + p.stderr)

# followup-scope gate: a blocked completion is not held to the GitHub counters
fake = tempfile.mkdtemp(prefix='dry-libs-')
os.makedirs(os.path.join(fake, '.config/agent-watcher'))
for d in ('hooks', 'lib'):
    os.symlink(os.path.join(AW, d), os.path.join(fake, '.config/agent-watcher', d))
GID = '9999999999996'
MARKER = f'/tmp/agent-followup-scope-{GID}.json'
json.dump({'newest_comment_at': '', 'agent_comments_after_watermark': 0, 'github_blocking_threads': 0,
           'github_unanswered_bodies': 0, 'github_bots_incomplete': 2}, open(MARKER, 'w'))
HOOK = os.path.join(AW, 'hooks/require-followup-scope-on-complete.sh')


def scope_gate(cmd):
    return subprocess.run(['bash', HOOK], input=json.dumps({'tool_input': {'command': cmd}}), capture_output=True,
                          text=True, env=dict(os.environ, HOME=fake, AGENT_TASK_GID=GID, ASANA_TOKEN=''))


p = scope_gate(f'~/.config/agent-watcher/update-status.sh {GID} Complete')
check('scope gate: plain Complete with bots incomplete is blocked by the bot gate', p.returncode == 2 and 'reviewer-bot' in p.stderr, p.stderr)
p = scope_gate(f'~/.config/agent-watcher/update-status.sh {GID} Complete --blocked yes --reason "bots red at budget"')
check('scope gate: blocked completion is not held to the bot count', p.returncode == 0, p.stderr)
os.remove(MARKER)

# ------------------------------------------------------------ agent marker def
texts = ['🥋 hi\n👊', ' 🥋 hi\n👊 \n', '\n🥋 multi\nline\n👊\n', 'plain', '🥋 open only', None, 'x\n👊']
p = subprocess.run(['jq', '-c', '-L', os.path.join(AW, 'lib'), 'include "agent-authored"; map(agent_authored)'],
                   input=json.dumps(texts), capture_output=True, text=True)
check('agent marker: whitespace-tolerant, needs both markers',
      p.stdout.strip() == '[true,true,true,false,false,false,false]', p.stdout + p.stderr)
p = sh(f'printf "%s" " 🥋 hi\n👊 " | {AW}/agent-authored-text.sh --check')
check('agent-authored-text.sh --check agrees with the jq def', p.returncode == 0, p.stderr)

# ---------------------------------------------------------- task field deltas
old = {'name': 't', 'completed': False, 'Priority': 'Low', 'TDD?': None, 'agent_on_complete': 'a', 'Status': 'x'}
new = {'name': 't', 'completed': False, 'Priority': 'High', 'TDD?': 'TDD', 'agent_on_complete': 'b'}
p = sh(f'source {AW}/lib/task-fields.sh; task_field_deltas "$O" "$N"', {'O': json.dumps(old), 'N': json.dumps(new)})
d = {x['field']: x for x in json.loads(p.stdout or '[]')}
check('field deltas: run parameter tagged', d.get('Priority', {}).get('run_param') is True, d)
check('field deltas: an ask is not tagged', d.get('TDD?', {}).get('run_param') is False, d)
check('field deltas: never_delta and foreign fields dropped', 'agent_on_complete' not in d and 'Status' not in d, d)

# -------------------------------------------------------- default branch order
t = tempfile.mkdtemp(prefix='dry-git-')
sh(f'''set -e; cd {t}; git init -q --bare remote.git; git init -q work; cd work
git commit -q --allow-empty -m init; git remote add origin ../remote.git
git push -q origin HEAD:develop HEAD:master''')
p = sh(f'git -C {t}/work symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null; {HOME}/.cursor/skills/git-default-branch.sh -C {t}/work')
check('default branch: asks the remote for origin/HEAD first', p.stdout.strip() in ('origin/develop', 'origin/master'), p.stdout + p.stderr)
sh(f'git -C {t}/work remote set-url origin /nonexistent; git -C {t}/work symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null')
p = sh(f'{HOME}/.cursor/skills/git-default-branch.sh -C {t}/work --short')
check('default branch offline: master before develop', p.stdout.strip() == 'master', p.stdout + p.stderr)

# ---------------------------------------------------------------- HACKED rule
p = sh(f'{HOME}/.cursor/skills/pr-create/scripts/hacked-frames.sh /tmp/agent-proof-1-01-HACKED-x.png /tmp/agent-proof-1-02-UNHACKED-y.png')
check('HACKED: whole token only', p.stdout.strip() == '/tmp/agent-proof-1-01-HACKED-x.png', p.stdout + p.stderr)

# ----------------------------------------------------------- judge log + root
jl = tempfile.mkdtemp(prefix='dry-judge-')
sh(f'. {AW}/lib/judge-log.sh; judge_log_override 42 complete bypass "operator comment" "bypass the judge" abc 2026-10-02T00:00:00Z',
   {'COMPLETION_JUDGE_LOG_DIR': jl})
row = json.loads(open(os.path.join(jl, '42.jsonl')).read())
check('override line carries every field', row['verdict'] == 'override' and row['source'] == 'operator comment'
      and row['evidence_hash'] == 'abc' and row['comment_at'] and row['nonce'] == 'override', row)
p = sh(f'. {AW}/lib/worktree-root.sh; task_worktree 7', {'AGENT_WORKTREE_ROOT': '/x/wt'})
q = subprocess.run(['node', '-e', f'console.log(require("{AW}/lib/worktree-root.js").worktreeRoot())'],
                   capture_output=True, text=True, env=dict(os.environ, AGENT_WORKTREE_ROOT='/x/wt'))
check('worktree root: env wins, bash and JS agree', p.stdout.strip() == '/x/wt/7' and q.stdout.strip() == '/x/wt', p.stdout + q.stdout)

print(f'\n{fails} failure(s)')
sys.exit(1 if fails else 0)
