#!/usr/bin/env python3
"""Routing test for /pr-review's feature loader and the --features tag check.

Run: python3 ~/.config/agent-watcher/hooks/tests/pr-review-feature-routing.test.py
     (or run.sh pr-review-feature-routing)

Covers feature-routing.rb (glob matching, statuses, rule scope, schema errors,
base-ref reads through --git) and github-pr-review.sh render --features (feature
rule ids and lenses are valid tags only with the manifest). Fixture tree:
fixtures/pr-review-features/ (lenses.yaml, demo/features.yaml, demo/*.rules.yaml).
No network: route runs on --root and --git sources, and render makes no GitHub call.
"""
import json, os, shutil, subprocess, sys, tempfile

SKILL = os.path.expanduser('~/.cursor/skills/pr-review')
ROUTER = os.path.join(SKILL, 'scripts', 'feature-routing.rb')
REVIEW = os.path.join(SKILL, 'scripts', 'github-pr-review.sh')
LIVE_TREE = os.path.join(SKILL, 'features')
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'fixtures', 'pr-review-features')
fails = []
passed = 0


def check(name, cond, detail=''):
    global passed
    if cond:
        passed += 1
        print(f'ok - {name}')
    else:
        fails.append(name)
        print(f'FAIL {name}: {detail}')


