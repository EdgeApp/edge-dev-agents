#!/usr/bin/env python3
"""Contract tests for the two "watch/grade the RIGHT thing" resolvers:

  1. resolve-run.sh transcript discovery (--transcript-only): the run's newest
     SEGMENT, identified by the gid on a run-identity record in the opening
     records, never a chat fork and never ordered by mtime.
  2. watch-pr.sh repo resolution + the reviewer-bot gate: the repo is taken from
     the task's attached PR, never guessed from cwd, and every reviewer bot the
     Complete gate counts is judged separately.

Run: python3 ~/.config/agent-watcher/hooks/tests/transcript-discovery-and-watch-repo.test.py

Override RESOLVE_RUN_SH / WATCH_PR_SH to exercise a staged copy before install.
"""
import json, os, shutil, subprocess, sys, tempfile, time

HOME = os.path.expanduser('~')
RESOLVE_RUN = os.environ.get('RESOLVE_RUN_SH', f'{HOME}/.cursor/skills/resolve-run/scripts/resolve-run.sh')
WATCH_PR = os.environ.get('WATCH_PR_SH', f'{HOME}/.cursor/skills/one-shot/scripts/watch-pr.sh')

fails = []


def check(name, ok, detail=''):
    print(('ok   ' if ok else 'FAIL ') + name)
    if not ok:
        if detail:
            print('       ' + str(detail).replace('\n', '\n       ')[:900])
        fails.append(name)


# ---------------------------------------------------------------- fixtures ---
PROJ = 'https://app.asana.com/0/1215088146871429'


def rec(**kw):
    return json.dumps(kw)


