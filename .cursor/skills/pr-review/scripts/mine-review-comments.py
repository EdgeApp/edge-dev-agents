#!/usr/bin/env python3
"""Export a window of PR review activity from a GitHub org as JSONL.

Read-only: GitHub is read through GraphQL queries on the authenticated gh CLI
and through git fetches into local bare clones. Nothing is posted.

Stage search lists every PR created in the window (one slice per month, so no
slice nears the 1000-result search cap) plus PRs merged in the window but
created before it, in every state. Each search page carries the PR metadata,
review summaries and conversation comments for 50 PRs; a PR with more than 100
of either pages the rest (stage overflow). Stage threads fetches inline review
threads only for PRs that have them, many PRs per query through aliases, each
sized to the PR's thread count: GraphQL bills the connections a query could
return, so exact sizing is what keeps it cheap. Stage timeline reads timeline
events through repository.pullRequest, 10 PRs to a query, since search nodes
and larger batches drop events without saying so (see TIMELINE_BATCH_PRS).
Stage git fetches refs/pull/*/head into bare clones under <out>/repos/ and reads
each PR's commit list and per-file line counts there, which costs no API points.

Raw search slices, per-PR threads and timelines are cached under <out>/cache/;
a cached thread list or timeline is reused while the PR's updatedAt is
unchanged. --refresh ignores
the cache.

The gh token's hourly GraphQL budget is shared with everything else that uses
it. Every query reads its own rateLimit; when the remaining points drop below
--rate-floor, all workers pause until the reset. summary.json records the points
each stage used under apiUsage (the export makes no REST requests).

Outputs in --out:
  review-<since>_<until>.jsonl  one row per item, kind = pr, review_summary,
                                conversation or thread
  summary.json, summary.md      counts by kind, PR state, year, repo and author

Author classes come from the accounts file (--accounts, default
~/.config/pr-review/mining/accounts.json; template mining-accounts.example.json
next to this script): human (its humans), operator (its operator login, written
as that login's class name), bot (every other account, ghost included).
Accounts outside all three lists stay bot and are listed in the summary.
diffHunk keeps the hunk header plus the last --hunk-lines lines: GitHub truncates
a review comment's hunk at the commented line, so the tail is the context around
it. diffHunkFull keeps the hunk as GitHub returned it.

Usage:
  mine-review-comments.py [--org EdgeApp] [--since 2023-10-23] [--until 2026-10-23]
                          [--out ~/.config/pr-review/mining] [--accounts <file>]
                          [--jobs 4] [--rate-floor 1000] [--refresh]
"""

import argparse
import collections
import concurrent.futures
import datetime
import json
import os
import subprocess
import sys
import threading
import time

DEFAULT_ACCOUNTS = os.path.expanduser('~/.config/pr-review/mining/accounts.json')
EXAMPLE_ACCOUNTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mining-accounts.example.json')

# Filled by load_accounts() from the local accounts file, which stays off the
# public repo. humans and operator classify authors; anything else is a bot.
# knownBots only separates the expected bots from new ones in the summary.
HUMANS = set()
OPERATOR = None
KNOWN_BOTS = set()

# GraphQL budget shared by the worker threads. graphql() records each response's
# rateLimit; wait_for_budget() sleeps through the reset while remaining < floor.
RATE = {'floor': 1000, 'used': 0, 'byStage': collections.Counter(), 'shortPages': 0,
        'remaining': None, 'resetAt': None}
RATE_LOCK = threading.Lock()
RATE_LIMIT_FIELDS = 'rateLimit { cost remaining resetAt }'

# Search pages shrink to the next size when GitHub times out on a page.
SEARCH_PAGE_SIZES = (50, 25, 10)
# A thread batch stops adding PRs at this many billed connection requests
# (100 requests = 1 point) or this many aliases.
THREAD_BATCH_REQUESTS = 500
THREAD_BATCH_PRS = 25
# Timelines are read per PR through repository.pullRequest, this many to a
# query. Search nodes, node(id) reads and larger aliased batches all return
# timelines with events silently missing and no next page (13 of 28 PRs short
# at 28 to a query, none at 10, checked against single reads and REST).
TIMELINE_BATCH_PRS = 10
CACHE_VERSION = 2

# Timeline event types kept on the pr row, by GraphQL typename. Only the
# page's nodes and hasNextPage are trusted: filteredCount moves with the page
# size and totalCount counts items the API never returns.
TIMELINE_KINDS = {
  'HeadRefForcePushedEvent': 'force_push', 'ReadyForReviewEvent': 'ready_for_review',
  'ConvertToDraftEvent': 'convert_to_draft', 'ReviewRequestedEvent': 'review_requested',
  'ReviewDismissedEvent': 'review_dismissed', 'MergedEvent': 'merged',
  'ClosedEvent': 'closed', 'ReopenedEvent': 'reopened',
}

ACTOR = 'actor { login __typename }'

REVIEW_FIELDS = '''
  databaseId url state body submittedAt createdAt authorAssociation
  author { login __typename }
  commit { oid }
'''

CONVERSATION_FIELDS = '''
  databaseId url createdAt updatedAt body authorAssociation
  author { login __typename }
  reactionGroups { content users { totalCount } }
'''

TIMELINE_FIELDS = '''
  __typename
  ... on HeadRefForcePushedEvent { createdAt %(a)s beforeCommit { oid } afterCommit { oid } }
  ... on ReadyForReviewEvent { createdAt %(a)s }
  ... on ConvertToDraftEvent { createdAt %(a)s }
  ... on ReviewRequestedEvent {
    createdAt %(a)s
    requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Team { slug } }
  }
  ... on ReviewDismissedEvent { createdAt %(a)s review { databaseId } }
  ... on MergedEvent { createdAt %(a)s commit { oid } }
  ... on ClosedEvent { createdAt %(a)s }
  ... on ReopenedEvent { createdAt %(a)s }
''' % {'a': ACTOR}