def run(args, stdin=''):
    p = subprocess.run(args, input=stdin, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def route(files, root=FIXTURE, repo='demo', extra=()):
    rc, out, err = run([ROUTER, 'route', '--repo', repo, '--root', root, *extra],
                       '\n'.join(files) + '\n')
    return rc, (json.loads(out) if rc == 0 else None), err


def names(items):
    return [i['name'] for i in items]


def ids(m):
    return [r['id'] for r in m['rules']]


# --- routing --------------------------------------------------------------
rc, m, err = route(['README.md', 'src/other/thing.ts'])
check('no match: correctness only',
      rc == 0 and m['configFound'] and m['features'] == [] and m['rules'] == []
      and m['lenses'] == [{'name': 'correctness', 'always': True}], f'rc={rc} {err} {m}')

rc, m, err = route(['src/swap/a.ts'], repo='other-repo')
check('repo without features.yaml: configFound false, correctness only',
      rc == 0 and not m['configFound'] and names(m['lenses']) == ['correctness'], f'rc={rc} {err}')

empty = tempfile.mkdtemp()
rc, m, err = route(['src/swap/a.ts'], root=empty)
check('ref with no features tree at all: correctness only, exit 0',
      rc == 0 and not m['configFound'] and names(m['lenses']) == ['correctness'], f'rc={rc} {err}')

rc, m, err = route(['src/swap/deep/nested/quote.ts'])
check('dir/** matches deep files',
      rc == 0 and names(m['features']) == ['Swap'] and m['features'][0]['matchedFiles'] == ['src/swap/deep/nested/quote.ts'],
      f'rc={rc} {err} {m and m["features"]}')
check('rule scope defaults to feature paths; scoped and disabled rules stay out',
      m and ids(m) == ['swap-quote-refresh'], m and ids(m))
check('feature lenses spawn after correctness',
      m and names(m['lenses']) == ['correctness', 'amount-precision']
      and m['lenses'][1]['features'] == ['Swap'] and m['lenses'][1]['focus'], m and m['lenses'])

rc, m, err = route(['src/swap/__tests__/quote.test.ts'])
check('! pattern excludes', rc == 0 and m['features'] == [], m and m['features'])

rc, m, err = route(['src/swap/math/fee.ts'])
check('scoped rule loads when a changed file is in scope',
      rc == 0 and sorted(ids(m)) == ['swap-native-amounts', 'swap-quote-refresh'], m and ids(m))

rc, m, err = route(['src/hooks/stealth/useSend.ts', 'src/components/scenes/StealthSendScene.tsx', 'src/swap/x.ts'])
check('{a,b} alternation and single-dir * match',
      rc == 0 and sorted(names(m['features'])) == ['Stealth', 'Swap'], m and m['features'])
check('lenses dedupe across features, each lists its features',
      m and names(m['lenses']) == ['correctness', 'amount-precision', 'keys-security']
      and sorted(m['lenses'][1]['features']) == ['Stealth', 'Swap'], m and m['lenses'])
check('rule sources pass through',
      m and [r['sources'] for r in m['rules'] if r['id'] == 'stealth-confirm-before-send'] == [['https://github.com/example/repo/pull/1#discussion_r1']],
      m and m['rules'])

rc, m, err = route(['src/util/stealth/deep/x.ts'])
check('single * does not cross directories', rc == 0 and m['features'] == [], m and m['features'])

rc, m, err = route(['SRC/swap/a.ts'])
check('matching is case-sensitive', rc == 0 and m['features'] == [], m and m['features'])

rc, m, err = route(['docs/guide/setup.md'])
check('candidate is shadow only by default',
      rc == 0 and m['features'] == [] and names(m['shadow']) == ['Docs']
      and names(m['lenses']) == ['correctness'], m)
rc, m, err = route(['docs/guide/setup.md'], extra=['--candidates'])
check('candidate loads with --candidates',
      rc == 0 and names(m['features']) == ['Docs'] and m['shadow'] == []
      and names(m['lenses']) == ['correctness', 'keys-security'], m)

rc, m, err = route(['src/legacy/old.ts'], extra=['--candidates'])
check('retired never loads', rc == 0 and m['features'] == [] and m['shadow'] == [], m)

rc, out, err = run([ROUTER, 'validate', '--repo', 'demo', '--root', FIXTURE])
check('validate accepts the fixture', rc == 0 and out.startswith('OK demo: 4 features, 4 rules, 2 lenses'), f'rc={rc} {out} {err}')

live = tempfile.mkdtemp()
shutil.copy(os.path.join(LIVE_TREE, 'lenses.yaml'), live)
shutil.copytree(os.path.join(FIXTURE, 'demo'), os.path.join(live, 'demo'))
rc, out, err = run([ROUTER, 'validate', '--repo', 'demo', '--root', live])
check('live lenses.yaml parses and carries the fixture lenses', rc == 0, f'rc={rc} {err}')

rc, out, err = run([ROUTER, 'route', '--repo', 'demo'])
check('usage error exits 2', rc == 2, f'rc={rc}')


# --- schema errors ----------------------------------------------------------
def mutated(path, old, new):
    """Copy of the fixture with one substring replaced in one file -> root."""
    root = tempfile.mkdtemp()
    shutil.copytree(FIXTURE, root, dirs_exist_ok=True)
    target = os.path.join(root, path)
    text = open(target).read()
    assert old in text, (path, old)
    open(target, 'w').write(text.replace(old, new, 1))
    return root


SCHEMA_CASES = [
    ('unknown feature key', 'demo/features.yaml', '    owners: [swap-owner]', '    owner: [swap-owner]', 'unknown key'),
    ('unknown lens', 'demo/features.yaml', 'lenses: [amount-precision]', 'lenses: [amount-precison]', 'unknown lens'),
    ('bad status', 'demo/features.yaml', 'status: active', 'status: live', 'status'),
    ('duplicate rule id across files', 'demo/stealth.rules.yaml', 'id: stealth-confirm-before-send', 'id: swap-quote-refresh', 'declared by both'),
    ('bad severity', 'demo/swap.rules.yaml', 'severity: warning', 'severity: high', 'severity'),
    ('missing rule file', 'demo/features.yaml', 'rules: stealth.rules.yaml', 'rules: gone.rules.yaml', 'gone.rules.yaml'),
    ('paths with only exclusions', 'demo/features.yaml', "paths: [docs/**/*.md]", "paths: ['!docs/**']", 'not a ! exclusion'),
    ('lens catalog declares correctness', 'lenses.yaml', 'name: keys-security', 'name: correctness', 'correctness'),
]
for label, path, old, new, needle in SCHEMA_CASES:
    root = mutated(path, old, new)
    rc, out, err = run([ROUTER, 'validate', '--repo', 'demo', '--root', root])
    rc2, _, err2 = run([ROUTER, 'route', '--repo', 'demo', '--root', root], 'src/swap/a.ts\n')
    check(f'schema error: {label}', rc == 1 and rc2 == 1 and needle in err, f'rc={rc}/{rc2} {err.strip()}')


# --- base ref wins over the PR branch (--git) --------------------------------
repo = tempfile.mkdtemp()
tree = os.path.join(repo, '.cursor', 'skills', 'pr-review', 'features')


def git(*args):
    p = subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True)
    assert p.returncode == 0, (args, p.stderr)
    return p.stdout


git('init', '-q', '-b', 'main')
git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'before features')
before = git('rev-parse', 'HEAD').strip()
shutil.copytree(FIXTURE, tree)
git('add', '-A')
git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'features')
git('checkout', '-q', '-b', 'pr')
with open(os.path.join(tree, 'demo', 'swap.rules.yaml'), 'a') as f:
    f.write('  - id: swap-pr-added\n    rule: Added on the PR branch.\n    severity: critical\n')
