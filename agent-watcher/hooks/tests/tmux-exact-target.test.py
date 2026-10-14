#!/usr/bin/env python3
"""Contract test: every tmux target that names a session uses the exact-match form.

A bare `-t name` is a prefix match in tmux: `kill-session -t claude-asana-12` kills
`claude-asana-123` when `claude-asana-12` is gone. The exact form differs by command:
  - session targets (has-session, kill-session, rename-session, attach, switch-client)
    take `=name`
  - pane or window targets (send-keys, capture-pane, display-message, paste-buffer,
    list-panes with or without -s) take `=name:`; `=name` alone finds no pane, and
    list-panes -s falls back to a prefix match on it
Targets that hold a pane id ($TMUX_PANE, $PANE) are already exact and stay bare.

Part 1 reads every shell and node script under ~/.cursor and ~/.config/agent-watcher
and fails on a session-name target in the wrong form. Part 2 runs both forms against a
private tmux server (its own socket dir) to prove this tmux resolves them as stated.

Run: python3 ~/.config/agent-watcher/hooks/tests/tmux-exact-target.test.py
"""
import os, re, shutil, subprocess, sys, tempfile

HOME = os.path.expanduser('~')
ROOTS = [os.path.join(HOME, '.cursor'), os.path.join(HOME, '.config', 'agent-watcher')]
PRUNE = {'node_modules', 'tests', '.git', 'logs', 'state', 'cache'}
SESSION = {'has-session', 'kill-session', 'rename-session', 'switch-client', 'attach', 'attach-session'}
PANE = {'send-keys', 'capture-pane', 'display-message', 'display', 'paste-buffer'}
PANE_ID = re.compile(r'^\$\{?(TMUX_PANE|PANE)\b')
CALL = re.compile(r"""tmux\s+([a-z-]+)((?:(?![|;&]|\btmux\b).)*?)-t\s+(["']?)([^"'\s)`]+(?:\{[^}]*\}[^"'\s)`]*)*)""")
ARGV = re.compile(r"""\[\s*'([a-z-]+)',\s*'-t',\s*([^\]\s,]+)""")

fails = 0


def check(name, cond, detail=''):
    global fails
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else '  ' + str(detail)))
    if not cond:
        fails += 1


bad, seen = [], 0
for root in ROOTS:
    for d, dirs, files in os.walk(root, followlinks=True):
        dirs[:] = [x for x in dirs if x not in PRUNE]
        for fn in files:
            if not fn.endswith(('.sh', '.js')):
                continue
            p = os.path.join(d, fn)
            try:
                lines = open(p, errors='replace').read().split('\n')
            except OSError:
                continue
            for i, ln in enumerate(lines, 1):
                if ln.lstrip().startswith(('#', '//')):
                    continue
                for cmd, mid, _q, tgt in CALL.findall(ln):
                    if PANE_ID.match(tgt):
                        continue
                    session = cmd in SESSION
                    if not session and cmd not in PANE and cmd != 'list-panes':
                        continue
                    seen += 1
                    ok = tgt.startswith('=') and (not tgt.endswith(':') if session else tgt.endswith(':'))
                    if not ok:
                        bad.append(f'{p}:{i} {cmd} -t {tgt}')
                for cmd, tgt in ARGV.findall(ln):
                    seen += 1
                    if '=' not in tgt[:3]:
                        bad.append(f'{p}:{i} {cmd} -t {tgt}')
check('the scan found the tmux call sites', seen > 50, f'only {seen} sites seen')
check('no session-name target is a prefix match', not bad, '\n     ' + '\n     '.join(bad[:15]))

if not shutil.which('tmux'):
    print('skip tmux not installed: the live half did not run')
else:
    tmp = tempfile.mkdtemp(prefix='tmux-exact.')
    env = dict(os.environ, TMUX_TMPDIR=tmp)
    env.pop('TMUX', None)

    def t(*a):
        p = subprocess.run(['tmux', '-f', '/dev/null', *a], capture_output=True, text=True, env=env)
        return p.returncode, (p.stdout + p.stderr).strip()
    try:
        # The sibling whose name starts with the absent session's name.
        t('new-session', '-d', '-s', 'claude-asana-123', '-x', '80', '-y', '24')
        check('a bare target is a prefix match on this tmux (the hazard)', t('has-session', '-t', 'claude-asana-12')[0] == 0)
        check('has-session =name misses the sibling', t('has-session', '-t', '=claude-asana-12')[0] != 0)
        check('has-session =name finds the session itself', t('has-session', '-t', '=claude-asana-123')[0] == 0)
        check('list-panes -s =name still prefix-matches (why it takes the colon)', t('list-panes', '-s', '-t', '=claude-asana-12')[0] == 0)
        check('list-panes -s =name: misses the sibling', t('list-panes', '-s', '-t', '=claude-asana-12:')[0] != 0)
        check('list-panes -s =name: lists the session itself', t('list-panes', '-s', '-t', '=claude-asana-123:', '-F', '#{pane_pid}')[1].isdigit())
        for cmd in (['send-keys', '-t', '=claude-asana-12:', 'x'], ['capture-pane', '-p', '-t', '=claude-asana-12:'],
                    ['list-panes', '-t', '=claude-asana-12:'], ['paste-buffer', '-t', '=claude-asana-12:']):
            check(f'{cmd[0]} =name: misses the sibling', t(*cmd)[0] != 0)
        check('display-message =name: prints nothing for the sibling', t('display-message', '-p', '-t', '=claude-asana-12:', '#{session_name}')[1] == '')
        for cmd in (['send-keys', '-t', '=claude-asana-123:', ''], ['capture-pane', '-p', '-t', '=claude-asana-123:'],
                    ['list-panes', '-t', '=claude-asana-123:']):
            rc, out = t(*cmd)
            check(f'{cmd[0]} =name: reaches the session itself', rc == 0, out)
        check('display-message =name: reads the session itself', t('display-message', '-p', '-t', '=claude-asana-123:', '#{session_name}')[1] == 'claude-asana-123')
        check('send-keys =name without the colon finds no pane', t('send-keys', '-t', '=claude-asana-123', '')[0] != 0)
        t('kill-session', '-t', '=claude-asana-12')
        check('kill-session =name leaves the sibling alive', t('has-session', '-t', '=claude-asana-123')[0] == 0)
        rc, out = t('rename-session', '-t', '=claude-asana-12', 'done-asana-12')
        check('rename-session =name does not rename the sibling', rc != 0 and t('has-session', '-t', '=claude-asana-123')[0] == 0, out)
    finally:
        t('kill-server')
        shutil.rmtree(tmp, ignore_errors=True)

print(f'\n{fails} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
