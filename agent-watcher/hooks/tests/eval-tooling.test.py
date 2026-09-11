#!/usr/bin/env python3
"""Contract tests for the eval tooling that keeps the rubric small and the
remediation list ranked by script.

Run: python3 ~/.config/agent-watcher/hooks/tests/eval-tooling.test.py

  1. rubric-slice.sh: a profile slice carries exactly the profile's rows plus the
     preamble; an unknown profile exits 1.
  2. era.sh: rows split by the run's window end; empty date = everything in effect.
  3. Rubric rows carry no dates (era.md owns them); every `era: <name>` citation
     resolves to an era row.
  4. pr-commit-stats.sh: fixup body / kind / per-target-kind counts and subject
     length from an API payload fixture.
  5. actions-ledger.sh: record merges across cohorts, set moves status, rank groups
     by tier with approved-unbuilt and regressed classes first.
"""
import json, os, re, subprocess, sys, tempfile

SK = os.path.expanduser('~/.cursor/skills')
SLICE = f'{SK}/agent-eval/scripts/rubric-slice.sh'
ERA = f'{SK}/agent-eval/scripts/era.sh'
STATS = f'{SK}/resolve-run/scripts/pr-commit-stats.sh'
LEDGER = f'{SK}/eval-run/scripts/actions-ledger.sh'
RUBRICS = [f'{SK}/agent-eval/references/rubric.md', f'{SK}/orch-eval/references/rubric.md']
ERA_MD = f'{SK}/agent-eval/references/era.md'
fails = []


def check(name, cond, detail=''):
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else f'  {detail}'))
    cond or fails.append(name)


def sh(cmd, env=None):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, env={**os.environ, **(env or {})})


ROW = re.compile(r'^\|\s*\*{0,2}([AO]\d+)\b')

# ---- 1. slice ----
p = sh(f'{SLICE} report')
rows = [m.group(1) for m in (ROW.match(l) for l in p.stdout.split('\n')) if m]
check('report slice has exactly the profile rows', p.returncode == 0 and sorted(rows) == ['A20', 'A22', 'A3', 'A32', 'A9'], rows)
check('slice keeps the preamble era paragraph', 'ERA:' in p.stdout and '## Evidence sources' in p.stdout)
p = sh(f'{SLICE} --dims A1,A2')
check('--dims slice', p.returncode == 0 and [m.group(1) for m in (ROW.match(l) for l in p.stdout.split('\n')) if m] == ['A1', 'A2'])
check('unknown profile exits 1', sh(f'{SLICE} nope').returncode == 1)

# ---- 2. era ----
e = json.loads(sh(f'{ERA} 2026-08-10T12:00:00Z').stdout)
check('era splits by window end', e['as_of'] == '2026-08-10' and all(r['shipped'] <= '2026-08-10' for r in e['in_effect']) and all(r['shipped'] > '2026-08-10' for r in e['not_yet']) and e['not_yet'])
check('era rows carry dims and Before/After', all(r['dims'] and r['after'] for r in e['in_effect']) and all(r['before'] for r in e['not_yet']))
e2 = json.loads(sh(f'{ERA} ""').stdout)
check('empty date = all rows in effect', e2['as_of'] is None and not e2['not_yet'] and len(e2['in_effect']) == len(e['in_effect']) + len(e['not_yet']))

# ---- 3. rubric rows are date-free and cite real era names ----
names = {r['name'] for r in e2['in_effect']}
dated, unresolved = [], []
for path in RUBRICS:
    for line in open(path):
        if not ROW.match(line):
            continue
        if re.search(r'20\d\d-\d\d-\d\d', line):
            dated.append(ROW.match(line).group(1))
        for cite in re.findall(r'era: ([^;)\]|]+)', line):
            for n in cite.split(','):
                n = n.strip()
                if n and n not in names:
                    unresolved.append((ROW.match(line).group(1), n))
check('no dates in any dimension row', not dated, dated)
check('every era citation resolves', not unresolved, unresolved)

