#!/usr/bin/env python3
"""Contract tests for the operator hold.

Run: python3 ~/.config/agent-watcher/hooks/tests/operator-hold.test.py

Two tiers. GRAMMAR: hooks/lib/operator-directives.sh is a pure function, so every
phrasing runs in ONE bash process against a table (no hook fork, no stamp).
BEHAVIOR: one forked case per hook/gate behavior (set, release, stop order, machine
prompt, headless child, gate block/allow, stop hook stand-down).
"""
import json, os, shutil, subprocess, sys, tempfile

AW = os.path.expanduser('~/.config/agent-watcher')
GID = '7777777777'
STAMP = f'/tmp/agent-operator-hold-{GID}'
WAIVER = f'/tmp/agent-judge-waiver-{GID}'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


# ---------------- GRAMMAR (one process) ----------------
# phrase -> expected: "hold" | "release" | "release complete" | "stop" | "bypass"
GRAMMAR = [
    # leading / trailing bare anchors
    ('go', 'release'), ('ok go', 'release'), ('Yes, proceed', 'release'), ('GO: looks good', 'release'),
    ('resume, and fix X when you are done', 'release'), ('check the fee row again and resume', 'release'),
    ('lgtm, continue', 'release'), ('looks good, go ahead', 'release'), ('fix X and then resume.', 'release'),
    ('ship the fixup; proceed', 'release'), ('try the other token too, then go', 'release'),
    ('the row looks wrong, complete.', 'release complete'),
    # completion directives (first or last sentence or last clause)
    ('Complete the task', 'release complete'), ('Looks fine. Complete the task.', 'release complete'),
    ('Looks fine, complete the task.', 'release complete'), ('please finish up', 'release complete'),
    ('ship it', 'release complete'), ('Wrap it up and attach the report.', 'release complete'),
    ('Set it to complete, QA is happy', 'release complete'), ('The row is fine now. Go ahead and finish.', 'release complete'),
    ('fix the fee row and then finish up', 'release complete'),
    # stop directives
    ('stop the task', 'stop'), ('Stop the run and write up where you got to.', 'stop'),
    ('Set it to blocked, QA will handle it', 'stop'), ('kill the task', 'stop'), ('ok stop here', 'stop'),
    ('Nothing more to do; end the run.', 'stop'),
    # bypass grants
    ('You have approval to bypass the completion judge after this point', 'bypass'),
    ('Skip the judge and complete the task', 'bypass'),
    # holds: negations, conditions, non-bare verbs, interrupts, questions
    ('yes do it', 'hold'), ('approved', 'hold'), ('no, hold on', 'hold'), ('what does the fee row show?', 'hold'),
    ("don't complete yet", 'hold'), ('not ready to complete, QA found another case', 'hold'),
    ('wait before you finish', 'hold'), ('mark it complete when QA signs off', 'hold'),
    ('the task is complete once QA signs off', 'hold'), ('complete garbage, the fee is wrong', 'hold'),
    ('Stop, I am going to let QA finish testing', 'hold'), ('stop', 'hold'), ('that continue button is wrong', 'hold'),
    ('do not continue', 'hold'), ("fix X and don't continue", 'hold'), ('never go ahead without asking', 'hold'),
    ("don't stop the task yet", 'hold'), ('stop the sim, not the task', 'hold'), ('please do not skip the judge', 'hold'),
]
table = '\n'.join(f'{p}\t{e}' for p, e in GRAMMAR)
script = r'''
. "$1/hooks/lib/operator-directives.sh"
while IFS=$'\t' read -r phrase expect; do
  anchor=$(printf '%s' "$phrase" | release_anchor); kinds=$(printf '%s' "$phrase" | directive_kinds)
  got=hold
  case " $kinds " in *" bypass "*) got=bypass ;; *" stop "*) got=stop ;; *" complete "*) got="release complete" ;;
    *) case "$anchor" in "release complete") got="release complete" ;; release) got=release ;; esac ;; esac
  printf '%s\t%s\t%s\n' "$phrase" "$expect" "$got"
done
'''
p = subprocess.run(['bash', '-c', script, '_', AW], input=table + '\n', capture_output=True, text=True)
rows = [l.split('\t') for l in p.stdout.strip().splitlines()]
check(f'grammar: {len(GRAMMAR)} phrasings evaluated in one process', len(rows) == len(GRAMMAR), p.stderr[:200])
for phrase, expect, got in rows:
    check(f'grammar: {phrase!r} -> {expect}', got == expect, f'got {got}')

