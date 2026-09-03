#!/usr/bin/env bash
# git-branch-ops.sh
# Shared deterministic git branch operations used by Cursor skills.
#
# Usage:
#   git-branch-ops.sh autosquash [--base <ref> | --merge-base-with <ref>]
#   git-branch-ops.sh push [--remote <name>] [--branch <name>] [--force-with-lease]
#   git-branch-ops.sh self-rewrite [--upstream <ref>] [--min-lines N] [--min-ratio N] [--gate]
#   git-branch-ops.sh self-rewrite --whole-branch [--min-lines N] [--min-ratio N]
#   git-branch-ops.sh fold-mode
#
# fold-mode: may a fixup on this branch be squashed into its target RIGHT NOW?
# One JSON line: {"fold":true|false,"mode":"autosquash"|"preserve"|"no-pr"|
# "unknown","reason":"..."}. Asks pr-address.sh review-mode for the branch's
# open PR; `preserve` (a human is mid-review) means the fixup must stay a
# fixup! commit so the reviewer sees the delta, UNLESS the operator approved a
# rewrite (/tmp/agent-history-rewrite-approved-<AGENT_TASK_GID>.md, the same
# note git-history-gate.sh honors). No PR, or an oracle that cannot answer,
# folds (fail open: a fresh /im branch has no reviewer to protect).
# lint-commit.sh consults this before its post-fixup autosquash, so every
# fixup path (im, pr-land, tdd, self-rewrite folds, pr-address, bugbot) makes
# the same call without each caller remembering a flag.
#
# self-rewrite: find unpublished commits that REWRITE lines this branch already
# published. A commit whose removed lines were introduced by commits already on
# the remote branch is, by construction, an amendment of that earlier work: the
# "squiggly path" im's clean-history rule forbids, arriving as a standalone
# commit because a followup segment read the operator's ask as "new work".
# Detection is mechanical, so the callers (git-history-gate.sh on a raw push,
# pr-finalize-fixups.sh before its autosquash) need no judgment:
#   published = local commits `git cherry <upstream> HEAD` marks '-' (their patch
#               is already on the remote branch)
#   candidate = '+' commits, excluding fixup!/squash!/amend! subjects and merges
#   a candidate is FLAGGED when its removed lines number >= --min-lines (5) and
#   the share of them that `git blame` attributes to published commits is
#   >= --min-ratio percent (80)
# --whole-branch is the AUDIT form for a branch already on the remote: every
# commit since the merge-base is a candidate and its reference set is the
# earlier commits of the same branch, so it lists the squiggly path a PR
# already carries (what a rebase should fold) instead of what a push would add.
# The fold is a fixup (`lint-commit.sh --fixup <sha>`), so fixup! commits are
# the compliant shape and are never candidates. A commit that only ADDS lines
# (a new surface) removes nothing and is never flagged. No remote branch yet
# (first push) = nothing published = nothing to check.
#
# Output (stdout, one line of JSON):
#   {"status":"checked"|"no-upstream"|"not-a-branch","upstream":"...",
#    "candidates":N,"flagged":[{"sha":"...","subject":"...","removed":N,"published":N,
#    "targets":["<sha> <subject>", ...]}]}
# --gate: additionally, when flagged is non-empty and no concession note exists at
#   /tmp/agent-history-concession-<AGENT_TASK_GID>.md, print the remediation to
#   stderr and exit 2. The note is the auditable escape hatch (/eval-run reads it;
#   an unjustified note is a finding). Fails OPEN (exit 0, status noted) when git
#   cannot answer.
#
# Exit codes:
#   0 - success (self-rewrite: nothing flagged, or flagged without --gate)
#   1 - error
#   2 - self-rewrite --gate: flagged commits, no concession note
set -euo pipefail

CMD="${1:-}"
shift || true

