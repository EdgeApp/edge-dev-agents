#!/usr/bin/env python3
"""Contract tests for no-slop-lint.sh --strings and the locale vector of
lint-md-on-write.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/lint-locale-strings.test.py

Operator ruling 2026-09-07: user-facing copy (edge-react-gui src/locales/en_US.ts,
edge-login-ui-rn src/common/locales/strings/enUS.json) is outward prose. Only the
quoted VALUES are linted; keys, comments and code never are. Write, Edit and Bash
writes to those paths are gated; any other .ts/.json path is untouched.
"""
import json, os, subprocess, sys, tempfile

LINT = os.path.expanduser('~/.cursor/skills/no-slop/scripts/no-slop-lint.sh')
HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/lint-md-on-write.sh')
GUI = os.path.expanduser('~/git/edge-react-gui/src/locales/en_US.ts')
LUI = os.path.expanduser('~/git/edge-login-ui-rn/src/common/locales/strings/enUS.json')
fails = []
def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)

def lint(text, suffix, *flags):
    with tempfile.NamedTemporaryFile('w', suffix=suffix, delete=False) as fh:
        fh.write(text); path = fh.name
    p = subprocess.run([LINT, path, '--strings', *flags], capture_output=True, text=True)
    os.remove(path)
    return p.returncode, p.stdout

def hook(tool, payload, cwd='/Users/eddy/git/edge-react-gui'):
    p = subprocess.run([HOOK], input=json.dumps({'tool_name': tool, 'tool_input': payload, 'cwd': cwd}),
                       capture_output=True, text=True, timeout=60)
    return p.returncode, p.stderr

rc, out = lint('export const strings = {\n  // comment — not prose\n  ok: `Your funds are on the way.`,\n}\n', '.ts')
check('ts: comment em dash ignored, clean value passes', rc == 0, out)
rc, out = lint('  bad: `Swap complete — funds arrive soon`,\n', '.ts', '--fragment')
check('ts: em dash in a value is HARD (fragment mode)', rc == 1 and 'em dash' in out, out)
rc, out = lint("  bad: 'A seamless experience for users',\n", '.ts', '--fragment')
check('ts: banned vocabulary in a single-quoted value', rc == 1 and 'seamless' in out, out)
rc, out = lint('  "access_confirmation_title": "Access Confirmation",\n  "x": "Say \\"hi\\" and \\nwait — now",\n', '.json', '--fragment')
check('json: escapes unfolded, em dash caught on line 2', rc == 1 and 'HARD 2' in out, out)
rc, out = lint('  key_with_dash: `Sending %1$s — please wait`,\n', '.ts', '--fragment')
check('placeholder values still lint', rc == 1 and 'em dash' in out, out)

rc, err = hook('Edit', {'file_path': GUI, 'old_string': 'x', 'new_string': '  new_key: `Swap complete — funds arrive soon`,\n'})
check('hook: Edit of gui en_US.ts with an em dash is blocked', rc == 2 and 'user-facing copy' in err, f'rc={rc} {err[:160]}')
rc, err = hook('Edit', {'file_path': GUI, 'old_string': 'x', 'new_string': '  new_key: `Your funds are on the way.`,\n'})
check('hook: clean Edit of gui en_US.ts passes', rc == 0, f'rc={rc} {err[:160]}')
rc, err = hook('Edit', {'file_path': LUI, 'old_string': 'x', 'new_string': '  "new_key": "Set up your account in order to continue",\n'})
check('hook: Edit of login-ui enUS.json with banned vocabulary is blocked', rc == 2 and 'in order to' in err, f'rc={rc} {err[:160]}')
rc, err = hook('Edit', {'file_path': os.path.expanduser('~/git/edge-react-gui/src/components/Foo.tsx'), 'old_string': 'x', 'new_string': 'const s = `seamless — really`\n'})
check('hook: a non-locale .tsx edit is untouched', rc == 0, f'rc={rc} {err[:160]}')
rc, err = hook('Bash', {'command': "sed -i '' 's/^/  k: `Swap complete — soon`,/' src/locales/en_US.ts"})
check('hook: Bash sed -i on en_US.ts is blocked (plain fragment lint of the command)', rc == 2 and 'em dash' in err, f'rc={rc} {err[:160]}')
rc, err = hook('Write', {'file_path': GUI, 'content': open(GUI).read() + '  new_key: `A seamless flow`,\n'})
check('hook: Write over the existing file lints only the added value', rc == 2 and 'seamless' in err and 'in order to' not in err, f'rc={rc} {err[:200]}')
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed'); sys.exit(1 if fails else 0)