# Connections on a search node that can overflow their first page, with the
# arguments and node fields used to page the rest.
# The count field is what a page's nodes are checked against: a large search
# page can come back with fewer nodes than the count and no next page.
PR_CONNECTIONS = {
  'reviews': ('', 'totalCount', REVIEW_FIELDS),
  'comments': ('', 'totalCount', CONVERSATION_FIELDS),
}

TIMELINE_ARGS = 'itemTypes: [%s]' % ', '.join(
  ''.join('_' + c if c.isupper() else c.upper() for c in t).lstrip('_') for t in TIMELINE_KINDS)


def connection(name, after=None):
  args, count, fields = PR_CONNECTIONS[name]
  parts = ['first: 100'] + (['after: $after'] if after else []) + ([args] if args else [])
  return '%s(%s) { %s pageInfo { hasNextPage endCursor } nodes { %s } }' % (name, ', '.join(parts), count, fields)


SEARCH_QUERY = '''
query($q: String!, $first: Int!, $after: String) {
  %s
  search(query: $q, type: ISSUE, first: $first, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        id number title body url state isDraft createdAt updatedAt mergedAt closedAt
        baseRefName headRefName baseRefOid headRefOid
        mergeCommit { oid }
        additions deletions changedFiles
        author { login __typename }
        repository { name isFork }
        reviewThreads { totalCount }
        commits { totalCount }
        %s
        %s
      }
    }
  }
}
''' % (RATE_LIMIT_FIELDS, connection('reviews'), connection('comments'))


def overflow_query(name):
  return '''
query($id: ID!, $after: String) {
  %s
  node(id: $id) { ... on PullRequest { %s } }
}
''' % (RATE_LIMIT_FIELDS, connection(name, after=True))


COMMENT_FIELDS = '''
  id databaseId url createdAt body authorAssociation diffHunk
  author { login __typename }
  originalCommit { oid }
  commit { oid }
  replyTo { databaseId }
  pullRequestReview { databaseId }
  reactionGroups { content users { totalCount } }
'''

THREAD_FIELDS = '''
  id isResolved isOutdated path line originalLine startLine originalStartLine
  diffSide subjectType
  resolvedBy { login }
  comments(first: 100) {
    pageInfo { hasNextPage endCursor }
    nodes { %s }
  }
''' % COMMENT_FIELDS

THREADS_QUERY = '''
query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  %s
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { %s }
      }
    }
  }
}
''' % (RATE_LIMIT_FIELDS, THREAD_FIELDS)

MORE_COMMENTS_QUERY = '''
query($id: ID!, $after: String) {
  %s
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { %s }
      }
    }
  }
}
''' % (RATE_LIMIT_FIELDS, COMMENT_FIELDS)


def load_accounts(path):
  global HUMANS, OPERATOR, KNOWN_BOTS
  if not os.path.exists(path):
    sys.exit('accounts file %s missing: copy %s there and fill in the logins' % (path, EXAMPLE_ACCOUNTS))
  with open(path) as f:
    acc = json.load(f)
  HUMANS = set(acc['humans'])
  OPERATOR = acc['operator']
  KNOWN_BOTS = {b.lower() for b in acc.get('knownBots', [])}


def parse_time(s):
  return datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))


def seed_rate_limit():
  # REST rate_limit reads do not count against either budget.
  proc = subprocess.run(['gh', 'api', 'rate_limit'], capture_output=True, text=True, check=True)
  res = json.loads(proc.stdout)['resources']
  gql = res['graphql']
  reset = datetime.datetime.fromtimestamp(gql['reset'], datetime.timezone.utc)
  with RATE_LOCK:
    RATE['remaining'] = gql['remaining']
    RATE['resetAt'] = reset.isoformat()
  print('rate limit: graphql %d/%d remaining, resets %s; rest %d/%d' % (
    gql['remaining'], gql['limit'], RATE['resetAt'], res['core']['remaining'], res['core']['limit']),
    file=sys.stderr)


def wait_for_budget():
  # Holding the lock while sleeping parks every other worker here too.
  with RATE_LOCK:
    if RATE['remaining'] is None or RATE['remaining'] >= RATE['floor']:
      return
    wait = (parse_time(RATE['resetAt']) - datetime.datetime.now(datetime.timezone.utc)).total_seconds() + 5
    print('graphql remaining %d < %d: pausing %ds until %s' % (
      RATE['remaining'], RATE['floor'], max(wait, 0), RATE['resetAt']), file=sys.stderr)
    time.sleep(max(wait, 0))
    RATE['remaining'] = None


def graphql(query, variables, stage, attempts=5, partial=False):
  # partial=True returns the data of a response that also carries errors (an
  # aliased batch where one PR is gone); the caller checks for null aliases.
  body = json.dumps({'query': query, 'variables': variables})
  for attempt in range(attempts):
    wait_for_budget()
    proc = subprocess.run(['gh', 'api', 'graphql', '--input', '-'], input=body,
                          capture_output=True, text=True)
    data = None
    try:
      data = json.loads(proc.stdout) if proc.stdout else None
    except ValueError:
      pass
    # A gateway timeout answers with an error document that has no data key.
    if data is not None and 'data' in data:
      rl = (data.get('data') or {}).pop('rateLimit', None)
      if rl:
        with RATE_LOCK:
          RATE['used'] += rl['cost']
          RATE['byStage'][stage] += rl['cost']
          RATE['remaining'] = rl['remaining']
          RATE['resetAt'] = rl['resetAt']
      if not data.get('errors') or (partial and data.get('data')):
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