# ---- 4. pr-commit-stats ----
tmp = tempfile.mkdtemp(prefix='evaltool-')
try:
    def c(sha, msg, date='2026-09-12T00:00:00Z'):
        return {'sha': sha, 'commit': {'message': msg, 'author': {'date': date}}}
    fx = os.path.join(tmp, 'commits.json')
    json.dump([
        c('a' * 40, 'Add feature A'),
        c('b' * 40, 'A subject that is deliberately longer than fifty characters'),
        c('c' * 40, 'fixup! Add feature A\n\nAnswer the reviewer\n\nFixup-for: human'),
        c('d' * 40, 'fixup! Add feature A\n\nSecond human fix\n\nFixup-for: human'),
        c('e' * 40, 'fixup! Add feature A\n\nBot finding\n\nFixup-for: auto'),
        c('f' * 40, 'fixup! fixup! Add feature A'),
        c('1' * 40, 'fixup! Add feature B\n\nlegacy body'),
    ], open(fx, 'w'))
    s = json.loads(sh(f'{STATS} --from-json {fx} fixture').stdout)
    check('counts fixups and subjects', s['commits'] == 7 and s['fixups']['total'] == 5 and s['subjects_over_50'] == ['bbbbbbb'], s)
    check('bodyless and untagged listed by sha', s['fixups']['bodyless'] == ['fffffff'] and sorted(s['fixups']['untagged']) == ['1111111', 'fffffff'], s['fixups'])
    over = {(g['target'], g['kind']): g['n'] for g in s['fixups']['over_one_per_target_kind']}
    check('over-one groups per target and kind, nested subject folded', over == {('Add feature A', 'human'): 2}, over)

    # ---- 5. actions ledger ----
    env = {'ACTIONS_LEDGER': os.path.join(tmp, 'ledger.json')}
    a1 = os.path.join(tmp, 'a1.json'); a2 = os.path.join(tmp, 'a2.json')
    json.dump([
        {'class_id': 'watermark-gate', 'type': 'infra-fix', 'title': 'Block post-attach comments', 'dims': ['A9', 'A23'], 'gids': ['1', '2'], 'window_ends': {'1': '2026-08-10', '2': '2026-08-12'}},
        {'class_id': 'subtask-false-positive', 'type': 'infra-fix', 'title': 'require-subtasks false positives', 'tier': 3, 'gids': ['3'], 'window_ends': {'3': '2026-08-11'}},
        {'class_id': 'no-tier', 'type': 'skill-gap', 'title': 'skipped'},
    ], open(a1, 'w'))
    json.dump([
        {'class_id': 'watermark-gate', 'type': 'infra-fix', 'title': 'Block post-attach comments', 'gids': ['4'], 'window_ends': {'4': '2026-09-01'}},
        {'class_id': 'subtask-false-positive', 'type': 'infra-fix', 'title': 'x', 'gids': ['5'], 'window_ends': {'5': '2026-09-02'}},
        {'class_id': 'dead-citation-lint', 'type': 'infra-fix', 'title': 'Resolve cited URLs', 'dims': ['A20'], 'gids': ['6'], 'window_ends': {'6': '2026-09-02'}},
    ], open(a2, 'w'))
    check('tier-of picks the lowest tier number', sh(f'{LEDGER} tier-of A9,A23', env).stdout.strip() == '2')
    r = sh(f'{LEDGER} record --cohort 2026-08-19 --actions {a1}', env)
    check('record creates classes and skips a tierless one', '"created":2' in r.stdout and 'skip no-tier' in r.stderr, r.stdout + r.stderr)
    sh(f'{LEDGER} set watermark-gate approved --date 2026-08-20', env)
    sh(f'{LEDGER} set subtask-false-positive built --ref hookfix --date 2026-08-25', env)
    r = sh(f'{LEDGER} record --cohort 2026-09-05 --actions {a2}', env)
    check('second record updates known classes without re-giving tier', '"created":1' in r.stdout and '"updated":2' in r.stdout, r.stdout + r.stderr)
    snap = json.loads(sh(f'{LEDGER} snapshot', env).stdout)
    by = {c['id']: c for c in snap['classes']}
    check('approved class is approved_unbuilt with full recurrence', by['watermark-gate']['approved_unbuilt'] and by['watermark-gate']['recurrence_since_fix'] == 3)
    check('built class that recurred is regressed', by['subtask-false-positive']['regressed'] and by['subtask-false-positive']['recurrence_since_fix'] == 1)
    rank = sh(f'{LEDGER} rank', env).stdout
    t1, t2, t3 = rank.index('### Tier 1'), rank.index('### Tier 2'), rank.index('### Tier 3')
    check('rank groups by tier in order', t1 < t2 < t3 and 'dead-citation-lint' in rank[t1:t2] and 'APPROVED, UNBUILT' in rank[t2:t3] and 'REGRESSED' in rank[t3:])
    sh(f'{LEDGER} set dead-citation-lint declined --date 2026-09-06', env)
    check('declined classes leave the rank', 'dead-citation-lint' not in sh(f'{LEDGER} rank', env).stdout)
    check('unknown class id exits 1', sh(f'{LEDGER} set nope built', env).returncode == 1)
finally:
    import shutil; shutil.rmtree(tmp, ignore_errors=True)
print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