BASE=""
MERGE_BASE_WITH=""
REMOTE="origin"
BRANCH=""
FORCE_WITH_LEASE="false"
UPSTREAM=""
MIN_LINES=5
MIN_RATIO=80
GATE="false"
WHOLE_BRANCH="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE="$2"
      shift 2
      ;;
    --merge-base-with)
      MERGE_BASE_WITH="$2"
      shift 2
      ;;
    --remote)
      REMOTE="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --force-with-lease)
      FORCE_WITH_LEASE="true"
      shift
      ;;
    --upstream)
      UPSTREAM="$2"
      shift 2
      ;;
    --min-lines)
      MIN_LINES="$2"
      shift 2
      ;;
    --min-ratio)
      MIN_RATIO="$2"
      shift 2
      ;;
    --gate)
      GATE="true"
      shift
      ;;
    --whole-branch)
      WHOLE_BRANCH="true"
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

resolve_default_upstream() {
  local upstream
  upstream="$(
    git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
      || echo "origin/$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')" \
      || echo "origin/master"
  )"
  if [[ -z "$upstream" || "$upstream" == "origin/" ]]; then
    echo "origin/master"
  else
    echo "$upstream"
  fi
}

run_autosquash() {
  if [[ -n "$BASE" && -n "$MERGE_BASE_WITH" ]]; then
    echo "Error: Use either --base or --merge-base-with, not both" >&2
    exit 1
  fi

  if [[ -z "$BASE" ]]; then
    if [[ -z "$MERGE_BASE_WITH" ]]; then
      MERGE_BASE_WITH="$(resolve_default_upstream)"
    fi

    BASE="$(git merge-base "$MERGE_BASE_WITH" HEAD 2>/dev/null || true)"
    if [[ -z "$BASE" ]]; then
      echo "Error: Could not determine merge-base with '$MERGE_BASE_WITH'" >&2
      exit 1
    fi
  fi

  rm -f "$(git rev-parse --git-path index.lock)"
  GIT_EDITOR=true GIT_SEQUENCE_EDITOR=: git rebase -i "$BASE" --autosquash
  echo ">> Autosquash complete (base: $BASE)"
}

run_push() {
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(git branch --show-current)"
  fi
  if [[ -z "$BRANCH" ]]; then
    echo "Error: Could not determine current branch" >&2
    exit 1
  fi

  if [[ "$FORCE_WITH_LEASE" == "true" ]]; then
    git push --force-with-lease "$REMOTE" "$BRANCH"
    echo ">> Push complete ($REMOTE/$BRANCH, mode: force-with-lease)"
  else
    git push "$REMOTE" "$BRANCH"
    echo ">> Push complete ($REMOTE/$BRANCH, mode: plain)"
  fi
}