def fetch_overflow(pr):
  for name, (_, count, _) in PR_CONNECTIONS.items():
    conn = pr[name]
    if not conn['pageInfo']['hasNextPage'] and len(conn['nodes']) < conn[count]:
      # Short page: refetch the whole connection on its own.
      res = graphql(overflow_query(name), {'id': pr['id'], 'after': None}, 'overflow')
      pr[name] = conn = res['node'][name]
      with RATE_LOCK:
        RATE['shortPages'] += 1
    while conn['pageInfo']['hasNextPage']:
      res = graphql(overflow_query(name), {'id': pr['id'], 'after': conn['pageInfo']['endCursor']}, 'overflow')
      nxt = res['node'][name]
      conn['nodes'].extend(nxt['nodes'])
      conn['pageInfo'] = nxt['pageInfo']


def search_slice(cache_dir, q, refresh):
  path = os.path.join(cache_dir, 'search', q.replace(' ', '_').replace(':', '-').replace('<', 'lt') + '.json')
  if not refresh and os.path.exists(path):
    with open(path) as f:
      return json.load(f)
  nodes = []
  after = None
  sizes = list(SEARCH_PAGE_SIZES)
  while True:
    try:
      res = graphql(SEARCH_QUERY, {'q': q, 'first': sizes[0], 'after': after}, 'search', attempts=2)['search']
    except RuntimeError:
      if len(sizes) == 1:
        raise
      sizes.pop(0)
      print('search %s: page timed out, retrying at %d PRs a page' % (q, sizes[0]), file=sys.stderr)
      continue
    if res['issueCount'] >= 1000:
      raise RuntimeError('search slice %s hit the 1000-result cap' % q)
    nodes.extend(n for n in res['nodes'] if n)
    if not res['pageInfo']['hasNextPage']:
      break
    after = res['pageInfo']['endCursor']
  for pr in nodes:
    fetch_overflow(pr)
  os.makedirs(os.path.dirname(path), exist_ok=True)
  write_json(path, nodes)
  return nodes


def list_prs(org, since, until, cache_dir, refresh, jobs):
  # Created in the window, plus merged in the window but created before it.
  queries = ['org:%s is:pr created:%s..%s sort:created-asc' % (org, lo, hi) for lo, hi in month_slices(since, until)]
  queries.append('org:%s is:pr merged:%s..%s created:<%s sort:created-asc' % (org, since, until, since))
  prs = {}
  with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    for nodes in pool.map(lambda q: search_slice(cache_dir, q, refresh), queries):
      for n in nodes:
        prs[(n['repository']['name'], n['number'])] = n
  return sorted(prs.values(), key=lambda p: (p['repository']['name'], p['number']))


def fetch_more_comments(threads):
  for t in threads:
    conn = t['comments']
    while conn['pageInfo']['hasNextPage']:
      more = graphql(MORE_COMMENTS_QUERY, {'id': t['id'], 'after': conn['pageInfo']['endCursor']}, 'threads')
      nxt = more['node']['comments']
      conn['nodes'].extend(nxt['nodes'])
      conn['pageInfo'] = nxt['pageInfo']


def fetch_threads(org, repo, number, after=None):
  threads = []
  while True:
    res = graphql(THREADS_QUERY, {'owner': org, 'repo': repo, 'number': number, 'after': after}, 'threads')
    page = res['repository']['pullRequest']['reviewThreads']
    threads.extend(page['nodes'])
    if not page['pageInfo']['hasNextPage']:
      break
    after = page['pageInfo']['endCursor']
  fetch_more_comments(threads)
  return threads


def fetch_thread_batch(org, prs):
  # One aliased query for several PRs, each asking for exactly its thread count.
  parts = []
  for i, pr in enumerate(prs):
    parts.append('p%d: repository(owner: %s, name: %s) { pullRequest(number: %d) { '
                 'reviewThreads(first: %d) { pageInfo { hasNextPage endCursor } nodes { %s } } } }' % (
                   i, json.dumps(org), json.dumps(pr['repository']['name']), pr['number'],
                   pr['reviewThreads']['totalCount'], THREAD_FIELDS))
  data = graphql('query { %s %s }' % (RATE_LIMIT_FIELDS, ' '.join(parts)), {}, 'threads', partial=True)
  out = {}
  for i, pr in enumerate(prs):
    repo, number = pr['repository']['name'], pr['number']
    node = (data.get('p%d' % i) or {}).get('pullRequest')
    if node is None:
      out[(repo, number)] = RuntimeError('pull request not returned')
      continue
    page = node['reviewThreads']
    threads = page['nodes']
    # A thread added after the search ran spills onto a second page.
    if page['pageInfo']['hasNextPage']:
      threads.extend(fetch_threads(org, repo, number, page['pageInfo']['endCursor']))
    elif len(threads) < pr['reviewThreads']['totalCount']:
      # A short page with no next page: read the PR on its own.
      threads = fetch_threads(org, repo, number)
      with RATE_LOCK:
        RATE['shortPages'] += 1
    fetch_more_comments(threads)
    out[(repo, number)] = threads
  return out


def thread_cache_path(cache_dir, pr):
  return os.path.join(cache_dir, '%s-%d.json' % (pr['repository']['name'], pr['number']))


def cached_threads(cache_dir, pr):
  # Entries from before the review link was fetched are bare lists: refetch them.
  return cache_entry(thread_cache_path(cache_dir, pr), pr, 'threads')


def write_json(path, data):
  tmp = path + '.tmp'
  with open(tmp, 'w') as f:
    json.dump(data, f)
  os.replace(tmp, path)


def thread_batches(prs):
  batch, requests = [], 0
  for pr in prs:
    cost = 1 + pr['reviewThreads']['totalCount']
    if batch and (requests + cost > THREAD_BATCH_REQUESTS or len(batch) == THREAD_BATCH_PRS):
      yield batch
      batch, requests = [], 0
    batch.append(pr)
    requests += cost
  if batch:
    yield batch


