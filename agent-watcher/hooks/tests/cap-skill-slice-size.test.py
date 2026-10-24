#!/usr/bin/env python3
"""Contract test for cap-skill-slice-size.sh (the 20k cap on split skills).

Run: python3 ~/.config/agent-watcher/hooks/tests/cap-skill-slice-size.test.py

A throwaway HOME holds a fake ~/.cursor/skills tree and a ~/.claude/skills
symlink to it; SKILL_SLICE_LIMIT is set to 100 so the cases stay small. Every
vector is piped as a synthetic hook payload.
"""
import json
import os
import subprocess
import sys
import tempfile

HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/cap-skill-slice-size.sh')
LIB = os.path.expanduser('~/.config/agent-watcher/hooks/lib/skill-slice-size.js')
fails = []

home = tempfile.mkdtemp(prefix='slice-cap-')
skills = os.path.join(home, '.cursor', 'skills')
for d in ['one-shot/references', 'pr-land/references', 'build-and-test/references', 'other']:
    os.makedirs(os.path.join(skills, d))
os.makedirs(os.path.join(home, '.config', 'agent-watcher', 'hooks', 'lib'))
os.symlink(LIB, os.path.join(home, '.config', 'agent-watcher', 'hooks', 'lib', 'skill-slice-size.js'))
os.makedirs(os.path.join(home, '.claude'))
os.symlink(skills, os.path.join(home, '.claude', 'skills'))


def put(rel, n):
    p = os.path.join(skills, rel)
    open(p, 'w').write('x' * n)
    return p


DRIVE = put('build-and-test/references/drive.md', 90)
PLAYBOOK = put('build-and-test/references/sim-testing-playbook.md', 90)
CORE = put('pr-land/SKILL.md', 90)
OVER = put('one-shot/references/landing.md', 150)
OTHER = put('other/SKILL.md', 90)
ENV = dict(os.environ, HOME=home, SKILL_SLICE_LIMIT='100')


def run(payload):
    p = subprocess.run(['bash', HOOK], input=json.dumps(payload), capture_output=True, text=True, env=ENV)
    return p.returncode, p.stderr


def pre(tool, **ti):
    return run({'hook_event_name': 'PreToolUse', 'tool_name': tool, 'tool_input': ti})


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (': ' + detail if detail and not cond else ''))
    if not cond:
        fails.append(name)


rc, err = pre('Write', file_path=DRIVE, content='y' * 100)
check('Write to a capped slice at the cap -> deny naming the file and sizes', rc == 2 and 'build-and-test/references/drive.md would be 100' in err and 'it is 90 now' in err, f'rc={rc} {err[:200]}')
rc, _ = pre('Write', file_path=DRIVE, content='y' * 99)
check('Write to a capped slice just under the cap -> allow', rc == 0)
rc, err = pre('Write', file_path=os.path.join(skills, 'pr-land/references/new.md'), content='y' * 120)
check('Write creating a new capped slice over the cap -> deny', rc == 2 and 'pr-land/references/new.md' in err, f'rc={rc}')
rc, _ = pre('Write', file_path=PLAYBOOK, content='y' * 500)
check('Write to the uncapped playbook -> allow', rc == 0)
rc, _ = pre('Write', file_path=OTHER, content='y' * 500)
check('Write to a skill that is not split -> allow', rc == 0)
rc, _ = pre('Write', file_path=os.path.join(home, '.claude', 'skills', 'build-and-test', 'references', 'drive.md'), content='y' * 100)
check('Write through the ~/.claude/skills alias -> deny', rc == 2)
rc, _ = pre('Write', file_path='~/.cursor/skills/pr-land/SKILL.md', content='y' * 100)
check('Write with a ~ path -> deny', rc == 2)

rc, err = pre('Edit', file_path=CORE, old_string='xxxxx', new_string='xxxxxyyyyyyyyyy')
check('Edit growing a capped core past the cap -> deny', rc == 2 and 'pr-land/SKILL.md would be 100' in err, f'rc={rc} {err[:200]}')
rc, _ = pre('Edit', file_path=CORE, old_string='xxxxx', new_string='xxxxxyyyyy')
check('Edit growing a capped core to just under the cap -> allow', rc == 0)
rc, _ = pre('Edit', file_path=CORE, old_string='x', new_string='xx', replace_all=True)
check('Edit with replace_all counts every replacement -> deny', rc == 2)
rc, _ = pre('Edit', file_path=OVER, old_string='xxxxxxxxxx', new_string='')
check('Edit shrinking a file already over the cap -> allow', rc == 0)
rc, _ = pre('Edit', file_path=OVER, old_string='xxxxxxxxxx', new_string='xxxxxxxxxxx')
check('Edit growing a file already over the cap -> deny', rc == 2)
rc, _ = pre('Edit', file_path=CORE, old_string='not in the file', new_string='y' * 500)
check('Edit whose old_string is absent -> allow (the Edit fails on its own)', rc == 0)
rc, _ = pre('Edit', file_path=os.path.join(skills, 'one-shot/references/missing.md'), old_string='a', new_string='b')
check('Edit of a capped path that does not exist -> allow', rc == 0)


def post(cmd):
    return run({'hook_event_name': 'PostToolUse', 'tool_name': 'Bash', 'tool_input': {'command': cmd}})


rc, err = post('python3 edit.py ~/.cursor/skills/one-shot/references/landing.md')
check('Bash naming a capped file left over the cap -> exit 2 with the overage', rc == 2 and 'one-shot/references/landing.md (150)' in err, f'rc={rc} {err[:200]}')
rc, _ = post('ls ~/.cursor/skills')
check('Bash not naming the over-cap file -> quiet', rc == 0)
rc, _ = post('sed -i "" s/a/b/ ~/.cursor/skills/build-and-test/references/drive.md')
check('Bash naming a capped file under the cap -> quiet', rc == 0)
rc, _ = run({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'echo landing.md one-shot'}})
check('PreToolUse Bash -> no-op', rc == 0)
rc, _ = run({})
check('empty payload -> allow', rc == 0)
p = subprocess.run(['bash', HOOK], input='not json', capture_output=True, text=True, env=ENV)
check('malformed payload -> allow', p.returncode == 0)

print('\nall passed' if not fails else '\n%d failed' % len(fails))
sys.exit(1 if fails else 0)