def transcript(path, gid, *, signature=True, url_shape='plain', head_pad=0,
               last_ts='2026-09-01T00:00:00.000Z', mtime=None, gid_anchored=True,
               gid_list=None):
    """Write a fixture session transcript.

    signature   carry the `/one-shot --yolo` run signature in the head
    url_shape   plain | ellipsis (the newer app.asana.com/1/.../task/ rendering)
    head_pad    bytes of filler BEFORE the identity records (pushes every URL
                past the first 16KB, the shape that used to resolve to nothing)
    gid_anchored  put the gid on a run-identity record; False puts it only in a
                  bare list of gids, which must NOT make this file a candidate
    """
    lines = [rec(type='mode', mode='bypassPermissions')]
    if head_pad:
        lines.append(rec(type='attachment', hookName='SessionStart:startup',
                         stdout='x' * head_pad))
    url = f'{PROJ}/{gid}' if url_shape == 'plain' else 'app.asana.com/1/.../task/'
    if gid_anchored:
        lines.append(rec(type='attachment', stdout=f'[run-context refresh]\nTask gid: {gid}\nTask: fixture\n'))
    if gid_list:
        lines.append(rec(type='assistant', text='\n'.join(gid_list)))
    if signature:
        lines.append(rec(type='last-prompt', lastPrompt=f'/one-shot --yolo {url}'))
        lines.append(rec(type='user', message={'role': 'user', 'content':
                     f'<command-message>one-shot</command-message>\n<command-name>/one-shot</command-name>\n<command-args>--yolo {url}</command-args>'}))
    else:
        lines.append(rec(type='user', message={'role': 'user', 'content':
                     f'<command-args>chat fork about {url}</command-args>'}))
    lines.append(rec(type='assistant', timestamp=last_ts, text='done'))
    with open(path, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    if mtime:
        os.utime(path, (mtime, mtime))


def find_transcript(projects_dir, gid):
    env = dict(os.environ, PROJECTS_DIR=projects_dir)
    p = subprocess.run(['bash', RESOLVE_RUN, '--gid', gid, '--transcript-only'],
                       capture_output=True, text=True, env=env)
    return p.stdout.strip(), p


# ------------------------------------------------- 1. transcript discovery ---
tdir = tempfile.mkdtemp(prefix='resolve-run-fixtures-')
pdir = os.path.join(tdir, '-Users-eddy-git')
os.makedirs(pdir)
NOW = time.time()

# (a) no asana URL anywhere in the first 16KB
a = os.path.join(pdir, 'aaaaaaaa-no-url-in-16kb.jsonl')
transcript(a, '1000000000001', head_pad=20000, last_ts='2026-09-10T10:00:00.000Z')
got, p = find_transcript(tdir, '1000000000001')
check('no URL in the first 16KB: the run still resolves', got == a, got or p.stderr)

# (b) ellipsis-rendered URL carries no gid; the identity record does
b = os.path.join(pdir, 'bbbbbbbb-ellipsis-url.jsonl')
transcript(b, '1000000000002', url_shape='ellipsis', last_ts='2026-09-11T10:00:00.000Z')
got, p = find_transcript(tdir, '1000000000002')
check('ellipsis-rendered asana URL: the run still resolves', got == b, got or p.stderr)

# (c) two segments of one run: the OLDER segment was rewritten later (newer
#     mtime); the newer segment must win on its last record
old_seg = os.path.join(pdir, 'cccccccc-old-segment.jsonl')
new_seg = os.path.join(pdir, 'dddddddd-new-segment.jsonl')
transcript(old_seg, '1000000000003', last_ts='2026-08-14T12:00:00.000Z', mtime=NOW)
transcript(new_seg, '1000000000003', last_ts='2026-09-16T17:29:00.000Z', mtime=NOW - 86400)
got, p = find_transcript(tdir, '1000000000003')
check('two candidates: newest LAST RECORD wins over newest mtime', got == new_seg, got or p.stderr)

# (d) a chat fork carries the gid and the newest last record, but no /one-shot
run = os.path.join(pdir, 'eeeeeeee-the-run.jsonl')
fork = os.path.join(pdir, 'ffffffff-chat-fork.jsonl')
transcript(run, '1000000000004', last_ts='2026-09-15T08:00:00.000Z')
transcript(fork, '1000000000004', signature=False, last_ts='2026-09-16T20:00:00.000Z', mtime=NOW)
got, p = find_transcript(tdir, '1000000000004')
check('chat fork with the newest activity is never graded as the run', got == run, got or p.stderr)

# (e) a bare list of gids in the head is a mention, not an identity
other = os.path.join(pdir, 'gggggggg-lists-many-gids.jsonl')
transcript(other, '1000000000005', gid_list=['1000000000006', '1000000000007'],
           last_ts='2026-09-16T21:00:00.000Z', mtime=NOW)
got, p = find_transcript(tdir, '1000000000006')
check('a gid merely LISTED in the head does not claim that run', got == '', got or p.stderr)
got, p = find_transcript(tdir, '1000000000005')
check('the listing session still resolves for its own gid', got == other, got or p.stderr)

got, p = find_transcript(tdir, '1000000000099')
check('unknown gid resolves to nothing, exit 0', got == '' and p.returncode == 0, p.stderr)
shutil.rmtree(tdir, ignore_errors=True)

# --------------------------------------------- 2. watch-pr repo resolution ---
GID = '9999999999999'
WAIVER = f'/tmp/agent-bot-unavailable-{GID}'
GREEN = json.dumps([{'name': 'Travis CI - Pull Request', 'bucket': 'pass'},
                    {'name': 'Cursor Bugbot', 'bucket': 'pass'},
                    {'name': 'Cursor Security Agent: Security Reviewer', 'bucket': 'pass'}])

GH_STUB = r'''#!/usr/bin/env bash
ARGS="$*"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "$STUB_CWD_REPO"; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  NUM="$3"; R=""
  while [ $# -gt 0 ]; do case "$1" in --repo) R="$2"; shift 2 ;; *) shift ;; esac; done
  case " $STUB_PRS " in *" $R#$NUM "*) ;; *) echo "no PR #$NUM in $R" >&2; exit 1 ;; esac
  case "$ARGS" in
    *headRefOid*) echo "deadbeefcafe1234" ;;
    *isDraft,commits*) echo "{\"d\":${STUB_IS_DRAFT:-false},\"m\":\"feat: fixture\"}" ;;
    *isDraft*) echo "${STUB_IS_DRAFT:-false}" ;;
    *) echo "$NUM" ;;
  esac
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then echo "$STUB_CHECKS"; exit 0; fi
if [ "$1" = "api" ]; then echo "${STUB_REVIEW_COUNT:-0}"; exit 0; fi
exit 1
'''
CURL_STUB = r'''#!/usr/bin/env bash
URL=""
for a in "$@"; do case "$a" in https://app.asana.com/*) URL="$a" ;; esac; done
echo "$URL" >> "$STUB_CURL_LOG"
case "$URL" in
  */subtasks*) echo "{\"data\":[]}" ;;
  */attachments*) echo "${STUB_ATTACHMENTS:-{\"data\":[]}}" ;;
  *) echo "{\"data\":[]}" ;;
esac
exit 0
'''

wdir = tempfile.mkdtemp(prefix='watch-pr-stubs-')
bindir = os.path.join(wdir, 'bin')
os.makedirs(bindir)
for name, body in (('gh', GH_STUB), ('curl', CURL_STUB)):
    path = os.path.join(bindir, name)
    with open(path, 'w') as fh:
        fh.write(body)
    os.chmod(path, 0o755)
repo_cwd = os.path.join(wdir, 'worktree')
os.makedirs(repo_cwd)
subprocess.run(['git', 'init', '-q', repo_cwd], capture_output=True)
bare_cwd = os.path.join(wdir, 'not-a-repo')
os.makedirs(bare_cwd)
ATTACH_GUI = json.dumps({'data': [{'view_url': 'https://github.com/EdgeApp/edge-react-gui/pull/6021'}]})


def watch(args, *, cwd=repo_cwd, checks=GREEN, prs='EdgeApp/edge-react-gui#6021',
          cwd_repo='EdgeApp/edge-currency-accountbased', attachments='{"data":[]}', **extra):
    log = os.path.join(wdir, 'curl.log')
    open(log, 'w').close()
    env = dict(os.environ,
               PATH=bindir + os.pathsep + os.environ['PATH'],
               HOME=wdir, ASANA_TOKEN='fixture-token',
               STUB_CWD_REPO=cwd_repo, STUB_PRS=prs, STUB_CHECKS=checks,
               STUB_ATTACHMENTS=attachments, STUB_CURL_LOG=log)
    env.update({k: str(v) for k, v in extra.items()})
    for f in (WAIVER, f'/tmp/agent-watch-budget-{GID}-EdgeApp-edge-react-gui-pr6021'):
        if os.path.exists(f):
            os.remove(f)
    p = subprocess.run(['bash', WATCH_PR] + args, capture_output=True, text=True, cwd=cwd, env=env)
    p.curl_log = open(log).read()
    return p


p = watch(['--pr', '6021', '--task-gid', GID], attachments=ATTACH_GUI)
check('task attachment beats cwd: the gui PR is watched from an accb worktree',
      p.returncode == 0 and 'RESULT: green' in p.stdout
      and 'EdgeApp/edge-react-gui' in p.stderr and 'cwd is EdgeApp/edge-currency-accountbased' in p.stderr,
      p.stdout + p.stderr)

p = watch(['--pr', '1055', '--task-gid', GID], attachments=ATTACH_GUI,
          prs='EdgeApp/edge-currency-accountbased#1055')
check('task attaches no PR of that number: refuse, name --repo',
      p.returncode == 2 and '--repo' in p.stderr and 'RESULT' not in p.stdout, p.stdout + p.stderr)

p = watch(['--pr', '6021', '--task-gid', GID], prs='')
check('cwd repo has no PR of that number: refuse, name --repo',
      p.returncode == 2 and 'has no PR #6021' in p.stderr, p.stdout + p.stderr)

p = watch(['--pr', '6021'], cwd_repo='EdgeApp/edge-react-gui')
check('cwd fallback allowed only when the cwd repo really has the PR',
      p.returncode == 0 and 'source: cwd' in p.stderr, p.stdout + p.stderr)

p = watch(['--pr', '6021', '--repo', 'EdgeApp/edge-react-gui', '--task-gid', GID], attachments=ATTACH_GUI)
check('--repo wins outright and costs no Asana lookup',
      p.returncode == 0 and 'source: --repo' in p.stderr and p.curl_log.strip() == '', p.stderr + p.curl_log)

p = watch(['--pr', '6021'], cwd=bare_cwd, cwd_repo='')
check('no repo anywhere: refuse instead of letting gh infer one',
      p.returncode == 2 and '--repo' in p.stderr, p.stdout + p.stderr)

# ------------------------------------------------- reviewer-bot alternation ---
ONLY_BUGBOT = json.dumps([{'name': 'Travis CI - Pull Request', 'bucket': 'pass'},
                          {'name': 'Cursor Bugbot', 'bucket': 'pass'}])
BUGBOT_SKIPPED = json.dumps([{'name': 'Travis CI - Pull Request', 'bucket': 'pass'},
                             {'name': 'Cursor Bugbot', 'bucket': 'skipping'},
                             {'name': 'Cursor Security Agent: Security Reviewer', 'bucket': 'pass'}])
NEITHER = json.dumps([{'name': 'Travis CI - Pull Request', 'bucket': 'pass'}])

p = watch(['--pr', '6021', '--repo', 'EdgeApp/edge-react-gui', '--task-gid', GID], checks=GREEN)
check('both reviewer bots clean: plain green, no unavailable note',
      'RESULT: green' in p.stdout and 'reviewer-unavailable' not in p.stdout, p.stdout)

p = watch(['--pr', '6021', '--repo', 'EdgeApp/edge-react-gui', '--task-gid', GID], checks=ONLY_BUGBOT)
waiver = open(WAIVER).read() if os.path.exists(WAIVER) else ''
check('security reviewer missing while bugbot is clean: named unavailable',
      'reviewer-unavailable:Cursor Security(no check-run)' in p.stdout
      and 'Cursor Bugbot' not in p.stdout and 'Cursor Security' in waiver, p.stdout + '|' + waiver)

p = watch(['--pr', '6021', '--repo', 'EdgeApp/edge-react-gui', '--task-gid', GID],
          checks=BUGBOT_SKIPPED, STUB_REVIEW_COUNT=1)
check('one reviewer skipped, the other clean: the per-login review probe cannot clear it',
      'reviewer-unavailable:Cursor Bugbot(check-run skipped)' in p.stdout, p.stdout)

p = watch(['--pr', '6021', '--repo', 'EdgeApp/edge-react-gui', '--task-gid', GID],
          checks=NEITHER, STUB_REVIEW_COUNT=1)
check('every reviewer missing but one reviewed HEAD: outage probe still clears the note',
      'RESULT: green' in p.stdout and 'reviewer-unavailable' not in p.stdout, p.stdout)

p = watch(['--pr', '6021', '--repo', 'EdgeApp/edge-react-gui', '--task-gid', GID],
          checks=NEITHER, STUB_REVIEW_COUNT=0)
check('every reviewer missing with no review on HEAD: both named unavailable',
      'Cursor Bugbot(no check-run)' in p.stdout and 'Cursor Security(no check-run)' in p.stdout, p.stdout)

p = watch(['--pr', '6021', '--repo', 'EdgeApp/edge-react-gui', '--task-gid', GID],
          checks=NEITHER, STUB_REVIEW_COUNT=0, STUB_IS_DRAFT='true')
check('draft PR: reviewers skipping by design read as draft-reviewer-skipped',
      'draft-reviewer-skipped' in p.stdout and 'reviewer-unavailable' not in p.stdout, p.stdout)

for f in (WAIVER,):
    if os.path.exists(f):
        os.remove(f)
shutil.rmtree(wdir, ignore_errors=True)

print(f'\n{len(fails)} failure(s)' if fails else '\nall passed')
sys.exit(1 if fails else 0)