def all_threads(org, prs, cache_dir, refresh, jobs):
  results, failures, todo, empty = {}, [], [], 0
  for pr in prs:
    key = (pr['repository']['name'], pr['number'])
    if not pr['reviewThreads']['totalCount']:
      results[key] = []
      empty += 1
      continue
    hit = None if refresh else cached_threads(cache_dir, pr)
    if hit is None:
      todo.append(pr)
    else:
      results[key] = hit
  print('threads: %d PRs have threads, %d cached, %d to fetch' % (
    sum(1 for p in prs if p['reviewThreads']['totalCount']), len(prs) - len(todo) - empty, len(todo)), file=sys.stderr)
  by_key = {(p['repository']['name'], p['number']): p for p in todo}
  big = [p for p in todo if p['reviewThreads']['totalCount'] > 100]
  small = [p for p in todo if p['reviewThreads']['totalCount'] <= 100]
  with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    futs = [pool.submit(lambda p=p: {(p['repository']['name'], p['number']):
                                     fetch_threads(org, p['repository']['name'], p['number'])}) for p in big]
    futs += [pool.submit(fetch_thread_batch, org, b) for b in thread_batches(small)]
    for fut in concurrent.futures.as_completed(futs):
      try:
        got = fut.result()
      except Exception as e:
        failures.append('thread batch: %s' % e)
        continue
      for key, threads in got.items():
        if isinstance(threads, Exception):
          failures.append('%s#%d: %s' % (key[0], key[1], threads))
          continue
        results[key] = threads
        write_json(thread_cache_path(cache_dir, by_key[key]),
                   {'v': CACHE_VERSION, 'updatedAt': by_key[key]['updatedAt'], 'threads': threads})
  return results, failures


TIMELINE_QUERY = '''
query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  %s
  repository(owner: $owner, name: $repo) { pullRequest(number: $number) {
    timelineItems(first: 100, after: $after, %s) { pageInfo { hasNextPage endCursor } nodes { %s } }
  } }
}
''' % (RATE_LIMIT_FIELDS, TIMELINE_ARGS, TIMELINE_FIELDS)


def fetch_timeline_pages(org, repo, number, page):
  events = page['nodes']
  while page['pageInfo']['hasNextPage']:
    res = graphql(TIMELINE_QUERY, {'owner': org, 'repo': repo, 'number': number,
                                   'after': page['pageInfo']['endCursor']}, 'timeline')
    page = res['repository']['pullRequest']['timelineItems']
    events.extend(page['nodes'])
  return events


def fetch_timeline_batch(org, prs):
  parts = ['p%d: repository(owner: %s, name: %s) { pullRequest(number: %d) { '
           'timelineItems(first: 100, %s) { pageInfo { hasNextPage endCursor } nodes { %s } } } }' % (
             i, json.dumps(org), json.dumps(pr['repository']['name']), pr['number'], TIMELINE_ARGS, TIMELINE_FIELDS)
           for i, pr in enumerate(prs)]
  data = graphql('query { %s %s }' % (RATE_LIMIT_FIELDS, ' '.join(parts)), {}, 'timeline', partial=True)
  out = {}
  for i, pr in enumerate(prs):
    repo, number = pr['repository']['name'], pr['number']
    node = (data.get('p%d' % i) or {}).get('pullRequest')
    if node is None:
      out[(repo, number)] = RuntimeError('pull request not returned')
      continue
    out[(repo, number)] = fetch_timeline_pages(org, repo, number, node['timelineItems'])
  return out


def cache_entry(path, pr, field):
  if not os.path.exists(path):
    return None
  with open(path) as f:
    entry = json.load(f)
  if not isinstance(entry, dict) or entry.get('v') != CACHE_VERSION or entry.get('updatedAt') != pr['updatedAt']:
    return None
  return entry[field]


def all_timelines(org, prs, cache_dir, refresh, jobs):
  tl_dir = os.path.join(cache_dir, 'timeline')
  os.makedirs(tl_dir, exist_ok=True)
  path = lambda pr: os.path.join(tl_dir, '%s-%d.json' % (pr['repository']['name'], pr['number']))
  results, failures, todo = {}, [], []
  for pr in prs:
    hit = None if refresh else cache_entry(path(pr), pr, 'events')
    if hit is None:
      todo.append(pr)
    else:
      results[(pr['repository']['name'], pr['number'])] = hit
  print('timelines: %d cached, %d to fetch' % (len(prs) - len(todo), len(todo)), file=sys.stderr)
  by_key = {(p['repository']['name'], p['number']): p for p in todo}
  batches = [todo[i:i + TIMELINE_BATCH_PRS] for i in range(0, len(todo), TIMELINE_BATCH_PRS)]
  with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    futs = [pool.submit(fetch_timeline_batch, org, b) for b in batches]
    for fut in concurrent.futures.as_completed(futs):
      try:
        got = fut.result()
      except Exception as e:
        failures.append('timeline batch: %s' % e)
        continue
      for key, events in got.items():
        if isinstance(events, Exception):
          failures.append('%s#%d timeline: %s' % (key[0], key[1], events))
          continue
        results[key] = events
        write_json(path(by_key[key]), {'v': CACHE_VERSION, 'updatedAt': by_key[key]['updatedAt'], 'events': events})
  return results, failures


def git(repo_dir, *args, check=True):
  # gh supplies credentials for private repos; nothing here pushes.
  cmd = ['git', '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
         '--git-dir', repo_dir] + list(args)
  proc = subprocess.run(cmd, capture_output=True, text=True)
  if check and proc.returncode != 0:
    raise RuntimeError('git %s: %s' % (' '.join(args[:2]), proc.stderr.strip()[:300]))
  return proc


def sync_clone(org, repo, repos_dir):
  repo_dir = os.path.join(repos_dir, repo + '.git')
  if not os.path.exists(repo_dir):
    subprocess.run(['git', 'init', '--bare', '-q', repo_dir], check=True)
    git(repo_dir, 'remote', 'add', 'origin', 'https://github.com/%s/%s.git' % (org, repo))
  git(repo_dir, 'fetch', '-q', '--no-tags', 'origin',
      '+refs/heads/*:refs/heads/*', '+refs/pull/*/head:refs/pull/*/head')
  return repo_dir


