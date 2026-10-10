#!/usr/bin/env python3
"""Contract test for build-and-test/scripts/lib/native-app-cache.sh.

Run: python3 ~/.config/agent-watcher/hooks/tests/native-app-cache.test.py

Key half: two trees with the same native inputs share a key whatever their JS
differs in; any native input (pods lock, committed ios/ source, a patch, an
embedded webview asset) changes it; a tree with uncommitted native source has
no key, and a Podfile.lock whose hermes-engine line a build rewrote still has
the clean tree's key.

Store half: put then get returns the bundle, a miss prints nothing, a second
put replaces the entry, and trim keeps the most recently used entries.
"""
import os
import subprocess
import sys
import tempfile
import time

LIBDIR = os.path.expanduser('~/.cursor/skills/build-and-test/scripts/lib')
fails = []
HERMES_A = '  hermes-engine: ' + 'a' * 40
HERMES_B = '  hermes-engine: ' + 'b' * 40


def check(cond, msg):
    if not cond:
        fails.append(msg)


def sh(script, cwd=None, env=None):
    full = 'source "%s/native-deps-hash.sh"; source "%s/native-app-cache.sh"; %s' % (LIBDIR, LIBDIR, script)
    e = dict(os.environ)
    e.update(env or {})
    r = subprocess.run(['bash', '-c', full], cwd=cwd, capture_output=True, text=True, env=e)
    return r.stdout.strip()


def git(repo, *args):
    subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True, check=True)


def write(repo, rel, text):
    path = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'w').write(text)


def make_repo():
    repo = tempfile.mkdtemp()
    git(repo, 'init', '-q', '-b', 'develop', '.')
    git(repo, 'config', 'user.email', 't@example.com')
    git(repo, 'config', 'user.name', 't')
    git(repo, 'config', 'commit.gpgsign', 'false')
    write(repo, '.gitignore', 'node_modules\n')
    write(repo, 'ios/Podfile.lock', 'PODS:\n  - A (1.0)\nSPEC CHECKSUMS:\n' + HERMES_A + '\n')
    write(repo, 'ios/app/AppDelegate.swift', 'let a = 1\n')
    write(repo, 'patches/mod+1.0.0.patch', 'patch one\n')
    write(repo, 'src/index.ts', 'export const x = 1\n')
    write(repo, 'node_modules/edge-core/android/src/main/assets/core.js', 'core v1\n')
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m', 'base')
    return repo


def commit(repo, msg='change'):
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m', msg)


def key(repo):
    return sh('native_app_cache_key .', cwd=repo)


# --- key half ------------------------------------------------------------------
a = make_repo()
k = key(a)
check(len(k) == 16 + 1 + 12 and k.count('-') == 1, 'clean tree: want <stamp>-<source>, got %r' % k)
check(key(a) == k, 'key is stable across calls')

b = make_repo()
check(key(b) == k, 'an identical second tree shares the key')
write(b, 'src/index.ts', 'export const x = 2\n')
check(key(b) == k, 'an uncommitted JS change keeps the key')
commit(b)
write(b, 'src/other.ts', 'export const y = 1\n')
commit(b)
check(key(b) == k, 'committed JS changes keep the key')

write(b, 'ios/Podfile.lock', 'PODS:\n  - A (1.0)\nSPEC CHECKSUMS:\n' + HERMES_B + '\n')
check(key(b) == k, 'a build-rewritten hermes line keeps the clean key')
write(b, 'ios/Podfile.lock', 'PODS:\n  - A (2.0)\nSPEC CHECKSUMS:\n' + HERMES_A + '\n')
check(key(b) not in ('', k), 'a moved pod changes the key (uncommitted lock change still keyed)')
git(b, 'checkout', '--', 'ios/Podfile.lock')

write(b, 'ios/app/AppDelegate.swift', 'let a = 2\n')
check(key(b) == '', 'uncommitted ios source: no key')
commit(b)
check(key(b) not in ('', k), 'committed ios source: a different key')

c = make_repo()
write(c, 'ios/app/New.swift', 'let n = 1\n')
check(key(c) == '', 'untracked ios file: no key')
os.remove(os.path.join(c, 'ios/app/New.swift'))
write(c, 'patches/mod+1.0.0.patch', 'patch two\n')
check(key(c) == '', 'uncommitted patch: no key')
commit(c)
check(key(c) not in ('', k), 'committed patch: a different key')

e = make_repo()
write(e, 'node_modules/edge-core/android/src/main/assets/core.js', 'core v2\n')
check(key(e) not in ('', k), 'a different embedded webview asset changes the key')

check(sh('native_app_cache_key .', cwd=tempfile.mkdtemp()) == '', 'not a git repo: no key')

# --- store half ----------------------------------------------------------------
cache = tempfile.mkdtemp()
env = {'NATIVE_APP_CACHE_DIR': cache, 'NATIVE_APP_CACHE_KEEP': '3'}
BID = 'co.example.app'


def app(tag):
    d = tempfile.mkdtemp()
    p = os.path.join(d, 'Edge.app')
    os.makedirs(p)
    open(os.path.join(p, 'Info.plist'), 'w').write(tag)
    open(os.path.join(p, 'Edge'), 'w').write('binary ' + tag)
    return p


check(sh('native_app_cache_get %s k1' % BID, env=env) == '', 'miss prints nothing')
sh('native_app_cache_put %s k1 "%s" "note one"' % (BID, app('one')), env=env)
got = sh('native_app_cache_get %s k1' % BID, env=env)
check(got == os.path.join(cache, BID, 'k1', 'Edge.app') and open(got + '/Info.plist').read() == 'one',
      'put then get returns the stored bundle, got %r' % got)
check(open(os.path.join(cache, BID, 'k1', 'built-from')).read().strip() == 'note one', 'the note is kept')
sh('native_app_cache_put %s k1 "%s"' % (BID, app('one-b')), env=env)
check(open(sh('native_app_cache_get %s k1' % BID, env=env) + '/Info.plist').read() == 'one-b', 'a second put replaces')
check(sh('native_app_cache_put %s "" "%s"; echo rc=$?' % (BID, app('x')), env=env) == 'rc=1', 'empty key stores nothing')
check(sh('native_app_cache_put %s k9 /nonexistent.app; echo rc=$?' % BID, env=env) == 'rc=1', 'missing bundle stores nothing')
check(sh('native_app_cache_get other.bundle k1', env=env) == '', 'entries are per bundle id')

now = time.time()
for i, name in enumerate(['k2', 'k3', 'k4']):
    sh('native_app_cache_put %s %s "%s"' % (BID, name, app(name)), env=env)
for i, name in enumerate(['k1', 'k2', 'k3', 'k4']):
    p = os.path.join(cache, BID, name)
    if os.path.isdir(p):
        os.utime(p, (now - 1000 + i * 100, now - 1000 + i * 100))
sh('native_app_cache_get %s k2 >/dev/null' % BID, env=env)   # k2 becomes the most recently used
sh('native_app_cache_put %s k5 "%s"' % (BID, app('k5')), env=env)
left = sorted(n for n in os.listdir(os.path.join(cache, BID)) if not n.startswith('.'))
check(left == ['k2', 'k4', 'k5'], 'trim keeps the 3 most recently used, got %s' % left)

if fails:
    print('FAIL (%d)' % len(fails))
    for f in fails:
        print('  - ' + f)
    sys.exit(1)
print('PASS (13 key cases, 9 store cases)')
