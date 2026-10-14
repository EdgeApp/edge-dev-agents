#!/usr/bin/env python3
"""Contract tests for the three raw-write gates and their companion-script rule.

Run: python3 ~/.config/agent-watcher/hooks/tests/raw-write-gates.test.py

  block-raw-gh-writes.sh       raw gh pr create/comment/review, gh pr edit of the
                               body or title, gh api writes to comment endpoints
  block-raw-asana-api.sh       an HTTP client aimed at the Asana API
  block-raw-thread-resolve.sh  a raw resolveReviewThread mutation

The companion scripts under ~/.cursor/skills/ and ~/.config/agent-watcher/ call
these APIs themselves. Each gate matches its trigger against the view
`cmd-parse.sh --rest` prints, where quoted, heredoc and commented text is blank
and so is every command that runs a companion script. Three properties follow:

  1. A companion script's own arguments never fire a gate.
  2. A raw write on the same line as a companion script still blocks. The old
     rule excused the whole line once any companion script ran in it.
  3. A path that only names a companion script (cat, grep, git add) excuses
     nothing.

The gh gates act on EdgeApp repos only; the cases run with the hook cwd in a
scratch repo whose origin is an EdgeApp URL.
"""
import json, os, subprocess, sys, tempfile

HOOKS = os.path.expanduser('~/.config/agent-watcher/hooks')
SKILL = '~/.cursor/skills/pr-address/scripts/pr-address.sh'
AW = '~/.config/agent-watcher/check-followup-scope.sh'
URL = 'https://app.asana.com/api/1.0/tasks/1'
GQL = "gh api graphql -f query='mutation { resolveReviewThread(input:{threadId:\"T\"}) { thread { id } } }'"

CASES = [
    # gh writes
    ('block-raw-gh-writes.sh', 'raw pr create', 'gh pr create --fill', 2),
    ('block-raw-gh-writes.sh', 'raw pr comment', 'gh pr comment 5 --body x', 2),
    ('block-raw-gh-writes.sh', 'pr edit of the body', 'gh pr edit 5 --body x', 2),
    ('block-raw-gh-writes.sh', 'gh api POST to comments', 'gh api repos/EdgeApp/r/issues/5/comments -f body=x', 2),
    ('block-raw-gh-writes.sh', 'gh api reply inside bash -c', "bash -c 'gh api repos/EdgeApp/r/pulls/comments/9/replies -f body=x'", 2),
    ('block-raw-gh-writes.sh', 'gh api PATCH by --method', 'gh api --method PATCH repos/EdgeApp/r/issues/comments/9', 2),
    ('block-raw-gh-writes.sh', 'graphql read beside a reviews GET', "gh api graphql -f query='{ x }' && gh api repos/EdgeApp/r/pulls/5/reviews", 0),
    ('block-raw-gh-writes.sh', 'POST to /markdown beside a comments GET', 'gh api --method POST /markdown --input f.json; gh api repos/EdgeApp/r/issues/5/comments --paginate', 0),
    ('block-raw-gh-writes.sh', 'companion script alone', f'{SKILL} reply --body "use gh pr comment"', 0),
    ('block-raw-gh-writes.sh', 'companion script whose arguments name pr create', f'{SKILL} note gh pr create', 0),
    ('block-raw-gh-writes.sh', 'companion script, then a raw comment', f'{SKILL} reply --body x && gh pr comment 5 --body y', 2),
    ('block-raw-gh-writes.sh', 'raw create, then a companion script', f'gh pr create --fill; {SKILL} reply', 2),
    ('block-raw-gh-writes.sh', 'companion script inside a substitution, then create', f'OUT=$({SKILL} reply); gh pr create --fill', 2),
    ('block-raw-gh-writes.sh', 'companion script behind timeout and bash', f'timeout 60 bash {SKILL} reply --body x', 0),
    ('block-raw-gh-writes.sh', 'cat of a companion script, then create', f'cat {SKILL} && gh pr create --fill', 2),
    ('block-raw-gh-writes.sh', 'echo of the phrase', 'echo "gh pr create"', 0),
    ('block-raw-gh-writes.sh', 'pr edit of a label', 'gh pr edit 5 --add-label x', 0),
    ('block-raw-gh-writes.sh', 'pr view', 'gh pr view 5 --json body', 0),
    # Asana
    ('block-raw-asana-api.sh', 'raw curl', f'curl -s -H "Authorization: Bearer $T" "{URL}"', 2),
    ('block-raw-asana-api.sh', 'companion script alone', f'{AW} --task-gid 1 # {URL}', 0),
    ('block-raw-asana-api.sh', 'companion script given the URL', f'{AW} --url "{URL}"', 0),
    ('block-raw-asana-api.sh', 'companion script, then a raw curl', f'{AW} --task-gid 1 && curl -s "{URL}"', 2),
    ('block-raw-asana-api.sh', 'git add of a companion path, then curl', f'git add ~/.config/agent-watcher/x.sh && curl "{URL}"', 2),
    ('block-raw-asana-api.sh', 'URL in an echo', f'echo "{URL}"', 0),
    ('block-raw-asana-api.sh', 'curl of another host', 'curl -s https://example.com', 0),
    # Thread resolve
    ('block-raw-thread-resolve.sh', 'raw mutation', GQL, 2),
    ('block-raw-thread-resolve.sh', 'companion script given the mutation name', f'{SKILL} resolve --note resolveReviewThread', 0),
    ('block-raw-thread-resolve.sh', 'companion script, then a raw mutation', f'{SKILL} reply --body x && {GQL}', 2),
    ('block-raw-thread-resolve.sh', 'mutation named in a heredoc', "cat > /dev/null <<'E'\ngh api graphql resolveReviewThread\nE", 0),
]


def main():
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        off = os.path.join(tmp, 'jev')
        os.makedirs(off)
        open(os.path.join(off, 'OFF'), 'w').close()
        repo = os.path.join(tmp, 'repo')
        os.makedirs(repo)
        subprocess.run('git init -q && git remote add origin https://github.com/EdgeApp/edge-react-gui.git',
                       shell=True, cwd=repo, check=True)
        env = dict(os.environ, JEV_SHADOW_ROOT=off, AGENT_TASK_GID='1111111111')
        for hook, name, cmd, want in CASES:
            payload = json.dumps({'cwd': repo, 'tool_name': 'Bash', 'tool_input': {'command': cmd}})
            p = subprocess.run(['bash', os.path.join(HOOKS, hook)], input=payload, capture_output=True,
                               text=True, cwd=repo, env=env, timeout=30)
            ok = p.returncode == want and (want == 0 or 'BLOCKED' in p.stderr)
            print(f"{'ok  ' if ok else 'FAIL'} {hook[10:-3]}: {name} (exit {p.returncode}, want {want})")
            if not ok:
                fails.append(f'{hook}: {name}')
    if fails:
        print(f'{len(fails)} failing: {fails}')
        sys.exit(1)
    print('all cases pass')


if __name__ == '__main__':
    main()