# ---------------- BEHAVIOR (one forked case each) ----------------
tmp = tempfile.mkdtemp(prefix='hold-')
home = os.path.join(tmp, 'home')
os.makedirs(os.path.join(home, '.config/agent-watcher/hooks'))
os.symlink(os.path.join(AW, 'operator-hold.sh'), os.path.join(home, '.config/agent-watcher/operator-hold.sh'))
for f in ('operator-hold-prompt.sh', 'operator-hold-gate.sh', 'strip-cmd-mentions.sh', 'cmd-executes.sh', 'lib'):
    os.symlink(os.path.join(AW, 'hooks', f), os.path.join(home, '.config/agent-watcher/hooks', f))
ENV = dict(os.environ, HOME=home, AGENT_TASK_GID=GID)
HOOK = os.path.join(home, '.config/agent-watcher/hooks/operator-hold-prompt.sh')


def prompt(text, env=ENV):
    return subprocess.run([HOOK], input=json.dumps({'prompt': text}), capture_output=True, text=True, env=env).stdout


def held():
    return os.path.exists(STAMP)


def gate(cmd):
    return subprocess.run([os.path.join(home, '.config/agent-watcher/hooks/operator-hold-gate.sh')],
                          input=json.dumps({'tool_input': {'command': cmd}}), capture_output=True, text=True, env=ENV).returncode


def clear():
    for f in (STAMP, WAIVER, f'/tmp/agent-operator-present-{GID}'):
        try: os.remove(f)
        except FileNotFoundError: pass


try:
    clear()
    out = prompt('what does the fee row show?')
    check('human prompt sets the hold + steering context', held() and 'steering' in out, out[:60])
    out = prompt('looks good, go ahead')
    check('release prompt clears the hold + released context, no waiver', (not held()) and 'released' in out and not os.path.exists(WAIVER), out[:60])
    out = prompt('Complete the task')
    check('completion directive releases AND writes a standing judge waiver', (not held()) and os.path.exists(WAIVER) and 'operator-directed complete' in open(WAIVER).read())
    clear()
    out = prompt('stop the task')
    check('stop directive keeps the hold, injects the block-now context, writes the waiver', held() and 'stop directive' in out and '--blocked yes' in out and 'operator-directed stop' in open(WAIVER).read(), out[:80])
    clear()
    out = prompt('<task-notification>\n<task-id>abc</task-id>\n<status>completed</status>\n</task-notification>')
    check('machine prompt stamps nothing, prints nothing', (not held()) and out == '', out[:60])
    out = prompt('<operator-hold-expired>')
    check('hold-expiry resume prompt stamps nothing (machine text)', (not held()) and out == '', out[:60])
    out = prompt('<watchdog-dialog-declined>')
    check('dialog-declined resume prompt stamps nothing (machine text)', (not held()) and out == '', out[:60])
    # headless child: a renamed bash with " -p " in argv runs the hook as its CHILD
    p = subprocess.run(['bash', '-c', 'exec -a "$0" bash -c \'"$HOOK"; exit $?\' claude "$@"', os.path.join(tmp, 'claude'), '-p', '--model', 'haiku'],
                       input=json.dumps({'prompt': 'judge this: update, then resume'}), capture_output=True, text=True, env=dict(ENV, HOOK=HOOK))
    check('headless claude -p child stamps nothing', (not held()) and p.stdout == '', p.stdout[:60])
    p = subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'status', GID], capture_output=True, text=True)
    check('oracle: clear -> exit 1', p.returncode == 1 and p.stdout.strip() == 'clear')
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'set', GID]); os.utime(STAMP, (0, 0))
    p = subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'status', GID], capture_output=True, text=True)
    check('oracle: an old stamp is still held (the oracle has no clock; the watchdog expires it)', p.returncode == 0 and p.stdout.startswith('held'))
    check('gate: blocks a push while held', gate('cd /r && git push --force-with-lease origin br') == 2)
    check('gate: allows an operator-directed block while held', gate(f'~/.config/agent-watcher/update-status.sh {GID} Testing --blocked yes --reason x') == 0)
    check('gate: allows a read while held', gate('git status') == 0)
    real = dict(os.environ, AGENT_TASK_GID=GID)
    count = f'/tmp/agent-stop-block-count-{GID}'
    try: os.remove(count)
    except FileNotFoundError: pass
    p = subprocess.run([os.path.join(AW, 'hooks/require-continuation-or-block.sh')], input='{}', capture_output=True, text=True, env=real, timeout=60)
    check('stop hook stands down while held', p.returncode == 0 and p.stdout.strip() == '' and not os.path.exists(count), f'rc={p.returncode}')
    subprocess.run([os.path.join(AW, 'operator-hold.sh'), 'release', GID])
    check('gate: allows a push once released', gate('git push origin br') == 0)
finally:
    clear()
    shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
