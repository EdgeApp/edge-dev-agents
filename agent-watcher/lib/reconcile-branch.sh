#!/usr/bin/env bash
# reconcile-branch.sh — bring a REUSED task worktree back onto the remote branch
# when another session rewrote that branch while the worktree sat retained.
#
# WHY: a followup resumes on the task's retained worktree as-is (no fetch, no
# reset), so after an external rewrite (a fold done from another session, a
# rebase) the local branch still carries the OLD commits and the resumed
# transcript remembers their shas. A plain push is then rejected, but the usual
# `git fetch && git push --force-with-lease` passes its lease and OVERWRITES the
# other session's work. Reconciling at reuse time removes that window.
#
# reconcile_branch <worktree> <branch>
#   Fetches origin/<branch> and compares it with the worktree's HEAD:
#     same            -> nothing
#     local ahead     -> keep (unpushed local work; the remote did not move)
#     behind/diverged -> clean tree: `git reset --hard origin/<branch>` and a
#                        NOTICE on stderr naming both shas, so the agent knows
#                        every sha it remembers for this PR is gone
#                        dirty tree: refuse to touch it, WARN that the push
#                        will be rejected until the tree is committed or stashed
#                        and the branch reset by hand
#   Exit 0 always except when the fetch itself fails (exit 1, WARN printed):
#   reconciliation is best-effort and must never block a resume.
#   Prints nothing on stdout; every message goes to stderr with the
#   `>> reconcile-branch:` prefix.
reconcile_branch() {
  local wt="$1" branch="$2"
  [[ -d "$wt" && -n "$branch" ]] || return 0
  if ! git -C "$wt" fetch --quiet origin "$branch" 2>/dev/null; then
    echo ">> reconcile-branch: WARN fetch of origin/$branch failed; worktree left as-is" >&2
    return 1
  fi
  local cur local_head remote_head
  cur="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
  local_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  remote_head="$(git -C "$wt" rev-parse "origin/$branch" 2>/dev/null || true)"
  [[ -n "$local_head" && -n "$remote_head" ]] || return 0
  if [[ "$cur" != "$branch" ]]; then
    echo ">> reconcile-branch: WARN worktree is on '${cur:-detached}', not '$branch'; left as-is" >&2
    return 0
  fi
  if [[ "$local_head" == "$remote_head" ]]; then
    return 0
  fi
  if git -C "$wt" merge-base --is-ancestor "$remote_head" "$local_head" 2>/dev/null; then
    echo ">> reconcile-branch: local $branch is ahead of origin (unpushed work at ${local_head:0:9}); kept" >&2
    return 0
  fi
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    echo ">> reconcile-branch: WARN origin/$branch moved to ${remote_head:0:9} but the worktree has uncommitted changes; NOT reset. Commit or stash them, then \`git reset --hard origin/$branch\`; until then any push is rejected or would clobber the remote." >&2
    return 0
  fi
  git -C "$wt" reset -q --hard "origin/$branch"
  echo ">> reconcile-branch: BRANCH MOVED by another session: $branch was ${local_head:0:9} locally, origin is ${remote_head:0:9}; worktree reset --hard to origin. Every commit sha you remember for this PR is gone: re-read \`git log\` before folding, citing, or fixing up." >&2
  return 0
}