def has_commit(repo_dir, oid):
  return git(repo_dir, 'cat-file', '-e', oid + '^{commit}', check=False).returncode == 0


def pr_git(repo_dir, pr):
  # GitHub's PR commits are the ones reachable from the head and not from the
  # base; its files are the three-dot diff against the merge base.
  base, head = pr['baseRefOid'], pr['headRefOid']
  missing = [oid for oid in (base, head) if oid and not has_commit(repo_dir, oid)]
  for oid in missing:
    git(repo_dir, 'fetch', '-q', '--no-tags', 'origin', oid, check=False)
  missing = [oid for oid in (base, head) if not oid or not has_commit(repo_dir, oid)]
  if missing:
    return {'error': 'missing objects: %s' % ', '.join(str(m) for m in missing)}
  log = git(repo_dir, 'log', '--reverse', '--format=%H%x09%cI%x09%aI%x09%P', head, '^' + base).stdout
  commits = []
  for line in log.splitlines():
    sha, committed, authored, parents = line.split('\t')
    commits.append({'sha': sha, 'committedDate': committed, 'authoredDate': authored,
                    'parents': len(parents.split())})
  files = []
  for line in git(repo_dir, 'diff', '--numstat', '%s...%s' % (base, head)).stdout.splitlines():
    add, delete, path = line.split('\t', 2)
    files.append({'path': path, 'additions': int(add) if add != '-' else 0,
                  'deletions': int(delete) if delete != '-' else 0, 'binary': add == '-'})
  return {'commits': commits, 'files': files}


def all_git(org, prs, repos_dir, jobs):
  by_repo = collections.defaultdict(list)
  for pr in prs:
    by_repo[pr['repository']['name']].append(pr)
  os.makedirs(repos_dir, exist_ok=True)
  results, failures = {}, []

  def one_repo(repo):
    repo_dir = sync_clone(org, repo, repos_dir)
    return {(repo, pr['number']): pr_git(repo_dir, pr) for pr in by_repo[repo]}

  with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    futs = {pool.submit(one_repo, repo): repo for repo in sorted(by_repo)}
    for i, fut in enumerate(concurrent.futures.as_completed(futs), 1):
      try:
        results.update(fut.result())
      except Exception as e:
        failures.append('%s: %s' % (futs[fut], e))
      if i % 10 == 0:
        print('git: %d/%d repos' % (i, len(futs)), file=sys.stderr)
  return results, failures


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


def reactions(groups):
  return {g['content']: g['users']['totalCount'] for g in groups if g['users']['totalCount']}


def trim_hunk(hunk, keep):
  if not hunk:
    return hunk
  lines = hunk.split('\n')
  header = lines[0] if lines[0].startswith('@@') else None
  body = lines[1:] if header else lines
  if len(body) <= keep:
    return hunk
  return '\n'.join(([header] if header else []) + body[-keep:])


def pr_ref(pr):
  # The PR fields every row carries, so a row reads without joining.
  pr_author = login_of(pr['author'])
  return {
    'repo': pr['repository']['name'],
    'prNumber': pr['number'],
    'prUrl': pr['url'],
    'prState': pr['state'],
    'prAuthor': pr_author,
    'prAuthorClass': author_class(pr_author),
    'prCreatedAt': pr['createdAt'],
  }


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
      'reviewId': (c.get('pullRequestReview') or {}).get('databaseId'),
      'commit': (c['commit'] or {}).get('oid'),
      'originalCommit': (c['originalCommit'] or {}).get('oid'),
      'reactions': reactions(c['reactionGroups']),
      'body': c['body'],
    })
  root = t['comments']['nodes'][0] if t['comments']['nodes'] else None
  hunk = root['diffHunk'] if root else None
  return dict(pr_ref(pr), **{
    'kind': 'thread',
    'prTitle': pr['title'],
    'prBaseRef': pr['baseRefName'],
    'prMergedAt': pr['mergedAt'],
    'prClosedAt': pr['closedAt'],
    'threadId': t['id'],
    'createdAt': comments[0]['createdAt'] if comments else None,
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
  })


def review_row(pr, r):
  login = login_of(r['author'])
  return dict(pr_ref(pr), **{
    'kind': 'review_summary',
    'reviewId': r['databaseId'],
    'url': r['url'],
    'author': login,
    'authorClass': author_class(login),
    'authorAssociation': r['authorAssociation'],
    'state': r['state'],
    # A pending review (the token owner's own draft) has no submittedAt.
    'submittedAt': r['submittedAt'],
    'createdAt': r['createdAt'],
    'commit': (r['commit'] or {}).get('oid'),
    'body': r['body'],
  })


def conversation_row(pr, c):
  login = login_of(c['author'])
  return dict(pr_ref(pr), **{
    'kind': 'conversation',
    'commentId': c['databaseId'],
    'url': c['url'],
    'author': login,
    'authorClass': author_class(login),
    'authorAssociation': c['authorAssociation'],
    'createdAt': c['createdAt'],
    'updatedAt': c['updatedAt'],
    'reactions': reactions(c['reactionGroups']),
    'body': c['body'],
  })


def timeline_event(e):
  kind = TIMELINE_KINDS[e['__typename']]
  actor = login_of(e['actor']) if e.get('actor') else None
  out = {'type': kind, 'at': e['createdAt'], 'actor': actor, 'actorClass': author_class(actor) if actor else None}
  if kind == 'force_push':
    out['before'] = (e['beforeCommit'] or {}).get('oid')
    out['after'] = (e['afterCommit'] or {}).get('oid')
  elif kind == 'review_requested':
    rr = e['requestedReviewer'] or {}
    out['reviewer'] = login_of(rr) if rr.get('login') else rr.get('slug')
  elif kind == 'review_dismissed':
    out['reviewId'] = (e['review'] or {}).get('databaseId')
  elif kind == 'merged':
    out['commit'] = (e['commit'] or {}).get('oid')
  return out