git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-am', 'pr edits rules')
with open(os.path.join(tree, 'demo', 'swap.rules.yaml'), 'a') as f:
    f.write('  - id: swap-uncommitted\n    rule: Uncommitted.\n    severity: critical\n')


def git_route(ref):
    rc, out, err = run([ROUTER, 'route', '--repo', 'demo', '--git', repo, '--ref', ref], 'src/swap/a.ts\n')
    return rc, (json.loads(out) if rc == 0 else None), err


rc, m, err = git_route('main')
check('--git reads the base ref, not the PR branch or working tree',
      rc == 0 and ids(m) == ['swap-quote-refresh'] and m['source'].endswith('@main'), f'rc={rc} {err} {m and ids(m)}')
rc, m, err = git_route('pr')
check('--git at the PR ref sees its committed edit only', rc == 0 and ids(m) == ['swap-quote-refresh', 'swap-pr-added'], f'rc={rc} {err}')
rc, m, err = git_route(before)
check('--git at a ref before the features tree: correctness only', rc == 0 and not m['configFound'], f'rc={rc} {err}')
rc, m, err = git_route('no-such-ref')
check('--git with a bad ref exits 1', rc == 1, f'rc={rc}')


# --- render --features tag check ---------------------------------------------
rc, out, err = route(['src/swap/x.ts', 'src/hooks/stealth/useSend.ts'])
manifest = os.path.join(tempfile.mkdtemp(), 'manifest.json')
json.dump(out, open(manifest, 'w'))
review = {'event': 'COMMENT', 'body': '', 'comments': [
    {'path': 'src/swap/x.ts', 'line': 3, 'body': 'Stale quote.', 'tag': 'rule:swap-quote-refresh'},
    {'path': 'src/hooks/stealth/useSend.ts', 'line': 9, 'body': 'Float math.', 'tag': 'lens:amount-precision'},
]}
rc, out, err = run([REVIEW, 'render'], json.dumps(review))
check('render refuses feature tags without --features',
      rc == 1 and 'swap-quote-refresh' in err and 'amount-precision' in err, f'rc={rc} {err}')
rc, out, err = run([REVIEW, 'render', '--features', manifest], json.dumps(review))
bodies = [c['body'] for c in json.loads(out)['comments']] if rc == 0 else []
check('render accepts feature tags with --features and appends markers',
      rc == 0 and bodies[0].endswith('<!-- pr-review:tag=rule:swap-quote-refresh -->')
      and bodies[1].endswith('<!-- pr-review:tag=lens:amount-precision -->'), f'rc={rc} {err}')

unmatched = dict(review, comments=[{'path': 'a.ts', 'line': 1, 'body': 'x', 'tag': 'lens:keys-security'}])
rc, out, err = run([REVIEW, 'render', '--features', manifest], json.dumps(unmatched))
check('render accepts a lens the manifest spawned', rc == 0, f'rc={rc} {err}')
off = dict(review, comments=[{'path': 'a.ts', 'line': 1, 'body': 'x', 'tag': 'rule:swap-native-amounts'}])
rc, out, err = run([REVIEW, 'render', '--features', manifest], json.dumps(off))
check('render refuses a feature rule the manifest did not load', rc == 1 and 'swap-native-amounts' in err, f'rc={rc} {err}')
corr = dict(review, comments=[{'path': 'a.ts', 'line': 1, 'body': 'x', 'tag': 'lens:correctness'}])
rc, out, err = run([REVIEW, 'render', '--features', manifest], json.dumps(corr))
check('lens:correctness is not a tag', rc == 1, f'rc={rc}')
rc, out, err = run([REVIEW, 'render', '--features', '/nonexistent/manifest.json'], json.dumps(review))
check('render refuses an unreadable manifest', rc == 1 and 'not a readable feature manifest' in err, f'rc={rc} {err}')

plain = {'event': 'COMMENT', 'body': '', 'comments': [{'path': 'a.ts', 'line': 1, 'body': 'x', 'tag': 'general'}]}
rc_a, out_a, _ = run([REVIEW, 'render'], json.dumps(plain))
rc, m, _ = route(['README.md'])
cm = os.path.join(tempfile.mkdtemp(), 'manifest.json')
json.dump(m, open(cm, 'w'))
rc_b, out_b, _ = run([REVIEW, 'render', '--features', cm], json.dumps(plain))
check('correctness-only manifest leaves render output unchanged', rc_a == 0 and rc_b == 0 and out_a == out_b, f'{rc_a} {rc_b}')

print(f'{passed} passed, {len(fails)} failed')
sys.exit(1 if fails else 0)
