#!/usr/bin/env bash
# git-branch-ops.sh
# Shared deterministic git branch operations used by Cursor skills.
#
# Usage:
#   git-branch-ops.sh autosquash [--base <ref> | --merge-base-with <ref>]
#   git-branch-ops.sh fold-one --fixup <sha> [--base <ref> | --merge-base-with <ref>]
#   git-branch-ops.sh condense-fixups [--base <ref> | --merge-base-with <ref>]
#   git-branch-ops.sh push [--remote <name>] [--branch <name>] [--force-with-lease]
#   git-branch-ops.sh self-rewrite [--upstream <ref>] [--min-lines N] [--min-ratio N] [--gate]
#   git-branch-ops.sh self-rewrite --whole-branch [--min-lines N] [--min-ratio N]
#   git-branch-ops.sh fold-mode [--target <sha>]
#   git-branch-ops.sh note-scope [--note <path>]
#
# autosquash vs fold-one: `autosquash` is a WHOLE-BRANCH
# `rebase -i --autosquash` from the merge base — it squashes EVERY pending
# fixup! on the branch, including ones a reviewer has not seen. It belongs to
# the sanctioned push-time path (pr-finalize-fixups.sh) and to an operator
# approval that says `Targets: all`. `fold-one --fixup <sha>` squashes exactly
# ONE fixup into the commit its subject names and leaves every other pending
# fixup where it is; that is the fold lint-commit.sh performs after creating a
# fixup.
#
# fold-mode: may THIS fixup be squashed into its target RIGHT NOW?
# One JSON line: {"fold":true|false,"mode":"autosquash"|"preserve"|"no-pr"|
# "unknown","approved_targets":[...],"whole_branch":true|false,"reason":"..."}.
# Asks pr-address.sh review-mode for the branch's open PR; `preserve` (a human
# is mid-review) means the fixup must stay a fixup! commit so the reviewer sees
# the delta, UNLESS the operator approved a rewrite of the commit this fixup
# targets (pass it as --target <sha>). No PR, or an oracle that cannot answer,
# folds (fail open: a fresh /im branch has no reviewer to protect).
# lint-commit.sh consults this before its post-fixup fold, so every fixup path
# (im, pr-land, tdd, self-rewrite folds, pr-address, bugbot) makes the same
# call without each caller remembering a flag.
#
# OPERATOR REWRITE-APPROVAL NOTE — shape.
# /tmp/agent-history-rewrite-approved-<AGENT_TASK_GID>.md, written by the agent
# to record the operator task comment that approved a history rewrite under
# review (git-history-gate.sh's block message tells the agent to write it;
# /eval-run audits it against the comment it cites). It cites that comment and
# names its SCOPE on a line, case-insensitive:
#   Targets: <sha> [<sha> ...]   those commits may be rewritten
#   Targets: all                 the whole branch may be rewritten
# A note with NO Targets: line is the legacy shape: it approves folding ONE
# fixup into its own target (fold-one) and never a whole-branch autosquash.
# The approval is never blanket permission: an approval naming one commit does
# not authorize squashing a fixup the reviewer is still waiting to read.
# `note-scope` prints the tokens one per line (`all` for the whole branch) and
# exits 1 when there is no note, so git-history-gate.sh and this script read
# one parse.
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
#   0 - success (self-rewrite: nothing flagged, or flagged without --gate;
#       note-scope: a note exists)
#   1 - error (fold-one: target not on the branch, detached HEAD, or a rebase
#       conflict — the rebase is aborted and the fixup stays where it was;
#       note-scope: no note)
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
FIXUP=""
TARGET=""
NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixup)
      FIXUP="$2"
      shift 2
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --note)
      NOTE="$2"
      shift 2
      ;;
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

# Fill BASE from --base, --merge-base-with, or the default upstream's merge base.
resolve_base() {
  if [[ -n "$BASE" && -n "$MERGE_BASE_WITH" ]]; then
    echo "Error: Use either --base or --merge-base-with, not both" >&2
    exit 1
  fi
  [[ -n "$BASE" ]] && return 0
  [[ -n "$MERGE_BASE_WITH" ]] || MERGE_BASE_WITH="$(resolve_default_upstream)"
  BASE="$(git merge-base "$MERGE_BASE_WITH" HEAD 2>/dev/null || true)"
  if [[ -z "$BASE" ]]; then
    echo "Error: Could not determine merge-base with '$MERGE_BASE_WITH'" >&2
    exit 1
  fi
}

