#!/usr/bin/env python3
"""Export a window of human PR review threads from a GitHub org as JSONL.

Read-only: every GitHub call is a GraphQL query through the authenticated gh CLI.

Stage 1 enumerates merged PRs with the search API, one slice per month so no
slice nears the 1000-result search cap. Stage 2 fetches every reviewThread on
each PR with all of its comments (paginated past 100). Raw per-PR responses are
cached under <out>/cache/ so a rerun or an interrupted run only fetches what is
missing; --refresh ignores the cache.

Outputs in --out:
  review-threads-<since>_<until>.jsonl  one row per thread (root comment + replies)
  summary.json, summary.md              counts by repo, author and author class

Author classes come from the accounts file (--accounts, default
~/.config/pr-review/mining/accounts.json; template mining-accounts.example.json
next to this script): human (its humans), operator (its operator login, written
as that login's class name), bot (every other account, ghost included).
diffHunk keeps the hunk header plus the last --hunk-lines lines: GitHub truncates
a review comment's hunk at the commented line, so the tail is the context around
it. diffHunkFull keeps the hunk as GitHub returned it.

Usage:
  mine-review-comments.py [--org EdgeApp] [--since 2025-10-23] [--until 2026-10-23]
                          [--out ~/.config/pr-review/mining] [--accounts <file>]
                          [--jobs 4] [--refresh]
"""

import argparse
import collections
import concurrent.futures
import datetime
import json
import os
import subprocess
import sys
import time

DEFAULT_ACCOUNTS = os.path.expanduser('~/.config/pr-review/mining/accounts.json')
EXAMPLE_ACCOUNTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mining-accounts.example.json')

# Filled by load_accounts() from the local accounts file, which stays off the
# public repo. humans and operator classify authors; anything else is a bot.
# knownBots only separates the expected bots from new ones in the summary.
HUMANS = set()
OPERATOR = None
KNOWN_BOTS = set()


def load_accounts(path):
  global HUMANS, OPERATOR, KNOWN_BOTS
  if not os.path.exists(path):
    sys.exit('accounts file %s missing: copy %s there and fill in the logins' % (path, EXAMPLE_ACCOUNTS))
  with open(path) as f:
    acc = json.load(f)
  HUMANS = set(acc['humans'])
  OPERATOR = acc['operator']
  KNOWN_BOTS = {b.lower() for b in acc.get('knownBots', [])}


SEARCH_QUERY = '''
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title url mergedAt createdAt baseRefName
        author { login __typename }
        repository { name }
      }
    }
  }
}
'''

COMMENT_FIELDS = '''
  id databaseId url createdAt body authorAssociation diffHunk
  author { login __typename }
  originalCommit { oid }
  commit { oid }
  replyTo { databaseId }
  reactionGroups { content users { totalCount } }
'''

THREADS_QUERY = '''
query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line originalLine startLine originalStartLine
          diffSide subjectType
          resolvedBy { login }
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { %s }
          }
        }
      }
    }
  }
}
''' % COMMENT_FIELDS

MORE_COMMENTS_QUERY = '''
query($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { %s }
      }
    }
  }
}
''' % COMMENT_FIELDS


def graphql(query, variables, attempts=5):
  body = json.dumps({'query': query, 'variables': variables})
  for attempt in range(attempts):
    proc = subprocess.run(['gh', 'api', 'graphql', '--input', '-'], input=body,
                          capture_output=True, text=True)
    if proc.returncode == 0:
      data = json.loads(proc.stdout)
      if not data.get('errors'):
        return data['data']
      err = json.dumps(data['errors'])[:500]
    else:
      err = (proc.stderr or proc.stdout)[:500]
    if attempt + 1 == attempts:
      raise RuntimeError('graphql failed after %d attempts: %s' % (attempts, err))
    time.sleep(5 * (attempt + 1))


def month_slices(since, until):
  start = datetime.date.fromisoformat(since)
  end = datetime.date.fromisoformat(until)
  while start <= end:
    nxt = (start.replace(day=1) + datetime.timedelta(days=32)).replace(day=1)
    stop = min(nxt - datetime.timedelta(days=1), end)
    yield start.isoformat(), stop.isoformat()
    start = nxt


