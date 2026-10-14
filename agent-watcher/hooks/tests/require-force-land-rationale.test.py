"""require-force-land-rationale.sh: an admin merge needs the marker for its own repo, PR and head.

The gate reads the line through cmd-parse.sh and asks gh which PR and head each admin merge acts
on. A stub `gh` on PATH answers from a file (number, head, URL) or fails when the file is absent,
and markers go in a scratch directory (FORCE_LAND_MARKER_DIR), so no real marker counts.
Cases: a merge without --admin and a quoted mention pass; no marker blocks; the marker for the
same repo, PR and head passes; an older head, another repo's PR with the same number, a stale
marker and a --match-head-commit mismatch block; -R, a PR URL and `bash -c` text are read; when gh
fails the gate falls back to the PR number and the age; outside a task session it does nothing.
Run: python3 tests/require-force-land-rationale.test.py
"""
import json, os, subprocess, sys, tempfile, time

HOOK = os.path.expanduser('~/.config/agent-watcher/hooks/require-force-land-rationale.sh')


def main():
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        markers = os.path.join(tmp, 'markers')
        bindir = os.path.join(tmp, 'bin')
        os.makedirs(markers)
        os.makedirs(bindir)
        answer = os.path.join(tmp, 'gh-answer')
        with open(os.path.join(bindir, 'gh'), 'w') as fh:
            fh.write(f'#!/bin/sh\n[ -f {answer} ] || exit 1\ncat {answer}\n')
        os.chmod(os.path.join(bindir, 'gh'), 0o755)
        base_env = dict(os.environ, PATH=bindir + os.pathsep + os.environ['PATH'],
                        FORCE_LAND_MARKER_DIR=markers, AGENT_TASK_GID='1')

        def run(cmd, view=None, marks=(), gid=True):
            for f in os.listdir(markers):
                os.remove(os.path.join(markers, f))
            if os.path.exists(answer):
                os.remove(answer)
            if view:
                pr, head, repo = view
                with open(answer, 'w') as fh:
                    fh.write(f'{pr}\t{head}\thttps://github.com/{repo}/pull/{pr}\n')
            for repo, pr, head, age in marks:
                owner, name = repo.split('/')
                path = os.path.join(markers, f'agent-force-land-rationale-{owner}-{name}-{pr}.json')
                with open(path, 'w') as fh:
                    json.dump({'owner': owner, 'repo': name, 'pr': pr, 'headSha': head}, fh)
                if age:
                    t = time.time() - age
                    os.utime(path, (t, t))
            env = dict(base_env)
            if not gid:
                del env['AGENT_TASK_GID']
            payload = json.dumps({'cwd': tmp, 'tool_input': {'command': cmd}})
            p = subprocess.run(['bash', HOOK], input=payload, capture_output=True, text=True, cwd=tmp, env=env)
            return p.returncode, p.stderr

        R, OTHER = 'flt-owner/flt-repo', 'flt-owner/flt-other'
        VIEW = (7, 'aaa111', R)
        cases = [
            ('merge without --admin', 'gh pr merge 7 --squash', VIEW, (), True, 0),
            ('a quoted mention', 'echo "gh pr merge 7 --admin"', VIEW, (), True, 0),
            ('outside a task session', 'gh pr merge 7 --admin', VIEW, (), False, 0),
            ('no marker', 'gh pr merge 7 --admin', VIEW, (), True, 2),
            ('marker for the same repo, PR and head', 'gh pr merge 7 --admin', VIEW, ((R, 7, 'aaa111', 0),), True, 0),
            ('marker for an older head', 'gh pr merge 7 --admin', VIEW, ((R, 7, 'old000', 0),), True, 2),
            ('another repo, same PR number', 'gh pr merge 7 --admin', VIEW, ((OTHER, 7, 'aaa111', 0),), True, 2),
            ('a marker older than 6 hours', 'gh pr merge 7 --admin', VIEW, ((R, 7, 'aaa111', 7 * 3600),), True, 2),
            ('no PR argument, gh names the branch PR', 'gh pr merge --admin --squash', VIEW, ((R, 7, 'aaa111', 0),), True, 0),
            ('--match-head-commit differs from the marker', 'gh pr merge 7 --admin --match-head-commit bbb222', VIEW, ((R, 7, 'aaa111', 0),), True, 2),
            ('--match-head-commit equals the marker', 'gh pr merge 7 --admin --match-head-commit bbb222', VIEW, ((R, 7, 'bbb222', 0),), True, 0),
            ('-R picks the repo, gh fails', f'gh pr merge 7 -R {R} --admin', None, ((R, 7, 'x', 0),), True, 0),
            ('-R picks the repo, marker for another', f'gh pr merge 7 -R {R} --admin', None, ((OTHER, 7, 'x', 0),), True, 2),
            ('gh -R before the subcommand', f'gh -R {R} pr merge 7 --admin', VIEW, ((OTHER, 7, 'aaa111', 0),), True, 2),
            ('a PR URL, gh fails', f'gh pr merge https://github.com/{R}/pull/7 --admin', None, ((R, 7, 'x', 0),), True, 0),
            ('a PR URL, marker for another repo', f'gh pr merge https://github.com/{R}/pull/7 --admin', None, ((OTHER, 7, 'x', 0),), True, 2),
            ('inside bash -c, no marker', "bash -c 'gh pr merge 7 --admin'", VIEW, (), True, 2),
            ('inside bash -c, marker', "bash -c 'gh pr merge 7 --admin'", VIEW, ((R, 7, 'aaa111', 0),), True, 0),
            ('after a cd', 'cd /tmp && gh pr merge 7 --admin', VIEW, (), True, 2),
            ('gh fails, falls back to PR number and age', 'gh pr merge 7 --admin', None, ((OTHER, 7, 'x', 0),), True, 0),
            ('gh fails, no marker for that PR', 'gh pr merge 7 --admin', None, ((R, 8, 'x', 0),), True, 2),
            ('two merges, one without a marker', f'gh pr merge 7 -R {R} --admin && gh pr merge 9 -R {R} --admin', None, ((R, 7, 'x', 0),), True, 2),
        ]
        for name, cmd, view, marks, gid, want in cases:
            got, err = run(cmd, view, marks, gid)
            ok = got == want
            if name == 'marker for an older head' and 'older head commit' not in err:
                ok = False
            print(f"{'ok  ' if ok else 'FAIL'} {name}: exit {got} (want {want})")
            if not ok:
                fails.append(name)
    if fails:
        print(f'{len(fails)} failing: {fails}')
        sys.exit(1)
    print('all cases pass')


if __name__ == '__main__':
    main()
