#!/usr/bin/env python3
"""Build an offline replay snapshot of a past PR as it looked when it was first reviewed.

Usage:
  replay-snapshot.py --repo <name> --pr <N> [--force] [--no-gh] [--base <sha>]

Output (one directory per PR, nothing else is written outside it except the clone and the gh cache):
  ~/.config/pr-review/replay/snapshots/<repo>-<N>/repo/       self-contained git repo, no remote, no alternates
                                                         branches replay/base and replay/head (checked out)
  ~/.config/pr-review/replay/snapshots/<repo>-<N>/meta.json   PR context as of the first review

The first-reviewed commit X is the commit the first human review was left on (the
originalCommit of the earliest inline comment, or the commit of a review summary when the
newer review export carries one). With no human review it is the commit the first review of
any kind landed on, else the final head. The snapshot holds the base commit plus the PR's
commits up to X, with trees byte-identical to the originals (checked), and no later history.

Clones are bare repos under ~/.config/pr-review/mining/repos/<repo>.git (the layout the
mining export uses); this script only adds refs under refs/replay/. It never pushes and never
writes to a remote. The only GitHub API use is one read-only GraphQL query per PR for the
title, description (as of the first review) and creation data, cached under
~/.config/pr-review/replay/cache/; --no-gh skips it.

The review rules are mined from every PR in the 2023-10-23 to 2026-10-23 export, so a
replay that measures them scores PRs opened after 2026-10-23.
"""

import argparse
import datetime
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

HOME = os.path.expanduser('~')
MINING = os.path.join(HOME, '.config/pr-review/mining')
REPLAY = os.path.join(HOME, '.config/pr-review/replay')
OWNER = 'EdgeApp'
SQUASH_OVER = 200


def die(msg):
  print('replay-snapshot: ' + msg, file=sys.stderr)
  sys.exit(1)


def git(gitdir, *args, env=None, input=None, check=True):
  r = subprocess.run(['git', '--git-dir', gitdir] + list(args), capture_output=True, env=env,
                     input=input)
  if check and r.returncode != 0:
    die('git %s failed: %s' % (' '.join(args[:3]), r.stderr.decode(errors='replace').strip()))
  return r


def out(gitdir, *args, **kw):
  return git(gitdir, *args, **kw).stdout.decode().strip()


def has_commit(gitdir, sha):
  return git(gitdir, 'cat-file', '-e', sha + '^{commit}', check=False).returncode == 0


def load_accounts():
  try:
    return json.load(open(os.path.join(MINING, 'accounts.json')))
  except OSError:
    return {'humans': [], 'knownBots': []}


def pr_rows(repo, pr):
  """Thread rows from the one-year export plus any kind-tagged rows from the newer export."""
  threads, extra = [], []
  for path in sorted(glob.glob(os.path.join(MINING, 'review-*.jsonl'))):
    with open(path) as f:
      for line in f:
        try:
          r = json.loads(line)
        except ValueError:
          continue
        if r.get('repo') != repo or (r.get('prNumber') or r.get('number')) != pr:
          continue
        if 'kind' in r and r['kind'] != 'thread':
          extra.append(r)
        else:
          threads.append(r)
  return threads, extra


def review_events(threads, extra, pr_author, accounts):
  """Every review item as (time, author, class, commit, source)."""
  humans = set(accounts.get('humans', []))
  events = []
  for t in threads:
    for c in t.get('comments', []):
      commit = c.get('originalCommit') or c.get('commit')
      if c.get('author') and commit and c.get('createdAt'):
        events.append((c['createdAt'], c['author'], c.get('authorClass', ''), commit, 'inline'))
  for r in extra:
    if r.get('kind') != 'review_summary':
      continue
    commit = r.get('commit') or r.get('commitOid') or r.get('reviewCommit')
    if isinstance(commit, dict):
      commit = commit.get('oid')
    at = r.get('submittedAt') or r.get('createdAt')
    author = r.get('author')
    if isinstance(author, dict):
      author = author.get('login')
    if author and commit and at:
      cls = r.get('authorClass') or ('human' if author in humans else '')
      events.append((at, author, cls, commit, 'review_summary'))
  events = [e for e in events if e[1] != pr_author]
  events.sort()
  return events


def pr_meta_row(extra):
  for r in extra:
    if r.get('kind') == 'pr':
      return r
  return None