def list_merged_prs(org, since, until):
  prs = {}
  for lo, hi in month_slices(since, until):
    q = 'org:%s is:pr is:merged merged:%s..%s' % (org, lo, hi)
    after = None
    while True:
      res = graphql(SEARCH_QUERY, {'q': q, 'after': after})['search']
      if res['issueCount'] >= 1000:
        raise RuntimeError('search slice %s..%s hit the 1000-result cap' % (lo, hi))
      for n in res['nodes']:
        if n:
          prs[(n['repository']['name'], n['number'])] = n
      if not res['pageInfo']['hasNextPage']:
        break
      after = res['pageInfo']['endCursor']
  return sorted(prs.values(), key=lambda p: (p['repository']['name'], p['number']))


def fetch_threads(org, repo, number):
  threads = []
  after = None
  while True:
    res = graphql(THREADS_QUERY, {'owner': org, 'repo': repo, 'number': number, 'after': after})
    page = res['repository']['pullRequest']['reviewThreads']
    for t in page['nodes']:
      conn = t['comments']
      while conn['pageInfo']['hasNextPage']:
        more = graphql(MORE_COMMENTS_QUERY, {'id': t['id'], 'after': conn['pageInfo']['endCursor']})
        nxt = more['node']['comments']
        conn['nodes'].extend(nxt['nodes'])
        conn['pageInfo'] = nxt['pageInfo']
      threads.append(t)
    if not page['pageInfo']['hasNextPage']:
      return threads
    after = page['pageInfo']['endCursor']


def cached_threads(cache_dir, org, pr, refresh):
  repo, number = pr['repository']['name'], pr['number']
  path = os.path.join(cache_dir, '%s-%d.json' % (repo, number))
  if not refresh and os.path.exists(path):
    with open(path) as f:
      return json.load(f)
  threads = fetch_threads(org, repo, number)
  tmp = path + '.tmp'
  with open(tmp, 'w') as f:
    json.dump(threads, f)
  os.replace(tmp, path)
  return threads


def login_of(author):
  # GraphQL drops the [bot] suffix REST shows; restore it so logins match the REST form.
  if not author:
    return 'ghost'
  login = author['login']
  if author.get('__typename') == 'Bot' and not login.endswith('[bot]'):
    login += '[bot]'
  return login


def author_class(login):
  if login in HUMANS:
    return 'human'
  if login == OPERATOR:
    return OPERATOR
  return 'bot'


def trim_hunk(hunk, keep):
  if not hunk:
    return hunk
  lines = hunk.split('\n')
  header = lines[0] if lines[0].startswith('@@') else None
  body = lines[1:] if header else lines
  if len(body) <= keep:
    return hunk
  return '\n'.join(([header] if header else []) + body[-keep:])


def thread_row(pr, t, hunk_lines):
  comments = []
  for c in t['comments']['nodes']:
    login = login_of(c['author'])
    comments.append({
      'id': c['databaseId'],
      'url': c['url'],
      'author': login,
      'authorClass': author_class(login),
      'authorAssociation': c['authorAssociation'],
      'createdAt': c['createdAt'],
      'replyTo': (c['replyTo'] or {}).get('databaseId'),
      'commit': (c['commit'] or {}).get('oid'),
      'originalCommit': (c['originalCommit'] or {}).get('oid'),
      'reactions': {g['content']: g['users']['totalCount']
                    for g in c['reactionGroups'] if g['users']['totalCount']},
      'body': c['body'],
    })
  root = t['comments']['nodes'][0] if t['comments']['nodes'] else None
  pr_author = login_of(pr['author'])
  hunk = root['diffHunk'] if root else None
  return {
    'repo': pr['repository']['name'],
    'prNumber': pr['number'],
    'prUrl': pr['url'],
    'prTitle': pr['title'],
    'prAuthor': pr_author,
    'prAuthorClass': author_class(pr_author),
    'prBaseRef': pr['baseRefName'],
    'prMergedAt': pr['mergedAt'],
    'threadId': t['id'],
    'isResolved': t['isResolved'],
    'isOutdated': t['isOutdated'],
    'resolvedBy': login_of(t['resolvedBy']) if t['resolvedBy'] else None,
    'path': t['path'],
    'line': t['line'],
    'originalLine': t['originalLine'],
    'startLine': t['startLine'],
    'originalStartLine': t['originalStartLine'],
    'diffSide': t['diffSide'],
    'subjectType': t['subjectType'],
    'originalCommit': comments[0]['originalCommit'] if comments else None,
    'rootAuthor': comments[0]['author'] if comments else None,
    'rootAuthorClass': comments[0]['authorClass'] if comments else None,
    'replyCount': max(len(comments) - 1, 0),
    'diffHunk': trim_hunk(hunk, hunk_lines),
    'diffHunkFull': hunk,
    'comments': comments,
  }


