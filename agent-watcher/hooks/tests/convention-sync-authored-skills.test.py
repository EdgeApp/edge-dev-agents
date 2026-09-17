#!/usr/bin/env python3
"""Contract tests for convention-sync.sh's authored-only skills gate and secret scan.

Run: python3 ~/.config/agent-watcher/hooks/tests/convention-sync-authored-skills.test.py
     (CONVENTION_SYNC_SRC=<path> tests a staged copy of convention-sync.sh
     instead of the installed one)

Covers:
  A. Authored-only gate (user-to-repo)
     A1 a skill the repo already carries syncs (new + modified files).
     A2 a brand-new skill whose SKILL.md claims an author the repo distributes syncs.
     A3 a third-party bucket (a `.bucket-*` marker beside a UUID-named directory)
        is excluded, reported once with the marker in the reason and the file
        count, and none of its files reach new/modified.
     A4 a skill claiming a foreign author, and one claiming no author, are each
        excluded and reported with a reason naming why.
     A5 a UUID-named directory dropped INSIDE a repo-tracked skill is excluded.
     A6 a shared script at the skills/ top level still syncs.
     A7 rules/ is untouched by the gate.
     A8 .syncignore patterns are still honored.
  B. Secret scan (stage gate)
     B1 a key-shaped blob in a key-named file is reported in secretFindings.
     B2 --stage refuses, names the path, and copies nothing into the repo.
     B3 a prose placeholder (`sk-...` with no digits) is not a finding.
     B4 .syncignore is the escape hatch: with the key file ignored, the stage
        runs and lands exactly the authored files (bucket and unrecognized
        skills stay out of the repo).

Offline under a throwaway HOME and a throwaway fixture repo. No network, and
nothing outside the temp directory is written.
"""
import json, os, shutil, subprocess, sys, tempfile, time

REAL = os.path.expanduser('~')
SCRIPT = os.environ.get(
    'CONVENTION_SYNC_SRC',
    os.path.join(REAL, '.cursor/skills/convention-sync/scripts/convention-sync.sh'))
UUID = 'fb58cfea-3e13-4555-b632-7874df833e0c_6d0a949f-5235-4aa6-b754-5e7faa3cc0c2'
AUTHOR = 'j0ntz'
# Fake credential material. Shaped like the real thing, valid nowhere.
FAKE_KEY = 'AQ.Ab8RN6J' + 'x7Qm2vT4wL9pZ0cK3sD1fG5hJ8nB6rY2uE4iO7a'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


TMP = tempfile.mkdtemp(prefix='convention-sync-authored-test-')
HOME = os.path.join(TMP, 'home')
REPO = os.path.join(TMP, 'edge-dev-agents')
SKILLS = os.path.join(HOME, '.cursor/skills')
REPO_SKILLS = os.path.join(REPO, '.cursor/skills')