def gh_meta(repo, pr, use_gh):
  cache = os.path.join(REPLAY, 'cache', '%s-%d.json' % (repo, pr))
  if os.path.exists(cache):
    return json.load(open(cache))
  if not use_gh:
    return None
  q = ('query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){'
       'title body author{login} createdAt lastEditedAt baseRefName baseRefOid headRefName headRefOid '
       'mergeCommit{oid} commits(first:1){totalCount nodes{commit{oid}}} '
       'userContentEdits(first:100){totalCount nodes{editedAt diff}}}}}')
  r = subprocess.run(['gh', 'api', 'graphql', '-f', 'query=' + q, '-F', 'o=' + OWNER,
                      '-F', 'n=' + repo, '-F', 'p=%d' % pr], capture_output=True, text=True)
  if r.returncode != 0:
    die('gh graphql failed: ' + r.stderr.strip())
  data = json.loads(r.stdout)['data']['repository']['pullRequest']
  os.makedirs(os.path.dirname(cache), exist_ok=True)
  with open(cache, 'w') as f:
    json.dump(data, f)
  return data


def body_as_of(meta, at):
  """The PR description as it read at time `at` (ISO). None when unknowable."""
  if meta is None:
    return None, 'unavailable'
  if not meta.get('lastEditedAt') or meta['lastEditedAt'] <= at:
    return meta.get('body') or '', 'current'
  edits = (meta.get('userContentEdits') or {}).get('nodes') or []
  total = (meta.get('userContentEdits') or {}).get('totalCount', len(edits))
  prior = [e for e in edits if e.get('editedAt') and e['editedAt'] <= at and e.get('diff') is not None]
  if prior:
    return max(prior, key=lambda e: e['editedAt'])['diff'], 'edit-history'
  if total > len(edits):
    return None, 'edit-history-truncated'
  return None, 'no-version-before-review'


def ensure_clone(repo):
  root = os.path.join(MINING, 'repos')
  gitdir = os.path.join(root, repo + '.git')
  if os.path.isdir(gitdir):
    return gitdir
  os.makedirs(root, exist_ok=True)
  tmp = tempfile.mkdtemp(prefix='.%s.' % repo, dir=root)
  r = subprocess.run(['git', 'clone', '--bare', '--quiet', 'https://github.com/%s/%s.git' % (OWNER, repo),
                      tmp + '/c.git'], capture_output=True, text=True)
  if r.returncode != 0:
    shutil.rmtree(tmp, ignore_errors=True)
    die('clone failed: ' + r.stderr.strip())
  try:
    os.rename(tmp + '/c.git', gitdir)
  except OSError:
    pass  # a parallel clone won the race; use it
  shutil.rmtree(tmp, ignore_errors=True)
  return gitdir


def fetch(gitdir, pr, base_ref, shas):
  specs = ['+refs/pull/%d/head:refs/replay/pull/%d/head' % (pr, pr),
           '+refs/heads/%s:refs/replay/base/%s' % (base_ref, base_ref)]
  for attempt in range(3):
    r = git(gitdir, 'fetch', '--quiet', '--no-tags', 'https://github.com/%s/%s.git' % (OWNER, os.path.basename(gitdir)[:-4]),
            *specs, check=False)
    if r.returncode == 0:
      break
  else:
    die('fetch failed: ' + r.stderr.decode(errors='replace').strip())
  missing = [s for s in shas if s and not has_commit(gitdir, s)]
  if missing:
    url = 'https://github.com/%s/%s.git' % (OWNER, os.path.basename(gitdir)[:-4])
    git(gitdir, 'fetch', '--quiet', '--no-tags', url,
        *['+%s:refs/replay/sha/%s' % (s, s) for s in missing], check=False)