def summarize(rows, prs, args):
  by_repo = collections.defaultdict(lambda: collections.Counter())
  by_author = collections.defaultdict(lambda: collections.Counter())
  for pr in prs:
    by_repo[pr['repository']['name']]['mergedPrs'] += 1
  for r in rows:
    rc = by_repo[r['repo']]
    rc['threads'] += 1
    rc['root_' + (r['rootAuthorClass'] or 'none')] += 1
    if r['rootAuthor']:
      by_author[r['rootAuthor']]['rootThreads'] += 1
    for c in r['comments']:
      rc['comments_' + c['authorClass']] += 1
      by_author[c['author']]['comments'] += 1
      if c['replyTo'] is not None:
        by_author[c['author']]['replies'] += 1
  pr_with_threads = {(r['repo'], r['prNumber']) for r in rows}
  pr_with_human = {(r['repo'], r['prNumber']) for r in rows if r['rootAuthorClass'] == 'human'}
  totals = collections.Counter()
  for c in by_repo.values():
    totals.update(c)
  unknown = sorted(a for a in by_author
                   if author_class(a) == 'bot' and a.lower() not in KNOWN_BOTS)
  return {
    'org': args.org,
    'operator': OPERATOR,
    'window': {'since': args.since, 'until': args.until},
    'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
    'totals': dict(totals),
    'reposWithMergedPrs': len(by_repo),
    'reposWithThreads': len({r['repo'] for r in rows}),
    'reposWithHumanRoots': len({r['repo'] for r in rows if r['rootAuthorClass'] == 'human'}),
    'prsWithThreads': len(pr_with_threads),
    'prsWithHumanRoots': len(pr_with_human),
    'humanRootsResolved': sum(1 for r in rows if r['rootAuthorClass'] == 'human' and r['isResolved']),
    'humanRootsOutdated': sum(1 for r in rows if r['rootAuthorClass'] == 'human' and r['isOutdated']),
    'humanRootsWithReplies': sum(1 for r in rows if r['rootAuthorClass'] == 'human' and r['replyCount']),
    'unlistedAccountsTaggedBot': unknown,
    'byRepo': {k: dict(v) for k, v in sorted(by_repo.items())},
    'byAuthor': {k: dict(v, authorClass=author_class(k)) for k, v in
                 sorted(by_author.items(), key=lambda kv: -kv[1]['comments'])},
  }