def write(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(body)


def skill_md(name, author=None, body='Body.\n'):
    front = f'---\nname: {name}\ndescription: Test skill.\n'
    if author:
        front += f'metadata:\n  author: {author}\n'
    return front + '---\n\n' + body


def git(*args, cwd=REPO):
    return subprocess.run(
        ['git', '-c', 'user.name=test', '-c', 'user.email=test@example.com', *args],
        cwd=cwd, capture_output=True, text=True)


def run(*args, expect_json=True):
    proc = subprocess.run(['bash', SCRIPT, REPO, *args], capture_output=True, text=True,
                          env={**os.environ, 'HOME': HOME})
    data = None
    if expect_json and proc.stdout.strip():
        try:
            data = json.loads(proc.stdout)
        except json.JSONDecodeError:
            data = None
    return proc, data


# --- fixture ------------------------------------------------------------------
# Repo side: one tracked skill (its frontmatter author is what makes AUTHOR an
# author "the repo distributes") plus the .syncignore the sync reads from there.
write(os.path.join(REPO_SKILLS, 'alpha/SKILL.md'), skill_md('alpha', AUTHOR, 'Upstream copy.\n'))
write(os.path.join(REPO, '.cursor/.syncignore'),
      '# test excludes\nskills/alpha/maestro/swap-*.yaml\n')
write(os.path.join(REPO, 'README.md'), 'repo readme\n')
write(os.path.join(REPO, '.cursor/rules/keep.mdc'), 'rule\n')

# Home side.
write(os.path.join(HOME, '.cursor/README.md'), 'repo readme\n')
write(os.path.join(HOME, '.cursor/rules/keep.mdc'), 'rule\n')
write(os.path.join(HOME, '.cursor/rules/fresh.mdc'), 'new rule\n')
write(os.path.join(SKILLS, 'alpha/SKILL.md'), skill_md('alpha', AUTHOR, 'Local edit.\n'))
write(os.path.join(SKILLS, 'alpha/scripts/run.sh'), '#!/usr/bin/env bash\necho hi\n')
write(os.path.join(SKILLS, 'alpha/references/notes.md'),
      'Use the placeholder sk-gid-for-pr-body-link in the PR body.\n')
write(os.path.join(SKILLS, 'alpha/scripts/api-key.txt'), FAKE_KEY + '\n')
write(os.path.join(SKILLS, 'alpha/maestro/swap-quote.yaml'), 'flow: swap\n')
write(os.path.join(SKILLS, 'alpha/maestro/buy-quote.yaml'), 'flow: buy\n')
write(os.path.join(SKILLS, f'alpha/{UUID}/notes.md'), 'dropped bucket inside a real skill\n')
write(os.path.join(SKILLS, 'beta/SKILL.md'), skill_md('beta', AUTHOR, 'Brand new, mine.\n'))
write(os.path.join(SKILLS, 'gamma/SKILL.md'), skill_md('gamma', 'SomeVendor', 'Third party.\n'))
write(os.path.join(SKILLS, 'delta/SKILL.md'), skill_md('delta', None, 'No author marker.\n'))
write(os.path.join(SKILLS, 'toolbox.sh'), '#!/usr/bin/env bash\necho shared\n')
write(os.path.join(SKILLS, f'synced/.bucket-{UUID}'), '')
write(os.path.join(SKILLS, f'synced/{UUID}/manifest.json'), '{"name": null}\n')
write(os.path.join(SKILLS, f'synced/{UUID}/vendor/SKILL.md'), skill_md('vendor', 'SomeVendor'))
write(os.path.join(SKILLS, f'synced/{UUID}/vendor/scripts/key.txt'), FAKE_KEY + '\n')

git('init', '-q')
git('checkout', '-q', '-b', 'main')
git('add', '-A')
git('commit', '-q', '-m', 'fixture')
# The stale-local gate compares repo commit time against local mtime; make every
# local file newer so the fixture's own commit can't block the stage.
time.sleep(1.1)
now = time.time()
for root, _dirs, files in os.walk(os.path.join(HOME, '.cursor')):
    for f in files:
        os.utime(os.path.join(root, f), (now, now))

# --- A. dry run ---------------------------------------------------------------
proc, data = run()
check('dry run exits 0', proc.returncode == 0, proc.stderr[-400:])
if data is None:
    print('FAIL dry run produced no JSON')
    print(proc.stdout[:400], proc.stderr[-400:])
    sys.exit(1)

new, mod = data['new'], data['modified']
excluded = {e['entry']: e for e in data['excludedSkills']}
findings = {f['file']: f['kind'] for f in data['secretFindings']}

check('A1 tracked skill: local edit is modified', 'skills/alpha/SKILL.md' in mod, mod)
check('A1 tracked skill: new file inside it syncs', 'skills/alpha/scripts/run.sh' in new, new)
check('A2 new skill with an operator author marker syncs', 'skills/beta/SKILL.md' in new, new)
check('A3 bucket reported once', 'skills/synced' in excluded, list(excluded))
check('A3 bucket reason names the marker',
      f'.bucket-{UUID}' in excluded.get('skills/synced', {}).get('reason', ''),
      excluded.get('skills/synced'))
check('A3 bucket file count reported', excluded.get('skills/synced', {}).get('files') == 4,
      excluded.get('skills/synced'))
check('A3 no bucket file is staged',
      not [f for f in new + mod if f.startswith('skills/synced/')], new + mod)
check('A4 foreign-author skill excluded', 'skills/gamma' in excluded, list(excluded))
check('A4 foreign-author reason names the author',
      'SomeVendor' in excluded.get('skills/gamma', {}).get('reason', ''),
      excluded.get('skills/gamma'))
check('A4 unrecognized skill excluded', 'skills/delta' in excluded, list(excluded))
check('A4 unrecognized reason names the missing marker',
      'metadata.author' in excluded.get('skills/delta', {}).get('reason', ''),
      excluded.get('skills/delta'))
check('A4 excluded skills are not staged',
      not [f for f in new + mod if f.startswith(('skills/gamma/', 'skills/delta/'))], new + mod)
check('A5 UUID dir inside a tracked skill excluded', f'skills/alpha/{UUID}' in excluded,
      list(excluded))
check('A5 UUID reason says UUID-named',
      'UUID' in excluded.get(f'skills/alpha/{UUID}', {}).get('reason', ''),
      excluded.get(f'skills/alpha/{UUID}'))
check('A6 top-level shared script syncs', 'skills/toolbox.sh' in new, new)
check('A7 rules/ untouched by the gate', 'rules/fresh.mdc' in new, new)
check('A8 .syncignore still honored',
      'skills/alpha/maestro/swap-quote.yaml' in data['ignored']
      and 'skills/alpha/maestro/swap-quote.yaml' not in new
      and 'skills/alpha/maestro/buy-quote.yaml' in new, data['ignored'])

check('B1 key-named blob reported', 'skills/alpha/scripts/api-key.txt' in findings, findings)
check('B3 prose placeholder is not a finding',
      'skills/alpha/references/notes.md' not in findings, findings)
check('B1 bucket key never reaches the scan (gate ran first)',
      not [f for f in findings if f.startswith('skills/synced/')], findings)

# --- B2. stage refusal --------------------------------------------------------
proc, _ = run('--stage', expect_json=False)
check('B2 stage refused', proc.returncode != 0, proc.stdout[-200:])
check('B2 refusal names the file', 'skills/alpha/scripts/api-key.txt' in proc.stderr,
      proc.stderr[-300:])
check('B2 nothing copied into the repo', not os.path.exists(os.path.join(REPO_SKILLS, 'beta')))
check('B2 repo working tree still clean',
      git('status', '--porcelain').stdout.strip() == '',
      git('status', '--porcelain').stdout[:300])

# --- B4. escape hatch, then a real stage --------------------------------------
write(os.path.join(REPO, '.cursor/.syncignore'),
      '# test excludes\nskills/alpha/maestro/swap-*.yaml\nskills/alpha/scripts/api-key.txt\n')
git('add', '-A')
git('commit', '-q', '-m', 'ignore the key file')
time.sleep(1.1)
now = time.time()
for root, _dirs, files in os.walk(os.path.join(HOME, '.cursor')):
    for f in files:
        os.utime(os.path.join(root, f), (now, now))

proc, data = run('--stage')
check('B4 stage runs once the key file is ignored', proc.returncode == 0, proc.stderr[-400:])
check('B4 authored new skill landed', os.path.exists(os.path.join(REPO_SKILLS, 'beta/SKILL.md')))
check('B4 shared script landed', os.path.exists(os.path.join(REPO_SKILLS, 'toolbox.sh')))
check('B4 key file did not land',
      not os.path.exists(os.path.join(REPO_SKILLS, 'alpha/scripts/api-key.txt')))
check('B4 bucket did not land', not os.path.exists(os.path.join(REPO_SKILLS, 'synced')))
check('B4 unrecognized skills did not land',
      not os.path.exists(os.path.join(REPO_SKILLS, 'gamma'))
      and not os.path.exists(os.path.join(REPO_SKILLS, 'delta')))
check('B4 UUID dir inside the tracked skill did not land',
      not os.path.exists(os.path.join(REPO_SKILLS, 'alpha', UUID)))
check('B4 exclusions still reported on the staging run',
      data is not None and {'skills/synced', 'skills/gamma', 'skills/delta'}
      <= {e['entry'] for e in data['excludedSkills']},
      data and data.get('excludedSkills'))

shutil.rmtree(TMP, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall checks passed')
sys.exit(1 if fails else 0)