run_self_rewrite() {
  local branch up flagged_json="" ncand=0 status="checked"
  branch="${BRANCH:-$(git branch --show-current 2>/dev/null || true)}"
  if [[ -z "$branch" && "$WHOLE_BRANCH" != "true" ]]; then
    printf '{"status":"not-a-branch","upstream":"","candidates":0,"flagged":[]}\n'
    return 0
  fi
  local cherry published="" candidates="" merge_base
  if [[ "$WHOLE_BRANCH" == "true" ]]; then
    # Audit form: every branch commit is a candidate; the reference set is
    # filled per candidate below (the branch commits before it).
    up="${UPSTREAM:-$(resolve_default_upstream)}"
    merge_base="$(git merge-base "$up" HEAD 2>/dev/null || true)"
    if [[ -z "$merge_base" ]]; then
      printf '{"status":"no-merge-base","upstream":"%s","candidates":0,"flagged":[]}\n' "$up"
      return 0
    fi
    candidates="$(git rev-list --reverse "$merge_base..HEAD" 2>/dev/null || true)"
  else
    up="${UPSTREAM:-$REMOTE/$branch}"
    if ! git rev-parse --verify -q "$up" >/dev/null 2>&1; then
      printf '{"status":"no-upstream","upstream":"%s","candidates":0,"flagged":[]}\n' "$up"
      return 0
    fi
    # '-' = patch already on the remote branch (published), '+' = unpublished.
    cherry="$(git cherry "$up" HEAD 2>/dev/null || true)"
    published="$(printf '%s\n' "$cherry" | awk '$1=="-"{print $2}')"
    candidates="$(printf '%s\n' "$cherry" | awk '$1=="+"{print $2}')"
    # Commits reachable from the remote branch are published too (blame can land
    # on them when the local branch was never rewritten).
    merge_base="$(git merge-base "$(resolve_default_upstream)" "$up" 2>/dev/null || true)"
    if [[ -n "$merge_base" ]]; then
      published="$(printf '%s\n%s\n' "$published" "$(git rev-list "$merge_base..$up" 2>/dev/null || true)")"
    fi
  fi

  local sha subject total own parents f hunks range blamed target_list
  for sha in $candidates; do
    if [[ "$WHOLE_BRANCH" == "true" ]]; then
      published="$(git rev-list "$merge_base..$sha^" 2>/dev/null || true)"
      [[ -n "$published" ]] || { ncand=$((ncand+1)); continue; }
    fi
    subject="$(git log -1 --format=%s "$sha")"
    case "$subject" in fixup!*|squash!*|amend!*) continue ;; esac
    parents="$(git rev-list --parents -n 1 "$sha" | wc -w | tr -d ' ')"
    [[ "$parents" -gt 2 ]] && continue   # merge commit
    ncand=$((ncand+1))
    total=0; own=0; blamed=""
    for f in $(git diff --name-only --diff-filter=MD "$sha^" "$sha" 2>/dev/null); do
      # Old-side hunk ranges: "-<start>,<count>" (count omitted = 1, 0 = pure add).
      hunks="$(git diff -U0 "$sha^" "$sha" -- "$f" 2>/dev/null \
        | sed -nE 's/^@@ -([0-9]+)(,([0-9]+))? .*/\1 \3/p')"
      [[ -n "$hunks" ]] || continue
      while read -r start count; do
        [[ -z "$start" ]] && continue
        count="${count:-1}"
        [[ "$count" -eq 0 ]] && continue
        range="$start,$((start+count-1))"
        blamed="$(git blame -l -L "$range" "$sha^" -- "$f" 2>/dev/null | awk '{print $1}' | sed 's/^\^//')"
        [[ -n "$blamed" ]] || continue
        while read -r bsha; do
          [[ -z "$bsha" ]] && continue
          total=$((total+1))
          if printf '%s\n' "$published" | grep -q "^$bsha"; then own=$((own+1)); fi
        done <<< "$blamed"
      done <<< "$hunks"
    done
    if [[ "$total" -ge "$MIN_LINES" ]] && [[ $((own*100)) -ge $((MIN_RATIO*total)) ]]; then
      # The published commits this one rewrites, most-touched first: the fold targets.
      target_list=""
      for f in $(git diff --name-only --diff-filter=MD "$sha^" "$sha" 2>/dev/null); do
        hunks="$(git diff -U0 "$sha^" "$sha" -- "$f" 2>/dev/null \
          | sed -nE 's/^@@ -([0-9]+)(,([0-9]+))? .*/\1 \3/p')"
        while read -r start count; do
          [[ -z "$start" ]] && continue
          count="${count:-1}"; [[ "$count" -eq 0 ]] && continue
          target_list+="$(git blame -l -L "$start,$((start+count-1))" "$sha^" -- "$f" 2>/dev/null | awk '{print $1}' | sed 's/^\^//')"$'\n'
        done <<< "$hunks"
      done
      local targets_json="" t
      while read -r cnt t; do
        [[ -z "$t" ]] && continue
        printf '%s\n' "$published" | grep -q "^$t" || continue
        [[ -n "$targets_json" ]] && targets_json+=","
        targets_json+="\"$(git log -1 --format='%h %s' "$t" | sed 's/"/\\"/g')\""
      done < <(printf '%s' "$target_list" | grep -v '^$' | sort | uniq -c | sort -rn | head -3)
      [[ -n "$flagged_json" ]] && flagged_json+=","
      flagged_json+="{\"sha\":\"$(git rev-parse --short=10 "$sha")\",\"subject\":\"$(printf '%s' "$subject" | sed 's/"/\\"/g')\",\"removed\":$total,\"published\":$own,\"targets\":[$targets_json]}"
    fi
  done

  printf '{"status":"%s","upstream":"%s","candidates":%d,"flagged":[%s]}\n' "$status" "$up" "$ncand" "$flagged_json"

  if [[ "$GATE" == "true" && -n "$flagged_json" ]]; then
    local note="/tmp/agent-history-concession-${AGENT_TASK_GID:-none}.md"
    if [[ -n "${AGENT_TASK_GID:-}" && -s "$note" ]]; then
      echo ">> self-rewrite: flagged commits allowed by concession note $note" >&2
      return 0
    fi
    {
      echo "BLOCKED: this push adds commits that rewrite lines already published on $up."
      echo "A commit that edits its own branch's earlier work is an amendment of that"
      echo "commit, not new scope (im clean-history), whatever the operator's ask was"
      echo "called. Fold each one into the commit it rewrites, then push again:"
      printf '%s' "[$flagged_json]" | node -e '
        const d = JSON.parse(require("fs").readFileSync(0, "utf8"))
        for (const f of d) {
          console.error(`  - ${f.sha} "${f.subject}": ${f.published}/${f.removed} removed lines came from published commits`)
          for (const t of f.targets) console.error(`      fold target: ${t}`)
        }' 2>&1
      echo "  Fold, newest flagged commit first while it is the tip:"
      echo "        git reset --soft HEAD~1 && ~/.cursor/skills/lint-commit.sh --fixup <target-sha>"
      echo "        (lint-commit folds the fixup into its target at once when review-mode"
      echo "        allows, so the next flagged commit becomes the tip). An UNFLAGGED commit above a"
      echo "        flagged one: move it below first with"
      echo "        ~/.cursor/skills/im/scripts/reorder-commits.sh <base> <hashes oldest..newest>."
      echo "  A commit that ADDS a new surface without touching the branch's own lines"
      echo "  is not flagged and may stay standalone."
      echo "  Escape hatch (audited by /eval-run): write why this must stay a separate"
      echo "  commit to $note and re-run."
    } >&2
    return 2
  fi
  return 0
}