# The operator rewrite-approval note for this run. Shape: see the header.
rewrite_note_path() {
  printf '/tmp/agent-history-rewrite-approved-%s.md\n' "${AGENT_TASK_GID:-none}"
}

# Print the note's scope tokens, one per line (`all` = the whole branch); no
# output = the legacy unscoped shape. Exit 1 when the note is absent or empty,
# so a caller can tell "no approval" from "approval with no scope line".
# Lowercased before matching: `Targets:` / `targets:` / `Target:` all parse,
# and shas are hex either way.
run_note_scope() {
  local note="${1:-${NOTE:-$(rewrite_note_path)}}"
  [[ -s "$note" ]] || return 1
  tr '[:upper:]' '[:lower:]' < "$note" \
    | sed -nE 's/^[[:space:]]*targets?[[:space:]]*:[[:space:]]*(.*)$/\1/p' \
    | tr ',' ' ' | tr -s '[:space:]' '\n' | grep -v '^$' || true
  return 0
}

run_autosquash() {
  resolve_base

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
      echo "        git reset --soft HEAD~1 && ~/.cursor/skills/lint-commit.sh --fixup <target-sha> --for auto -m \"<what changed and why>\""
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

# condense-fixups: ONE fixup! per target commit AND KIND, however many rounds
# produced them. Every fixup on the branch is grouped by the commit it targets
# (nested "fixup! fixup! X" counts for X) and by its `Fixup-for:` trailer
# (human / auto, written by lint-commit.sh --for; a fixup without one is its own
# legacy group), so the fixes a person asked for stay a separate commit from bot
# churn. A group with more than one member is folded into its first member, in
# place, with the bodies concatenated and one trailer kept, and the subject
# normalized to "fixup! <target subject>". Groups keep the order their first
# member had. Target commits are never touched, so the reviewer's delta view
# survives; this is the preserve-mode counterpart of autosquash and
# pr-finalize-fixups.sh runs it before every preserve push. Orphan fixups (no
# target in range) stay where they are. Output: one JSON line
# {"condensed":N,"groups":[{"target":"...","for":"human|auto|","fixups":N}],"base":"..."}
# where condensed is the number of fixup commits removed. Exit 1 on a rebase
# conflict (aborted, tree left clean).
run_condense_fixups() {
  resolve_base
  local tmp plan
  tmp="$(mktemp -d -t condense-fixups.XXXXXX)"
  # shellcheck disable=SC2064  # expand now: the local is gone when EXIT fires
  trap "rm -rf '$tmp'" EXIT
  cat > "$tmp/condense.js" <<'NODEEOF'
const fs = require('fs')
const { execSync } = require('child_process')
const [mode, arg] = process.argv.slice(2)
const tmp = process.env.CONDENSE_TMP
const base = process.env.CONDENSE_BASE
const git = a => execSync('git ' + a, { encoding: 'utf8' })

const strip = s => { let n = 0; while (s.startsWith('fixup! ')) { s = s.slice(7); n++ } return { headline: s, depth: n } }
const TRAILER = /^Fixup-for:\s*(\S+)\s*$/m
const log = git('log --reverse --format=%H%x1f%s%x1f%b%x1e ' + base + '..HEAD').trim()
const commits = log ? log.split('\x1e').map(l => l.replace(/^\n/, '')).filter(Boolean).map(l => {
  const [sha, subj, body] = l.split('\x1f')
  const m = (body || '').match(TRAILER)
  return { sha, subj, body: (body || '').replace(/^Fixup-for:.*$/mg, '').trim(), kind: m ? m[1] : '' }
}) : []
const targets = new Map()
for (const c of commits) {
  if (strip(c.subj).depth === 0 && !targets.has(c.subj)) targets.set(c.subj, { sha: c.sha, subj: c.subj, groups: [] })
}
const member = new Map()
for (const c of commits) {
  const { headline, depth } = strip(c.subj)
  if (depth === 0) continue
  const t = targets.get(headline)
  if (!t) continue
  let g = t.groups.find(g => g.kind === c.kind)
  if (!g) { g = { kind: c.kind, fixups: [] }; t.groups.push(g) }
  g.fixups.push(c); member.set(c.sha, t)
}
const needsWork = g => g.fixups.length > 1 || (g.fixups.length === 1 && strip(g.fixups[0].subj).depth > 1)
const work = []
for (const t of targets.values()) for (const g of t.groups) if (needsWork(g)) work.push({ t, g })
const plan = {
  condensed: work.reduce((n, w) => n + w.g.fixups.length - 1, 0),
  groups: work.map(w => ({ target: w.t.subj, for: w.g.kind, fixups: w.g.fixups.length })),
  base: base.slice(0, 10)
}

if (mode === 'plan') { process.stdout.write(JSON.stringify(plan) + '\n'); process.exit(0) }

// todo mode: rewrite git's rebase todo (path in arg)
const full = s => commits.find(c => c.sha.startsWith(s) || s.startsWith(c.sha))?.sha
const lines = fs.readFileSync(arg, 'utf8').split('\n')
const out = []
let i = 0
for (const line of lines) {
  const m = line.match(/^(pick|p)\s+([0-9a-f]+)(\s.*)?$/)
  if (!m) { out.push(line); continue }
  const sha = full(m[2])
  if (sha && member.has(sha)) continue
  out.push(line)
  const t = sha && [...targets.values()].find(t => t.sha === sha)
  if (!t) continue
  for (const g of t.groups) {
    g.fixups.forEach((f, k) => out.push((k === 0 ? 'pick ' : 'fixup ') + f.sha + ' ' + f.subj))
    if (!needsWork(g)) continue
    const bodies = []
    for (const f of g.fixups) if (f.body && !bodies.includes(f.body)) bodies.push(f.body)
    const trailer = g.kind ? '\n\nFixup-for: ' + g.kind : ''
    const msg = tmp + '/' + (i++) + '.msg'
    fs.writeFileSync(msg, 'fixup! ' + t.subj + (bodies.length ? '\n\n' + bodies.join('\n\n') : '') + trailer + '\n')
    out.push('exec git commit --amend --no-verify -q -F "' + msg + '"')
  }
}
fs.writeFileSync(arg, out.join('\n'))
NODEEOF
  plan="$(CONDENSE_TMP="$tmp" CONDENSE_BASE="$BASE" node "$tmp/condense.js" plan)"
  if [[ "$(printf '%s' "$plan" | jq -r '.condensed')" == "0" ]]; then
    printf '%s\n' "$plan"
    return 0
  fi
  rm -f "$(git rev-parse --git-path index.lock)"
  if ! CONDENSE_TMP="$tmp" CONDENSE_BASE="$BASE" GIT_SEQUENCE_EDITOR="node $tmp/condense.js todo" GIT_EDITOR=true \
      git rebase --autostash -i "$BASE" >"$tmp/rebase.log" 2>&1; then
    echo "Error: rebase failed while condensing fixups" >&2
    sed 's/^/  /' "$tmp/rebase.log" | tail -20 >&2
    if [[ -d "$(git rev-parse --git-path rebase-merge)" ]] || [[ -d "$(git rev-parse --git-path rebase-apply)" ]]; then
      git rebase --abort 2>&1 | sed 's/^/  /' >&2 || true
    fi
    exit 1
  fi
  echo ">> Condensed fixups: $(printf '%s' "$plan" | jq -r '.condensed') commit(s) folded into their target+kind group's first fixup (base: $BASE)" >&2
  printf '%s\n' "$plan"
}

# fold-one --fixup <sha>: squash exactly ONE fixup! commit into the commit its
# subject names. Every other pending fixup on the branch keeps its own commit,
# which is the whole point: `autosquash` rewrites the branch from the merge
# base and sweeps up fixups a reviewer is still waiting to read.
# The sequence editor drops the named fixup's `pick` line and re-inserts it as
# `fixup` directly after its target's line; every other line stays `pick`.
run_fold_one() {
  local fixup_sha target_sha subject headline short_fix short_tgt tmp
  if [[ -z "$FIXUP" ]]; then
    echo "Error: fold-one needs --fixup <sha>" >&2
    exit 1
  fi
  if ! git symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    echo "Error: HEAD is detached; check out the branch before folding a fixup" >&2
    exit 1
  fi
  fixup_sha="$(git rev-parse --verify -q "${FIXUP}^{commit}" 2>/dev/null || true)"
  if [[ -z "$fixup_sha" ]]; then
    echo "Error: '$FIXUP' is not a commit in this repo" >&2
    exit 1
  fi
  resolve_base
  if ! git rev-list "$BASE..HEAD" 2>/dev/null | grep -qx "$fixup_sha"; then
    echo "Error: fixup $(git rev-parse --short=10 "$fixup_sha") is not on this branch above $BASE" >&2
    exit 1
  fi
  subject="$(git log -1 --format=%s "$fixup_sha")"
  if [[ "$subject" != fixup!\ * ]]; then
    echo "Error: $(git rev-parse --short=10 "$fixup_sha") is not a fixup! commit (subject: $subject)" >&2
    exit 1
  fi
  headline="$subject"
  while [[ "$headline" == fixup!\ * ]]; do headline="${headline#fixup! }"; done
  # Literal subject comparison, never a dynamic regex: subjects carry regex
  # metacharacters. %H is 40 chars, so the subject starts at column 42. Search
  # below the fixup only, so the target is always an ancestor of it.
  target_sha="$(git log "$BASE..$fixup_sha^" --format='%H %s' 2>/dev/null \
    | HEADLINE="$headline" awk 'substr($0, 42) == ENVIRON["HEADLINE"] { print $1; exit }' || true)"
  if [[ -z "$target_sha" ]]; then
    echo "Error: fixup target \"$headline\" is not on this branch (searched $BASE..$(git rev-parse --short=10 "$fixup_sha")^)." >&2
    echo "  The fixup stays where it is. Re-target it at a commit on the branch, or let pr-finalize-fixups.sh carry it." >&2
    exit 1
  fi
  short_fix="$(git rev-parse --short=10 "$fixup_sha")"
  short_tgt="$(git rev-parse --short=10 "$target_sha")"
  tmp="$(mktemp -d -t fold-one.XXXXXX)"
  # shellcheck disable=SC2064  # expand now: the local is gone when EXIT fires
  trap "rm -rf '$tmp'" EXIT
  cat > "$tmp/fold-one.js" <<'NODEEOF'
const fs = require('fs')
const todoPath = process.argv[2]
const fixup = process.env.FOLD_FIXUP_SHA
const target = process.env.FOLD_TARGET_SHA
const shaOf = l => { const m = l.match(/^(?:pick|p)\s+([0-9a-f]+)/); return m ? m[1] : null }
// git abbreviates todo shas; either side may be the prefix.
const same = (a, b) => !!a && !!b && (a.startsWith(b) || b.startsWith(a))
const lines = fs.readFileSync(todoPath, 'utf8').split('\n')
const kept = []
let fixupLine = null
for (const line of lines) {
  const sha = shaOf(line)
  if (sha && same(fixup, sha) && fixupLine === null) { fixupLine = line; continue }
  kept.push(line)
}
if (fixupLine === null) { console.error('ERROR: fixup ' + fixup + ' is not in the rebase todo'); process.exit(1) }
const at = kept.findIndex(l => { const sha = shaOf(l); return sha && same(target, sha) })
if (at < 0) { console.error('ERROR: target ' + target + ' is not in the rebase todo'); process.exit(1) }
kept.splice(at + 1, 0, fixupLine.replace(/^(?:pick|p)\s+/, 'fixup '))
fs.writeFileSync(todoPath, kept.join('\n'))
NODEEOF
  rm -f "$(git rev-parse --git-path index.lock)"
  if ! FOLD_FIXUP_SHA="$fixup_sha" FOLD_TARGET_SHA="$target_sha" \
      GIT_SEQUENCE_EDITOR="node $tmp/fold-one.js" GIT_EDITOR=true \
      git rebase --autostash -i "$BASE" >"$tmp/rebase.log" 2>&1; then
    echo "Error: rebase failed while folding $short_fix into $short_tgt" >&2
    sed 's/^/  /' "$tmp/rebase.log" | tail -20 >&2
    if [[ -d "$(git rev-parse --git-path rebase-merge)" ]] || [[ -d "$(git rev-parse --git-path rebase-apply)" ]]; then
      echo "Aborting the rebase; the fixup stays where it was" >&2
      git rebase --abort 2>&1 | sed 's/^/  /' >&2 || true
    fi
    exit 1
  fi
  echo ">> Folded fixup $short_fix into $short_tgt (\"$headline\"); other pending fixups untouched"
}

run_fold_mode() {
  local prjson prnum owner rname mode="" note tokens tokens_json="" tok tok_sha target_sha=""
  local scoped="false" all="false" covers="false"
  prjson="$(gh pr view --json number,headRepositoryOwner,headRepository 2>/dev/null || true)"
  if [[ -z "$prjson" ]]; then
    printf '{"fold":true,"mode":"no-pr","approved_targets":[],"whole_branch":false,"reason":"no open PR for this branch"}\n'; return 0
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
      note="${NOTE:-$(rewrite_note_path)}"
      if [[ -z "${AGENT_TASK_GID:-}" && -z "$NOTE" ]] || [[ ! -s "$note" ]]; then
        printf '{"fold":false,"mode":"preserve","approved_targets":[],"whole_branch":false,"reason":"a human reviewer is mid-review on PR #%s; keep the fixup! commit so they see the delta"}\n' "$prnum"
        return 0
      fi
      tokens="$(run_note_scope "$note" || true)"
      [[ -n "$tokens" ]] && scoped="true"
      [[ -n "$TARGET" ]] && target_sha="$(git rev-parse --verify -q "${TARGET}^{commit}" 2>/dev/null || true)"
      while read -r tok; do
        [[ -n "$tok" ]] || continue
        [[ -n "$tokens_json" ]] && tokens_json+=","
        tokens_json+="\"$(printf '%s' "$tok" | sed 's/[\\"]/_/g')\""
        if [[ "$tok" == "all" ]]; then all="true"; continue; fi
        if [[ -n "$target_sha" ]]; then
          tok_sha="$(git rev-parse --verify -q "${tok}^{commit}" 2>/dev/null || true)"
          [[ -n "$tok_sha" && "$tok_sha" == "$target_sha" ]] && covers="true"
        fi
      done <<< "$tokens"
      if [[ "$all" == "true" ]]; then
        printf '{"fold":true,"mode":"preserve","approved_targets":[%s],"whole_branch":true,"reason":"operator rewrite approval %s says Targets: all, so the whole branch may be rewritten"}\n' "$tokens_json" "$note"
      elif [[ "$covers" == "true" ]]; then
        printf '{"fold":true,"mode":"preserve","approved_targets":[%s],"whole_branch":false,"reason":"operator rewrite approval %s names this fixup target (%s); fold only this fixup"}\n' \
          "$tokens_json" "$note" "$(git rev-parse --short=10 "$target_sha")"
      elif [[ "$scoped" == "true" ]]; then
        printf '{"fold":false,"mode":"preserve","approved_targets":[%s],"whole_branch":false,"reason":"operator rewrite approval %s covers only the targets it names; it does not cover %s, so the fixup stays for the reviewer"}\n' \
          "$tokens_json" "$note" "${target_sha:-the commit this fixup targets (no --target given)}"
      else
        echo ">> fold-mode: $note names no targets. Add a scope line so the approval says what it covers: 'Targets: <sha> [<sha> ...]' or 'Targets: all'. Folding THIS fixup only." >&2
        printf '{"fold":true,"mode":"preserve","approved_targets":[],"whole_branch":false,"reason":"operator rewrite approval %s is unscoped (no Targets: line); it folds this one fixup into its own target and never a whole-branch autosquash"}\n' "$note"
      fi ;;
    autosquash) printf '{"fold":true,"mode":"autosquash","approved_targets":[],"whole_branch":false,"reason":"no active human review on PR #%s"}\n' "$prnum" ;;
    *) printf '{"fold":true,"mode":"unknown","approved_targets":[],"whole_branch":false,"reason":"review-mode unavailable; fail open"}\n' ;;
  esac
}

case "$CMD" in
  autosquash)
    run_autosquash
    ;;
  fold-one)
    run_fold_one
    ;;
  fold-mode)
    run_fold_mode
    ;;
  note-scope)
    run_note_scope
    ;;
  condense-fixups)
    run_condense_fixups
    ;;
  push)
    run_push
    ;;
  self-rewrite)
    run_self_rewrite
    ;;
  *)
    echo "Usage: git-branch-ops.sh {autosquash|fold-one|condense-fixups|push|self-rewrite|fold-mode|note-scope} [args]" >&2
    exit 1
    ;;
esac