def summary_md(s, jsonl_name):
  t = s['totals']
  out = [
    '# Review threads, %s merged PRs %s to %s' % (s['org'], s['window']['since'], s['window']['until']),
    '',
    'Export: `%s`. Generated %s.' % (jsonl_name, s['generatedAt']),
    '',
    '| Measure | Count |', '|---|---|',
    '| Merged PRs | %d |' % t.get('mergedPrs', 0),
    '| Repos with a merged PR | %d |' % s['reposWithMergedPrs'],
    '| Review threads | %d |' % t.get('threads', 0),
    '| PRs with any thread | %d |' % s['prsWithThreads'],
    '| Human root comments | %d |' % t.get('root_human', 0),
    '| Repos with a human root | %d |' % s['reposWithHumanRoots'],
    '| PRs with a human root | %d |' % s['prsWithHumanRoots'],
    '| Human roots resolved / outdated / with replies | %d / %d / %d |' % (
      s['humanRootsResolved'], s['humanRootsOutdated'], s['humanRootsWithReplies']),
    '| %s root comments | %d |' % (s['operator'], t.get('root_' + s['operator'], 0)),
    '| Bot root comments | %d |' % t.get('root_bot', 0),
    '| All comments (human / %s / bot) | %d / %d / %d |' % (
      s['operator'], t.get('comments_human', 0), t.get('comments_' + s['operator'], 0), t.get('comments_bot', 0)),
    '',
    'Accounts outside the human, operator and named-bot lists (tagged bot): %s' % (
      ', '.join(s['unlistedAccountsTaggedBot']) or 'none'),
    '',
    '## By repo', '',
    '| Repo | Merged PRs | Threads | Human roots | %s roots | Bot roots | Human comments |' % s['operator'],
    '|---|---|---|---|---|---|---|',
  ]
  repos = sorted(s['byRepo'].items(), key=lambda kv: (-kv[1].get('root_human', 0), -kv[1].get('threads', 0), kv[0]))
  for name, c in repos:
    out.append('| %s | %d | %d | %d | %d | %d | %d |' % (
      name, c.get('mergedPrs', 0), c.get('threads', 0), c.get('root_human', 0),
      c.get('root_' + s['operator'], 0), c.get('root_bot', 0), c.get('comments_human', 0)))
  out += ['', '## By author', '',
          '| Author | Class | Root threads | Replies | All comments |', '|---|---|---|---|---|']
  for name, c in s['byAuthor'].items():
    out.append('| %s | %s | %d | %d | %d |' % (
      name, c['authorClass'], c.get('rootThreads', 0), c.get('replies', 0), c.get('comments', 0)))
  return '\n'.join(out) + '\n'


def main():
  ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  ap.add_argument('--org', default='EdgeApp')
  ap.add_argument('--since', default='2025-10-23')
  ap.add_argument('--until', default='2026-10-23')
  ap.add_argument('--out', default=os.path.expanduser('~/.config/pr-review/mining'))
  ap.add_argument('--accounts', default=DEFAULT_ACCOUNTS)
  ap.add_argument('--jobs', type=int, default=4)
  ap.add_argument('--hunk-lines', type=int, default=10)
  ap.add_argument('--refresh', action='store_true', help='refetch PRs already in the cache')
  args = ap.parse_args()
  load_accounts(args.accounts)

  cache_dir = os.path.join(args.out, 'cache')
  os.makedirs(cache_dir, exist_ok=True)

  prs = list_merged_prs(args.org, args.since, args.until)
  print('merged PRs: %d in %d repos' % (len(prs), len({p['repository']['name'] for p in prs})), file=sys.stderr)

  results = {}
  failures = []
  with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
    futs = {pool.submit(cached_threads, cache_dir, args.org, pr, args.refresh): pr for pr in prs}
    for i, fut in enumerate(concurrent.futures.as_completed(futs), 1):
      pr = futs[fut]
      key = (pr['repository']['name'], pr['number'])
      try:
        results[key] = fut.result()
      except Exception as e:
        failures.append('%s#%d: %s' % (key[0], key[1], e))
      if i % 100 == 0:
        print('fetched %d/%d' % (i, len(prs)), file=sys.stderr)
  if failures:
    print('FAILED %d PRs (rerun to retry; cached PRs are skipped):' % len(failures), file=sys.stderr)
    for f in failures:
      print('  ' + f, file=sys.stderr)
    sys.exit(1)

  rows = []
  for pr in prs:
    for t in results[(pr['repository']['name'], pr['number'])]:
      rows.append(thread_row(pr, t, args.hunk_lines))

  name = 'review-threads-%s_%s.jsonl' % (args.since, args.until)
  with open(os.path.join(args.out, name), 'w') as f:
    for r in rows:
      f.write(json.dumps(r, ensure_ascii=False) + '\n')
  s = summarize(rows, prs, args)
  with open(os.path.join(args.out, 'summary.json'), 'w') as f:
    json.dump(s, f, indent=2)
  with open(os.path.join(args.out, 'summary.md'), 'w') as f:
    f.write(summary_md(s, name))

  t = s['totals']
  print('threads %d, human roots %d in %d repos, %s roots %d, bot roots %d' % (
    t.get('threads', 0), t.get('root_human', 0), s['reposWithHumanRoots'],
    OPERATOR, t.get('root_' + OPERATOR, 0), t.get('root_bot', 0)))
  print('wrote %s, summary.json, summary.md in %s' % (name, args.out))


if __name__ == '__main__':
  main()