def pick_base(gitdir, x, base_tip, meta):
  """The base commit the PR forked from, as of X."""
  if git(gitdir, 'merge-base', '--is-ancestor', x, base_tip, check=False).returncode != 0:
    return out(gitdir, 'merge-base', x, base_tip), 'merge-base(X, base tip)'
  # X was merged into the base branch. Find the first-parent commit that brought it in.
  chain = out(gitdir, 'rev-list', '--first-parent', '--ancestry-path', '%s..%s' % (x, base_tip)).split()
  if chain:
    m = chain[-1]
    parents = out(gitdir, 'rev-list', '--parents', '-n', '1', m).split()[1:]
    if parents[0] != x and len(parents) > 1:
      return out(gitdir, 'merge-base', x, parents[0]), 'merge-base(X, merge^1)'
  # Fast-forward or rebase merge: X sits on the base branch's first-parent line.
  first = meta and (meta.get('commits') or {}).get('nodes')
  if first:
    c = first[0]['commit']['oid']
    if has_commit(gitdir, c) and git(gitdir, 'merge-base', '--is-ancestor', c, x, check=False).returncode == 0:
      return out(gitdir, 'rev-parse', c + '^'), 'parent of first PR commit'
  die('X is on the base branch first-parent line and the PR first commit is unknown; pass --base')


def copy_objects(gitdir, snap_git, commits):
  """Copy every tree and blob reachable from the commits' trees (no history) into the snapshot."""
  objs = set()
  for c in commits:
    lst = out(gitdir, 'rev-list', '--objects', '--no-walk', c).split('\n')
    for line in lst:
      sha = line.split(' ', 1)[0]
      if sha and sha != c:
        objs.add(sha)
  pack = git(gitdir, 'pack-objects', '--stdout', '-q', input=('\n'.join(sorted(objs)) + '\n').encode()).stdout
  git(snap_git, 'index-pack', '--stdin', '--fix-thin', input=pack)


def commit_env(gitdir, c):
  fmt = out(gitdir, 'show', '-s', '--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI', c).split('\x00')
  env = dict(os.environ)
  env.update(GIT_AUTHOR_NAME=fmt[0], GIT_AUTHOR_EMAIL=fmt[1], GIT_AUTHOR_DATE=fmt[2],
             GIT_COMMITTER_NAME=fmt[3], GIT_COMMITTER_EMAIL=fmt[4], GIT_COMMITTER_DATE=fmt[5])
  return env