run_fold_mode() {
  local prjson prnum owner rname mode="" note
  prjson="$(gh pr view --json number,headRepositoryOwner,headRepository 2>/dev/null || true)"
  if [[ -z "$prjson" ]]; then
    printf '{"fold":true,"mode":"no-pr","reason":"no open PR for this branch"}\n'; return 0
  fi
  prnum="$(printf '%s' "$prjson" | jq -r '.number // empty')"
  owner="$(printf '%s' "$prjson" | jq -r '.headRepositoryOwner.login // empty')"
  rname="$(printf '%s' "$prjson" | jq -r '.headRepository.name // empty')"
  if [[ -n "$prnum" && -n "$owner" && -n "$rname" ]]; then
    mode="$("$HOME/.cursor/skills/pr-address/scripts/pr-address.sh" review-mode \
      --owner "$owner" --repo "$rname" --pr "$prnum" 2>/dev/null | jq -r '.mode // empty' 2>/dev/null || true)"
  fi
  case "$mode" in
    preserve)
      note="/tmp/agent-history-rewrite-approved-${AGENT_TASK_GID:-none}.md"
      if [[ -n "${AGENT_TASK_GID:-}" && -s "$note" ]]; then
        printf '{"fold":true,"mode":"preserve","reason":"operator rewrite approval %s"}\n' "$note"
      else
        printf '{"fold":false,"mode":"preserve","reason":"a human reviewer is mid-review on PR #%s; keep the fixup! commit so they see the delta"}\n' "$prnum"
      fi ;;
    autosquash) printf '{"fold":true,"mode":"autosquash","reason":"no active human review on PR #%s"}\n' "$prnum" ;;
    *) printf '{"fold":true,"mode":"unknown","reason":"review-mode unavailable; fail open"}\n' ;;
  esac
}

case "$CMD" in
  autosquash)
    run_autosquash
    ;;
  fold-mode)
    run_fold_mode
    ;;
  push)
    run_push
    ;;
  self-rewrite)
    run_self_rewrite
    ;;
  *)
    echo "Usage: git-branch-ops.sh {autosquash|push|self-rewrite|fold-mode} [args]" >&2
    exit 1
    ;;
esac