def pr_row(pr, g, thread_count):
  author = login_of(pr['author'])
  commits = g.get('commits')
  files = g.get('files')
  timeline = [timeline_event(e) for e in pr['timelineItems']['nodes'] if e['__typename'] in TIMELINE_KINDS]
  for r in pr['reviews']['nodes']:
    login = login_of(r['author'])
    timeline.append({'type': 'review', 'at': r['submittedAt'] or r['createdAt'], 'actor': login,
                     'actorClass': author_class(login), 'state': r['state'], 'reviewId': r['databaseId'],
                     'commit': (r['commit'] or {}).get('oid')})
  for c in commits or []:
    timeline.append({'type': 'commit', 'at': c['committedDate'], 'sha': c['sha']})
  # ISO timestamps with offsets: compare as datetimes, not strings.
  timeline.sort(key=lambda e: parse_time(e['at']))
  check = None
  if commits is not None:
    check = {
      'commits': len(commits) == pr['commits']['totalCount'],
      'files': len(files) == pr['changedFiles'],
      'lines': (sum(f['additions'] for f in files), sum(f['deletions'] for f in files)) ==
               (pr['additions'], pr['deletions']),
    }
  return dict(pr_ref(pr), **{
    'kind': 'pr',
    'title': pr['title'],
    'body': pr['body'],
    'isDraft': pr['isDraft'],
    'repoIsFork': pr['repository']['isFork'],
    'createdAt': pr['createdAt'],
    'updatedAt': pr['updatedAt'],
    'mergedAt': pr['mergedAt'],
    'closedAt': pr['closedAt'],
    'baseRef': pr['baseRefName'],
    'headRef': pr['headRefName'],
    'baseSha': pr['baseRefOid'],
    'headSha': pr['headRefOid'],
    'mergeCommitSha': (pr['mergeCommit'] or {}).get('oid'),
    'additions': pr['additions'],
    'deletions': pr['deletions'],
    'changedFiles': pr['changedFiles'],
    'commitCount': pr['commits']['totalCount'],
    'threadCount': thread_count,
    'reviewCount': len(pr['reviews']['nodes']),
    'conversationCount': len(pr['comments']['nodes']),
    'commits': commits,
    'files': files,
    'gitError': g.get('error'),
    'gitMatchesGitHub': check,
    'timeline': timeline,
  })


def row_time(r):
  if r['kind'] == 'review_summary':
    return r['submittedAt'] or r['createdAt']
  return r['createdAt']


def summarize(rows, args, failures):
  by_kind = collections.Counter()
  kind_state = collections.defaultdict(collections.Counter)
  kind_year = collections.defaultdict(collections.Counter)
  kind_class = collections.defaultdict(collections.Counter)
  by_repo = collections.defaultdict(collections.Counter)
  by_author = collections.defaultdict(collections.Counter)
  years = collections.defaultdict(set)
  review_states = collections.Counter()
  git_check = collections.Counter()
  git_examples = []
  threads = []

  def credit(login, field, ts):
    by_author[login][field] += 1
    if ts:
      years[login].add(ts[:4])

  for r in rows:
    kind = r['kind']
    by_kind[kind] += 1
    kind_state[kind][r['prState']] += 1
    ts = row_time(r)
    if ts:
      kind_year[kind][ts[:4]] += 1
    rc = by_repo[r['repo']]
    if kind == 'pr':
      rc['prs'] += 1
      rc['prs_' + r['prState'].lower()] += 1
      kind_class[kind][r['prAuthorClass']] += 1
      credit(r['prAuthor'], 'prsAuthored', r['createdAt'])
      chk = r['gitMatchesGitHub']
      if chk is None:
        git_check['gitError'] += 1
        if len(git_examples) < 20:
          git_examples.append('%s#%d: %s' % (r['repo'], r['prNumber'], r['gitError']))
      else:
        git_check['checked'] += 1
        for k, ok in chk.items():
          if not ok:
            git_check[k + 'Mismatch'] += 1
        if not all(chk.values()) and len(git_examples) < 20:
          git_examples.append('%s#%d: %s' % (r['repo'], r['prNumber'],
                                             ', '.join(k for k, ok in chk.items() if not ok)))
    elif kind == 'review_summary':
      rc['reviews_' + r['authorClass']] += 1
      kind_class[kind][r['authorClass']] += 1
      review_states[(r['authorClass'], r['state'], 'empty' if not r['body'].strip() else 'body')] += 1
      credit(r['author'], 'reviewSummaries', ts)
    elif kind == 'conversation':
      rc['conversation_' + r['authorClass']] += 1
      kind_class[kind][r['authorClass']] += 1
      credit(r['author'], 'conversation', ts)
    else:
      threads.append(r)
      rc['threads'] += 1
      rc['root_' + (r['rootAuthorClass'] or 'none')] += 1
      kind_class[kind][r['rootAuthorClass'] or 'none'] += 1
      if r['rootAuthor']:
        by_author[r['rootAuthor']]['threadRoots'] += 1
      for c in r['comments']:
        rc['comments_' + c['authorClass']] += 1
        credit(c['author'], 'threadComments', c['createdAt'])
  human_roots = [r for r in threads if r['rootAuthorClass'] == 'human']
  unlisted = {a: dict(c, years=sorted(years[a])) for a, c in sorted(by_author.items())
              if author_class(a) == 'bot' and a.lower() not in KNOWN_BOTS}
  return {
    'org': args.org,
    'operator': OPERATOR,
    'window': {'since': args.since, 'until': args.until},
    'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
    'byKind': dict(by_kind),
    'byKindPrState': {k: dict(v) for k, v in kind_state.items()},
    'byKindYear': {k: dict(sorted(v.items())) for k, v in kind_year.items()},
    'byKindAuthorClass': {k: dict(v) for k, v in kind_class.items()},
    'reviewStates': [{'authorClass': c, 'state': s, 'body': b, 'count': n}
                     for (c, s, b), n in sorted(review_states.items())],
    'reposWithPrs': len(by_repo),
    'reposWithHumanRoots': len({r['repo'] for r in human_roots}),
    'prsWithThreads': len({(r['repo'], r['prNumber']) for r in threads}),
    'prsWithHumanRoots': len({(r['repo'], r['prNumber']) for r in human_roots}),
    'humanRootsResolved': sum(1 for r in human_roots if r['isResolved']),
    'humanRootsOutdated': sum(1 for r in human_roots if r['isOutdated']),
    'humanRootsWithReplies': sum(1 for r in human_roots if r['replyCount']),
    'gitCheck': dict(git_check, examples=git_examples),
    'fetchFailures': failures,
    'unlistedAccountsTaggedBot': unlisted,
    'byRepo': {k: dict(v) for k, v in sorted(by_repo.items())},
    'byAuthor': {k: dict(v, authorClass=author_class(k), years=sorted(years[k])) for k, v in
                 sorted(by_author.items(), key=lambda kv: -sum(kv[1].values()))},
  }


