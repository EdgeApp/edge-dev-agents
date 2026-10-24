#!/usr/bin/env python3
"""set-tested.sh keeps earlier credit: the written value is the union of the
current field and the options passed, a credited method leaves only through
--drop/--clear with --reason, and Untested never overwrites a real credit.
SET_TESTED_CURRENT stands in for the Asana read; --dry-run skips the write, so
nothing here touches Asana."""
import json, os, subprocess, sys

SCRIPT = os.path.expanduser('~/.config/agent-watcher/set-tested.sh')
CONFIG = os.path.expanduser('~/.config/agent-watcher/asana-config.json')
OPTS = json.load(open(CONFIG))['custom_fields']['tested']['options']
fails = 0


def run(current, *args):
    env = dict(os.environ, SET_TESTED_CURRENT=current)
    p = subprocess.run([SCRIPT, '123', *args, '--dry-run'], env=env,
                       capture_output=True, text=True, timeout=30)
    payload = None
    out = p.stdout
    if '{' in out:
        payload = json.loads(out[out.index('{'):])
    return p.returncode, payload, p.stdout + p.stderr


def written(payload):
    if payload is None:
        return None
    vals = list(payload['data']['custom_fields'].values())[0]
    names = {v: k for k, v in OPTS.items()}
    return sorted(names[g] for g in vals)


def check(name, got, want):
    global fails
    ok = got == want
    fails += not ok
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else f': got {got!r}, want {want!r}'))


rc, pl, _ = run('iOS Sim,Unit Tests', 'Unit Tests')
check('no-code followup passing less keeps the earlier drive', (rc, written(pl)), (0, ['Unit Tests', 'iOS Sim']))

rc, pl, err = run('iOS Sim', 'Untested')
check('Untested over a real credit exits 2', (rc, pl), (2, None))
check('the refusal names the credit it would erase', 'iOS Sim' in err, True)

rc, pl, out = run('iOS Sim', 'Untested', '--drop', 'iOS Sim', '--reason', 'code changed after the drive')
check('an explicit drop with a reason replaces the credit', (rc, written(pl)), (0, ['Untested']))
check('dry-run reports what was dropped', 'dropped=[iOS Sim]' in out, True)

rc, pl, _ = run('iOS Sim', 'Unit Tests', '--drop', 'iOS Sim')
check('--drop without --reason exits 2', (rc, pl), (2, None))

rc, pl, _ = run('iOS Sim', '--clear')
check('--clear without --reason exits 2', (rc, pl), (2, None))

rc, pl, _ = run('iOS Sim', '--clear', '--reason', 'drive was on the wrong build')
check('--clear with a reason empties the field', (rc, written(pl)), (0, []))

rc, pl, _ = run('Untested', 'Unit Tests')
check('a real method replaces an earlier Untested', (rc, written(pl)), (0, ['Unit Tests']))

rc, pl, _ = run('', 'iOS Sim')
check('an empty field takes the passed method', (rc, written(pl)), (0, ['iOS Sim']))

rc, pl, _ = run('', 'Untested', 'Unit Tests')
check('Untested combined with a real method exits 2', (rc, pl), (2, None))

rc, pl, _ = run('iOS Sim', 'Bogus')
check('an unknown option exits 2', (rc, pl), (2, None))

rc, pl, _ = run('iOS Sim', '--drop', 'Unit Tests', '--reason', 'x')
check('dropping a method that is not credited changes nothing', (rc, written(pl)), (0, ['iOS Sim']))

print('\nall passed' if not fails else f'\n{fails} failed')
sys.exit(1 if fails else 0)