def main():
  ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  ap.add_argument('--repo', required=True)
  ap.add_argument('--pr', required=True, type=int)
  ap.add_argument('--force', action='store_true', help='rebuild an existing snapshot')
  ap.add_argument('--no-gh', action='store_true', help='skip the GraphQL metadata query')
  ap.add_argument('--base', help='override the base commit')
  a = ap.parse_args()

  dest = os.path.join(REPLAY, 'snapshots', '%s-%d' % (a.repo, a.pr))
  if os.path.exists(dest):
    if not a.force:
      print(json.dumps({'snapshot': dest, 'status': 'exists'}))
      return
    shutil.rmtree(dest)

  accounts = load_accounts()
  threads, extra = pr_rows(a.repo, a.pr)
  prow = pr_meta_row(extra)
  if not threads and not prow:
    die('%s#%d not found in the mining export' % (a.repo, a.pr))
  first = threads[0] if threads else {}
  pr_author = first.get('prAuthor') or (prow or {}).get('author')
  base_ref = first.get('prBaseRef') or (prow or {}).get('baseRefName')
  meta = gh_meta(a.repo, a.pr, not a.no_gh)
  if meta:
    pr_author = pr_author or (meta.get('author') or {}).get('login')
    base_ref = base_ref or meta.get('baseRefName')
  if not base_ref:
    die('base branch unknown')

  events = review_events(threads, extra, pr_author, accounts)
  human = [e for e in events if e[2] == 'human']
  if human:
    first_review, rule = human[0], 'first human review'
  elif events:
    first_review, rule = events[0], 'first review of any kind'
  else:
    first_review, rule = None, 'final head (no review)'

  gitdir = ensure_clone(a.repo)
  fetch(gitdir, a.pr, base_ref, [first_review[3] if first_review else None])
  base_tip = 'refs/replay/base/' + base_ref
  x = first_review[3] if first_review else out(gitdir, 'rev-parse', 'refs/replay/pull/%d/head' % a.pr)
  if not has_commit(gitdir, x):
    die('first-reviewed commit %s is not fetchable' % x)
  x = out(gitdir, 'rev-parse', x + '^{commit}')
  base, base_rule = (a.base, '--base') if a.base else pick_base(gitdir, x, base_tip, meta)
  base = out(gitdir, 'rev-parse', base + '^{commit}')

  rng = out(gitdir, 'rev-list', '--reverse', '--topo-order', '--parents', x, '^' + base).split('\n')
  rng = [l.split() for l in rng if l]
  if not rng:
    die('empty PR range %s..%s' % (base[:8], x[:8]))
  squash = len(rng) > SQUASH_OVER or any(len(p) > 2 for p in rng)
  commits = [rng[-1][0]] if squash else [p[0] for p in rng]

  os.makedirs(dest)
  work = os.path.join(dest, 'repo')
  subprocess.run(['git', 'init', '-q', '-b', 'replay/head', work], check=True)
  snap = os.path.join(work, '.git')
  copy_objects(gitdir, snap, [base] + commits)

  msg_base = 'Replay base for %s#%d\n\nOriginal base commit: %s\n' % (a.repo, a.pr, base)
  head = out(snap, 'commit-tree', out(gitdir, 'rev-parse', base + '^{tree}'), env=commit_env(gitdir, base),
             input=msg_base.encode())
  snap_base = head
  for c in commits:
    tree = out(gitdir, 'rev-parse', c + '^{tree}')
    msg = git(gitdir, 'show', '-s', '--format=%B', c).stdout
    if squash:
      msg = ('%s#%d squashed to its first-reviewed commit (%d commits, merges inside)\n\n' %
             (a.repo, a.pr, len(rng))).encode() + msg
    head = out(snap, 'commit-tree', tree, '-p', head, env=commit_env(gitdir, c), input=msg)
  git(snap, 'update-ref', 'refs/heads/replay/base', snap_base)
  git(snap, 'update-ref', 'refs/heads/replay/head', head)
  subprocess.run(['git', '-C', work, 'config', 'user.name', 'replay'], check=True)
  subprocess.run(['git', '-C', work, 'config', 'user.email', 'replay@localhost'], check=True)
  subprocess.run(['git', '-C', work, 'checkout', '-q', '-f', 'replay/head'], check=True)

  # Integrity: trees match the originals, and nothing beyond the snapshot is reachable.
  for ours, theirs in ((snap_base, base), (head, x)):
    if out(snap, 'rev-parse', ours + '^{tree}') != out(gitdir, 'rev-parse', theirs + '^{tree}'):
      die('tree mismatch for %s' % theirs)
  if git(snap, 'remote', check=False).stdout.strip() or os.path.exists(os.path.join(snap, 'objects/info/alternates')):
    die('snapshot has a remote or alternates')
  fsck = git(snap, 'fsck', '--connectivity-only', '--no-dangling', check=False)
  if fsck.returncode != 0:
    die('fsck failed: ' + fsck.stderr.decode(errors='replace'))

  stat = out(snap, 'diff', '--shortstat', 'replay/base', 'replay/head')
  files = out(snap, 'diff', '--name-only', 'replay/base', 'replay/head').split('\n')
  at = first_review[0] if first_review else None
  body, body_src = (prow.get('body'), 'export') if prow and prow.get('body') is not None and not at else \
    body_as_of(meta, at or '9999')
  info = {
    'schema': 'pr-review-replay-snapshot/1',
    'repo': a.repo, 'owner': OWNER, 'pr': a.pr,
    'title': first.get('prTitle') or (meta or {}).get('title') or (prow or {}).get('title'),
    'body': body, 'bodySource': body_src,
    'author': pr_author, 'baseRef': base_ref,
    'createdAt': (meta or {}).get('createdAt'),
    'firstReviewedCommit': x, 'baseCommit': base, 'baseRule': base_rule,
    'firstReview': {'rule': rule, 'at': at, 'author': first_review[1] if first_review else None,
                    'source': first_review[4] if first_review else None},
    'snapshot': {'base': snap_base, 'head': head, 'commits': len(commits), 'originalCommits': len(rng),
                 'squashed': squash, 'files': len([f for f in files if f]), 'shortstat': stat},
    'builtAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
  }
  with open(os.path.join(dest, 'meta.json'), 'w') as f:
    json.dump(info, f, indent=2)
  print(json.dumps({'snapshot': dest, 'x': x[:10], 'base': base[:10], 'baseRule': base_rule, 'rule': rule,
                    'commits': len(commits), 'files': info['snapshot']['files'], 'stat': stat,
                    'bodySource': body_src}))


if __name__ == '__main__':
  main()