KINDS = ('pr', 'review_summary', 'conversation', 'thread')
COUNT_FIELDS = ('prsAuthored', 'reviewSummaries', 'conversation', 'threadRoots', 'threadComments')


def summary_md(s, jsonl_name):
  op = s['operator']
  states = sorted({st for v in s['byKindPrState'].values() for st in v})
  years = sorted({y for v in s['byKindYear'].values() for y in v})
  out = [
    '# Review activity, %s PRs created or merged %s to %s' % (s['org'], s['window']['since'], s['window']['until']),
    '',
    'Export: `%s`. Generated %s.' % (jsonl_name, s['generatedAt']),
    '',
    '## Rows by kind and PR state', '',
    '| Kind | %s | Total |' % ' | '.join(states), '|---|' + '---|' * (len(states) + 1),
  ]
  for k in KINDS:
    v = s['byKindPrState'].get(k, {})
    out.append('| %s | %s | %d |' % (k, ' | '.join(str(v.get(st, 0)) for st in states), s['byKind'].get(k, 0)))
  out += ['', '## Rows by kind and year (the row\'s own timestamp)', '',
          '| Kind | %s |' % ' | '.join(years), '|---|' + '---|' * len(years)]
  for k in KINDS:
    v = s['byKindYear'].get(k, {})
    out.append('| %s | %s |' % (k, ' | '.join(str(v.get(y, 0)) for y in years)))
  out += ['', '## Rows by kind and author class', '',
          'Threads count their root comment\'s author; PRs count the PR author.', '',
          '| Kind | human | %s | bot |' % op, '|---|---|---|---|']
  for k in KINDS:
    v = s['byKindAuthorClass'].get(k, {})
    out.append('| %s | %d | %d | %d |' % (k, v.get('human', 0), v.get(op, 0), v.get('bot', 0)))
  out += ['', '## Inline threads', '',
          '| Measure | Count |', '|---|---|',
          '| PRs with any thread | %d |' % s['prsWithThreads'],
          '| PRs with a human root | %d |' % s['prsWithHumanRoots'],
          '| Repos with a human root | %d |' % s['reposWithHumanRoots'],
          '| Human roots resolved / outdated / with replies | %d / %d / %d |' % (
            s['humanRootsResolved'], s['humanRootsOutdated'], s['humanRootsWithReplies']),
          '', '## Review summaries by state', '',
          '| Author class | State | With body | Empty body |', '|---|---|---|---|']
  rs = collections.defaultdict(dict)
  for e in s['reviewStates']:
    rs[(e['authorClass'], e['state'])][e['body']] = e['count']
  for (c, st), v in sorted(rs.items()):
    out.append('| %s | %s | %d | %d |' % (c, st, v.get('body', 0), v.get('empty', 0)))
  g = s['gitCheck']
  out += ['', '## Local git against GitHub', '',
          'Commit lists and file counts come from the clones under `repos/`; GitHub\'s own totals check them.', '',
          '| Measure | Count |', '|---|---|',
          '| PRs checked | %d |' % g.get('checked', 0),
          '| Commit count differs | %d |' % g.get('commitsMismatch', 0),
          '| File count differs | %d |' % g.get('filesMismatch', 0),
          '| Line totals differ | %d |' % g.get('linesMismatch', 0),
          '| No git data (objects missing) | %d |' % g.get('gitError', 0)]
  if g['examples']:
    out += ['', 'Examples: ' + '; '.join(g['examples'])]
  usage = s.get('apiUsage', {})
  out += ['', '## API usage', '', '| Stage | GraphQL points |', '|---|---|']
  for stage, pts in usage.get('byStage', {}).items():
    out.append('| %s | %d |' % (stage, pts))
  out += ['| total | %d |' % usage.get('graphqlPoints', 0), '',
          'REST requests: %d.' % usage.get('restRequests', 0)]
  out += ['', '## Accounts outside the human, operator and named-bot lists', '',
          'Tagged bot until sorted into accounts.json.', '',
          '| Login | PRs | Review summaries | Conversation | Thread roots | Thread comments | Years |',
          '|---|---|---|---|---|---|---|']
  for name, c in s['unlistedAccountsTaggedBot'].items():
    out.append('| %s | %s | %s |' % (name, ' | '.join(str(c.get(f, 0)) for f in COUNT_FIELDS),
                                     ', '.join(c['years'])))
  out += ['', '## By repo', '',
          '| Repo | PRs | Merged | Open | Closed | Threads | Human roots | %s roots | Bot roots | '
          'Human reviews | Human conversation |' % op,
          '|---|---|---|---|---|---|---|---|---|---|---|']
  repos = sorted(s['byRepo'].items(), key=lambda kv: (-kv[1].get('root_human', 0), -kv[1].get('prs', 0), kv[0]))
  for name, c in repos:
    out.append('| %s | %s |' % (name, ' | '.join(str(c.get(f, 0)) for f in (
      'prs', 'prs_merged', 'prs_open', 'prs_closed', 'threads', 'root_human', 'root_' + op, 'root_bot',
      'reviews_human', 'conversation_human'))))
  out += ['', '## By author', '',
          '| Author | Class | PRs | Review summaries | Conversation | Thread roots | Thread comments | Years |',
          '|---|---|---|---|---|---|---|---|']
  for name, c in s['byAuthor'].items():
    out.append('| %s | %s | %s | %s |' % (name, c['authorClass'], ' | '.join(str(c.get(f, 0)) for f in COUNT_FIELDS),
                                          ', '.join(c['years'])))
  return '\n'.join(out) + '\n'


def main():
  ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  ap.add_argument('--org', default='EdgeApp')
  ap.add_argument('--since', default='2023-10-23')
  ap.add_argument('--until', default='2026-10-23')
  ap.add_argument('--out', default=os.path.expanduser('~/.config/pr-review/mining'))
  ap.add_argument('--accounts', default=DEFAULT_ACCOUNTS)
  ap.add_argument('--jobs', type=int, default=4)
  ap.add_argument('--hunk-lines', type=int, default=10)
  ap.add_argument('--rate-floor', type=int, default=1000,
                  help='pause until the reset when GraphQL points remaining drop below this')
  ap.add_argument('--refresh', action='store_true', help='refetch search slices and PRs already in the cache')
  args = ap.parse_args()
  load_accounts(args.accounts)
  RATE['floor'] = args.rate_floor
  seed_rate_limit()

  cache_dir = os.path.join(args.out, 'cache')
  os.makedirs(cache_dir, exist_ok=True)

  prs = list_prs(args.org, args.since, args.until, cache_dir, args.refresh, args.jobs)
  print('PRs: %d in %d repos (%s); search points %d' % (
    len(prs), len({p['repository']['name'] for p in prs}),
    ', '.join('%s %d' % kv for kv in sorted(collections.Counter(p['state'] for p in prs).items())),
    RATE['used']), file=sys.stderr)

  threads, failures = all_threads(args.org, prs, cache_dir, args.refresh, args.jobs)
  print('threads fetched; points so far %d' % RATE['used'], file=sys.stderr)
  if failures:
    print('FAILED %d thread fetches (rerun to retry; cached PRs are skipped):' % len(failures), file=sys.stderr)
    for f in failures:
      print('  ' + f, file=sys.stderr)
    sys.exit(1)

  timelines, tl_failures = all_timelines(args.org, prs, cache_dir, args.refresh, args.jobs)
  print('timelines fetched; points so far %d' % RATE['used'], file=sys.stderr)
  if tl_failures:
    print('FAILED %d timeline fetches (rerun to retry; cached PRs are skipped):' % len(tl_failures), file=sys.stderr)
    for f in tl_failures:
      print('  ' + f, file=sys.stderr)
    sys.exit(1)
  for pr in prs:
    pr['timelineItems'] = {'nodes': timelines[(pr['repository']['name'], pr['number'])]}

  gits, git_failures = all_git(args.org, prs, os.path.join(args.out, 'repos'), args.jobs)
  if git_failures:
    print('FAILED %d repo clones or fetches:' % len(git_failures), file=sys.stderr)
    for f in git_failures:
      print('  ' + f, file=sys.stderr)
    sys.exit(1)

  rows = []
  for pr in prs:
    key = (pr['repository']['name'], pr['number'])
    rows.append(pr_row(pr, gits[key], len(threads[key])))
    rows.extend(review_row(pr, r) for r in pr['reviews']['nodes'])
    rows.extend(conversation_row(pr, c) for c in pr['comments']['nodes'])
    rows.extend(thread_row(pr, t, args.hunk_lines) for t in threads[key])

  name = 'review-%s_%s.jsonl' % (args.since, args.until)
  with open(os.path.join(args.out, name), 'w') as f:
    for r in rows:
      f.write(json.dumps(r, ensure_ascii=False) + '\n')
  s = summarize(rows, args, failures)
  s['apiUsage'] = {'graphqlPoints': RATE['used'], 'byStage': dict(RATE['byStage']), 'restRequests': 0,
                   'shortSearchConnectionsRefetched': RATE['shortPages']}
  with open(os.path.join(args.out, 'summary.json'), 'w') as f:
    json.dump(s, f, indent=2)
  with open(os.path.join(args.out, 'summary.md'), 'w') as f:
    f.write(summary_md(s, name))

  print('rows: %s' % ', '.join('%s %d' % (k, s['byKind'].get(k, 0)) for k in KINDS))
  print('human roots %d in %d repos; unlisted accounts %d' % (
    s['byKindAuthorClass'].get('thread', {}).get('human', 0), s['reposWithHumanRoots'],
    len(s['unlistedAccountsTaggedBot'])))
  g = s['gitCheck']
  print('git: %d checked, commit/file/line mismatches %d/%d/%d, no data %d' % (
    g.get('checked', 0), g.get('commitsMismatch', 0), g.get('filesMismatch', 0),
    g.get('linesMismatch', 0), g.get('gitError', 0)))
  print('graphql points used %d (%s), REST requests 0' % (
    RATE['used'], ', '.join('%s %d' % kv for kv in RATE['byStage'].items())))
  print('wrote %s, summary.json, summary.md in %s' % (name, args.out))


if __name__ == '__main__':
  main()
