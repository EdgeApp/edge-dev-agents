#!/usr/bin/env bash
# convention-sync.sh — Sync ~/.cursor/ files with the edge-dev-agents repo.
# Usage: ./convention-sync.sh [repo-dir] [--stage] [--commit -m "message"] [--repo-to-user]
# Compares ~/.cursor/{README.md,skills,rules,scripts} against the distribution
# copy in <repo-dir> and outputs a structured JSON summary of new, modified,
# and deleted files.
# With --stage: copies changed files and stages them in git (or copies to user dir with --repo-to-user).
# With --commit: stages + commits (requires -m). Only valid for user-to-repo direction.
#
# Sync model: ~/.cursor/ is canonical. Default direction (user-to-repo) copies local
# files into the repo. --repo-to-user is for onboarding or pulling others' changes.
# No bidirectional conflict detection — the chosen direction overwrites the other side.

set -euo pipefail

# Self-stabilization: re-exec from a temp copy before doing anything else.
# In --repo-to-user mode the .cursor rsync replaces THIS file on disk mid-run;
# bash reads scripts lazily, so the running process misaligns on the new bytes
# and crashes with spurious errors (seen 2026-06-11: "destpath: unbound
# variable" on a line containing no destpath). CONVENTION_SYNC_HOME preserves
# the real script dir for sibling-script lookups (generate-claude-md.sh).
if [[ -z "${CONVENTION_SYNC_STABLE:-}" ]]; then
  _stable_copy="$(mktemp /tmp/convention-sync-run.XXXXXX)"
  cp "${BASH_SOURCE[0]}" "$_stable_copy"
  CONVENTION_SYNC_STABLE=1 \
  CONVENTION_SYNC_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
    exec bash "$_stable_copy" "$@"
fi
trap 'rm -f "$0"' EXIT

REPO_DIR=""
DO_STAGE=false
DO_COMMIT=false
COMMIT_MSG=""
DIRECTION="user-to-repo"
FORCE_WARN=false       # --force: override blocking deletion/stale-local warnings
FORCE_BRANCH=false     # --force-branch: override the sync-branch safety check

resolve_default_repo_dir() {
  local cwd remote_url default_repo

  cwd="$(pwd)"
  if [[ "$(basename "$cwd")" == "edge-dev-agents" ]]; then
    printf '%s\n' "$cwd"
    return 0
  fi

  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    remote_url="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
    if [[ "$remote_url" == *"edge-dev-agents"* ]]; then
      printf '%s\n' "$cwd"
      return 0
    fi
  fi

  default_repo="$HOME/git/edge-dev-agents"
  if [[ -d "$default_repo/.git" || -f "$default_repo/.git" ]]; then
    printf '%s\n' "$default_repo"
    return 0
  fi

  return 1
}

validate_repo_dir() {
  local repo_dir remote_url
  repo_dir="$1"

  if [[ ! -d "$repo_dir/.cursor" ]]; then
    echo "ERROR: Repo directory must contain .cursor/: $repo_dir" >&2
    return 1
  fi

  if [[ "$(basename "$repo_dir")" == "edge-dev-agents" ]]; then
    return 0
  fi

  if git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    remote_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
    if [[ "$remote_url" == *"edge-dev-agents"* ]]; then
      return 0
    fi
  fi

  echo "ERROR: Repo directory does not appear to be the edge-dev-agents checkout: $repo_dir" >&2
  return 1
}

ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) DO_STAGE=true; shift ;;
    --commit) DO_COMMIT=true; DO_STAGE=true; shift ;;
    -m) COMMIT_MSG="$2"; shift 2 ;;
    --repo-to-user) DIRECTION="repo-to-user"; shift ;;
    --force) FORCE_WARN=true; shift ;;
    --force-branch) FORCE_BRANCH=true; shift ;;
    *) REPO_DIR="$1"; shift ;;
  esac
done

if [[ -z "$REPO_DIR" ]]; then
  if ! REPO_DIR="$(resolve_default_repo_dir)"; then
    echo "ERROR: Could not resolve the edge-dev-agents repo. Run with an explicit repo path." >&2
    echo "Usage: convention-sync.sh [repo-dir] [--stage] [--commit -m \"message\"]" >&2
    exit 1
  fi
fi

if ! validate_repo_dir "$REPO_DIR"; then
  exit 1
fi

# Self-update before restoring: the extra-tree list is data inside this script,
# so a machine whose script predates a tree addition would silently skip that
# tree on --repo-to-user (the "run it twice" failure). If the repo carries a
# different version of this script, install it first and re-exec with the
# original args — the restored run then knows every tree the repo expects.
# Guarded by CONVENTION_SYNC_SELF_UPDATED so a copy failure can't loop; the
# canonical home path comes from CONVENTION_SYNC_HOME because $0 is the
# stable temp copy, not the installed script.
if [[ "$DIRECTION" == "repo-to-user" && -z "${CONVENTION_SYNC_SELF_UPDATED:-}" ]]; then
  _repo_self="$REPO_DIR/.cursor/skills/convention-sync/scripts/convention-sync.sh"
  _home_self="${CONVENTION_SYNC_HOME:-$HOME/.cursor/skills/convention-sync/scripts}/convention-sync.sh"
  # Same newer-local rule as the rsync path: only replace when the repo copy's
  # last commit postdates the local file's mtime, so unpushed local edits to
  # this script survive (they'd be skippedNewer in the rsync too). Fallback to
  # the repo file's mtime when git can't date it (non-checkout test fixtures).
  _repo_self_time=$(git -C "$REPO_DIR" log -1 --format=%ct -- ".cursor/skills/convention-sync/scripts/convention-sync.sh" 2>/dev/null || true)
  [[ -n "$_repo_self_time" ]] || _repo_self_time=$(stat -f %m "$_repo_self" 2>/dev/null || echo 0)
  _home_self_time=$(stat -f %m "$_home_self" 2>/dev/null || echo 0)
  if [[ -f "$_repo_self" && "$_repo_self_time" -gt "$_home_self_time" ]] && ! diff -q "$_repo_self" "$_home_self" >/dev/null 2>&1; then
    echo "self-update: installing repo convention-sync.sh over $_home_self and re-executing" >&2
    cp "$_repo_self" "$_home_self"
    chmod +x "$_home_self"
    rm -f "$0"   # this process's stable temp copy; the re-exec makes its own
    CONVENTION_SYNC_SELF_UPDATED=1 CONVENTION_SYNC_STABLE="" \
      exec bash "$_home_self" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
fi

if [[ "$DO_COMMIT" == true && -z "$COMMIT_MSG" ]]; then
  echo "ERROR: --commit requires -m \"message\"" >&2
  exit 1
fi

USER_DIR="$HOME/.cursor"
REPO_CURSOR="$REPO_DIR/.cursor"
DIRS="skills rules scripts"
# .syncignore is canonical in the repo (#4) so a fresh machine inherits the same
# excludes; fall back to ~/.cursor only if the repo doesn't carry one.
if [[ -f "$REPO_CURSOR/.syncignore" ]]; then SYNCIGNORE="$REPO_CURSOR/.syncignore"; else SYNCIGNORE="$USER_DIR/.syncignore"; fi
USER_README="$USER_DIR/README.md"
REPO_ROOT_README="$REPO_DIR/README.md"
LEGACY_REPO_README="$REPO_CURSOR/README.md"

# --- Extra portable trees (beyond ~/.cursor) ----------------------------------
# Home is canonical; these are mirrored into the repo so a second machine can be
# bootstrapped from it. Secrets and machine-local state are excluded so only
# committable code/config is mirrored. Format: "SRC_ABS|REPO_SUBDIR|csv-excludes"
# Excludes are rsync patterns (matched against the path relative to SRC).
EXTRA_TREES=(
  "$HOME/.config/agent-watcher|agent-watcher|credentials.json,secrets,*.log,*.state,*.lock,pool.json,slots.json,watchdog-state.json,oom-repro/forensics,oom-repro/logs,.DS_Store,.git"
  "$HOME/.claude/memory-shared|memory-shared|.DS_Store,.git"
  "$HOME/.claude/workflows|claude-workflows|.DS_Store,.git"
)
# Single committable files (home canonical) → repo relpath. Format: "SRC_FILE|REPO_RELPATH"
EXTRA_FILES=(
  "$HOME/.claude/link-shared-memory.sh|bin/link-shared-memory.sh"
)
# Claude settings PROJECTION (#6): hook REGISTRATIONS live inside
# ~/.claude/settings.json, which is machine-local as a whole (model, theme,
# notification prefs) — but the `hooks` block is part of the orchestration
# system: the hook SCRIPTS sync via the agent-watcher tree, and without their
# registrations a second machine gets scripts that never fire. So the `.hooks`
# key ALONE is projected to the repo (claude-settings/hooks.json, key-sorted)
# on user→repo, and merged back on repo→user / bootstrap by replacing ONLY the
# `.hooks` key of the local settings.json — every other key stays untouched.
# The projecting machine is canonical for the whole block (no per-hook merge).
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOKS_REL="claude-settings/hooks.json"
extra_json="[]"
dropped_hooks_json="[]"
settings_backup=""

# Enumerate registrations a whole-block replace would DESTROY: present in $1
# (the block being overwritten) but absent from $2 (the incoming block), keyed
# on event+command so a re-grouped hook under a different matcher isn't a false
# positive. The whole-block policy is deliberate, but a silent replace loses the
# `matcher` of every local-only registration with no way to recover it, so the
# matcher rides along in the report. Both args are hooks-object JSON.
dropped_hooks_between() {
  jq -n --argjson old "$1" --argjson new "$2" '
    def flat: [ to_entries[] as $e | ($e.value // [])[] as $g | ($g.hooks // [])[] as $h
                | {event: $e.key, matcher: ($g.matcher // ""), command: ($h.command // "")} ];
    ($new | flat) as $n
    | ($old | flat)
    | map(select( . as $x | ($n | any(.event == $x.event and .command == $x.command)) | not ))
  ' 2>/dev/null || echo '[]'
}

# Pull-before-push gate (user-to-repo only).
# Fetches origin and detects whether the remote branch has commits we don't.
# Dry-run includes the count for visibility; --stage/--commit aborts if > 0.
ORIGIN_AHEAD=0
ORIGIN_BRANCH=""
if [[ "$DIRECTION" == "user-to-repo" ]]; then
  if git -C "$REPO_DIR" fetch origin --quiet 2>/dev/null; then
    current_branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
      if git -C "$REPO_DIR" rev-parse --verify --quiet "origin/$current_branch" >/dev/null 2>&1; then
        ORIGIN_AHEAD=$(git -C "$REPO_DIR" rev-list --count "HEAD..origin/$current_branch" 2>/dev/null || echo 0)
        ORIGIN_BRANCH="origin/$current_branch"
      fi
    fi
  fi
fi

if [[ "$DO_STAGE" == "true" && "$ORIGIN_AHEAD" -gt 0 ]]; then
  echo "ERROR: $ORIGIN_BRANCH is $ORIGIN_AHEAD commit(s) ahead of local HEAD." >&2
  echo "Pull first to integrate remote changes, then re-run convention-sync:" >&2
  echo "  cd $REPO_DIR && git pull --rebase" >&2
  exit 1
fi

# Branch safety (#1, user-to-repo + stage). Since 2026-08-26 the sync targets
# the DEFAULT branch directly (the perpetual sync PR is retired; PR #1 merged
# intentionally). The hazard is now the inverse of the old one: the shared
# checkout parked on some OTHER session's feature branch, where committing
# rides the sync onto that branch and a later HEAD:main push can fast-forward
# an open PR's head into main, closing it unreviewed (the PR #3
# develop-staging incident, 2026-08-26). Refuse any non-default branch.
# Override with --force-branch.
if [[ "$DO_STAGE" == "true" && "$DIRECTION" == "user-to-repo" && "$FORCE_BRANCH" != "true" ]]; then
  cur_branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  def_branch="$(git -C "$REPO_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [[ -z "$def_branch" ]] && def_branch="main"
  if [[ "$cur_branch" != "$def_branch" ]]; then
    echo "ERROR: on branch '$cur_branch' but the sync commits directly to '$def_branch'." >&2
    echo "  cd $REPO_DIR && git checkout $def_branch   (or pass --force-branch)" >&2
    echo "If '$cur_branch' is another session's PR branch, committing here would ride the sync onto its PR." >&2
    exit 1
  fi
fi

# Load ignore patterns from .syncignore (one glob per line, # comments, blank lines skipped)
ignore_patterns=()
if [[ -f "$SYNCIGNORE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"       # strip comments
    line="${line%"${line##*[![:space:]]}"}"  # strip trailing whitespace
    [[ -z "$line" ]] && continue
    ignore_patterns+=("$line")
  done < "$SYNCIGNORE"
fi

is_ignored() {
  local entry="$1"
  for pattern in "${ignore_patterns[@]+"${ignore_patterns[@]}"}"; do
    # shellcheck disable=SC2254
    if [[ "$entry" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

new_json="[]"
mod_json="[]"
del_json="[]"
ignored_json="[]"
warnings_json="[]"

repo_path_for() {
  # Translate a sync entry (e.g. "skills/foo.sh" or "README.md") into the
  # path used inside the repo so git log can look up history.
  local entry="$1"
  if [[ "$entry" == "README.md" ]]; then
    printf '%s\n' "README.md"
  else
    printf '%s\n' ".cursor/$entry"
  fi
}

local_path_for() {
  local entry="$1"
  if [[ "$entry" == "README.md" ]]; then
    printf '%s\n' "$USER_DIR/README.md"
  else
    printf '%s\n' "$USER_DIR/$entry"
  fi
}

home_path_for_extra() {
  # Map a repo-relative extra path (e.g. "agent-watcher/session-watchdog.js") back to
  # its canonical home location via the EXTRA_TREES / EXTRA_FILES mappings (#5).
  local rp="$1" tree src dest pair sfile rel
  for tree in "${EXTRA_TREES[@]+"${EXTRA_TREES[@]}"}"; do
    IFS='|' read -r src dest _ <<< "$tree"
    if [[ "$rp" == "$dest/"* ]]; then printf '%s\n' "$src/${rp#"$dest"/}"; return 0; fi
  done
  for pair in "${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}"; do
    IFS='|' read -r sfile rel <<< "$pair"
    if [[ "$rp" == "$rel" ]]; then printf '%s\n' "$sfile"; return 0; fi
  done
  if [[ "$rp" == "$HOOKS_REL" ]]; then printf '%s\n' "$CLAUDE_SETTINGS"; return 0; fi
  return 1
}

file_mtime() {
  local f="$1"
  stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true
}

last_commit_ts() {
  git -C "$REPO_DIR" log -1 --format=%ct -- "$1" 2>/dev/null || true
}

last_commit_short() {
  git -C "$REPO_DIR" log -1 --format='%h %s' -- "$1" 2>/dev/null || true
}

# repo-to-user newer-local protection: true when the LOCAL copy was modified
# after the repo file's last commit — copying (or deleting) would clobber
# unpushed local work. mtime-vs-mtime is wrong here (a fresh `git pull` stamps
# repo files with checkout time), so compare local mtime vs repo COMMIT time.
# --force disables the protection. Skipped files are reported in skippedNewer.
skipped_newer_json="[]"
local_is_newer() {  # $1 = local abs path, $2 = repo path relative to REPO_DIR
  [[ "$FORCE_WARN" == true ]] && return 1
  [[ -f "$1" ]] || return 1
  local lts cts
  lts=$(stat -f %m "$1" 2>/dev/null || echo 0)
  cts="$(last_commit_ts "$2")"
  [[ -n "$cts" ]] || cts=0
  (( lts > cts ))
}

add_warning() {
  warnings_json=$(echo "$warnings_json" | jq \
    --arg f "$1" --arg k "$2" --arg c "$3" \
    '. + [{file: $f, kind: $k, lastCommit: $c}]')
}

compare_readme() {
  local source_readme="$1"
  local target_readme="$2"

  if is_ignored "README.md"; then
    ignored_json=$(echo "$ignored_json" | jq '. + ["README.md"]')
    return
  fi

  if [[ -f "$source_readme" ]]; then
    if [[ ! -f "$target_readme" ]]; then
      new_json=$(echo "$new_json" | jq '. + ["README.md"]')
    elif ! diff -q "$source_readme" "$target_readme" >/dev/null 2>&1; then
      mod_json=$(echo "$mod_json" | jq '. + ["README.md"]')
    fi
  elif [[ -f "$target_readme" ]]; then
    del_json=$(echo "$del_json" | jq '. + ["README.md"]')
  fi
}

compare_dirs() {
  local source_base="$1"
  local target_base="$2"
  local source_path target_path rel entry

  for dir in $DIRS; do
    source_path="$source_base/$dir"
    target_path="$target_base/$dir"

    if [[ -d "$source_path" ]]; then
      while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        entry="$dir/$rel"
        if is_ignored "$entry"; then
          ignored_json=$(echo "$ignored_json" | jq --arg f "$entry" '. + [$f]')
          continue
        fi
        if [[ ! -f "$target_path/$rel" ]]; then
          new_json=$(echo "$new_json" | jq --arg f "$entry" '. + [$f]')
        elif ! diff -q "$source_path/$rel" "$target_path/$rel" >/dev/null 2>&1; then
          mod_json=$(echo "$mod_json" | jq --arg f "$entry" '. + [$f]')
        fi
      done < <(cd "$source_path" && find . -type f ! -name '.DS_Store' | sed 's|^\./||')
    fi

    if [[ -d "$target_path" ]]; then
      while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        entry="$dir/$rel"
        is_ignored "$entry" && continue
        if [[ ! -f "$source_path/$rel" ]]; then
          del_json=$(echo "$del_json" | jq --arg f "$entry" '. + [$f]')
        fi
      done < <(cd "$target_path" && find . -type f ! -name '.DS_Store' | sed 's|^\./||')
    fi
  done
}

# Process the extra portable trees + files (user-to-repo only). In "dryrun" mode
# it only populates extra_json for the summary; in "stage" mode it rsyncs/copies
# into the repo (honoring excludes) and git-adds, then records the actually-staged
# paths. extra_json is reset each call so a dryrun then stage doesn't double-count.
process_extra() {
  local mode="$1" tree src dest excludes destpath pair sfile rel rp pat line
  local exargs expats
  extra_json="[]"
  dropped_hooks_json="[]"   # reset: a dryrun then stage must not double-report
  for tree in "${EXTRA_TREES[@]+"${EXTRA_TREES[@]}"}"; do
    IFS='|' read -r src dest excludes <<< "$tree"
    [[ -d "$src" ]] || continue
    exargs=(); expats=()
    IFS=',' read -ra expats <<< "$excludes"   # split without glob-expanding patterns
    for pat in "${expats[@]+"${expats[@]}"}"; do [[ -n "$pat" ]] && exargs+=( "--exclude=$pat" ); done
    destpath="$REPO_DIR/$dest"
    if [[ "$mode" == "stage" ]]; then
      mkdir -p "$destpath"
      # rsync stdout → /dev/null so the script's stdout stays pure JSON.
      rsync -rlptc --delete "${exargs[@]}" "$src/" "$destpath/" >/dev/null
      # Defensive: guarantee excluded files never land in the repo regardless of
      # rsync-implementation exclude quirks (openrsync and rsync honor some bare
      # filename patterns differently — this is why slots.json once slipped through).
      for pat in "${expats[@]+"${expats[@]}"}"; do
        [[ -z "$pat" ]] && continue
        if [[ "$pat" == */* ]]; then rm -rf "${destpath:?}/$pat"
        else find "$destpath" -name "$pat" -exec rm -rf {} + 2>/dev/null || true; fi
      done
      git -C "$REPO_DIR" add -A "$dest" >/dev/null 2>&1 || true
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        extra_json=$(echo "$extra_json" | jq --arg f "$line" '. + [$f]')
      done < <(git -C "$REPO_DIR" diff --cached --name-only -- "$dest" 2>/dev/null)
    else
      while IFS= read -r line; do
        [[ -z "$line" || "$line" == */ ]] && continue
        case "$line" in
          "sending "*|"sent "*|"total "*|"created "*|"building "*|"delta"*|"Transfer "*|"transferred "*|"deleting "*|"deleting"|"."|"./") continue ;;
        esac
        extra_json=$(echo "$extra_json" | jq --arg f "$dest/$line" '. + [$f]')
      done < <(rsync -rlptc -n -v --delete "${exargs[@]}" "$src/" "$destpath/" 2>/dev/null)
    fi
  done
  for pair in "${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}"; do
    IFS='|' read -r sfile rel <<< "$pair"
    [[ -f "$sfile" ]] || continue
    rp="$REPO_DIR/$rel"
    if [[ "$mode" == "stage" ]]; then
      mkdir -p "$(dirname "$rp")"
      cp "$sfile" "$rp"
      git -C "$REPO_DIR" add "$rel" >/dev/null 2>&1 || true
      if ! git -C "$REPO_DIR" diff --cached --quiet -- "$rel" 2>/dev/null; then
        extra_json=$(echo "$extra_json" | jq --arg f "$rel" '. + [$f]')
      fi
    else
      if [[ ! -f "$rp" ]] || ! diff -q "$sfile" "$rp" >/dev/null 2>&1; then
        extra_json=$(echo "$extra_json" | jq --arg f "$rel" '. + [$f]')
      fi
    fi
  done
  # Hooks projection export (#6): settings.json .hooks → repo. Skipped when the
  # local hooks block is missing/empty so an unconfigured machine can never
  # blank the canonical registrations in the repo.
  local hcur hrepo hrp
  hrp="$REPO_DIR/$HOOKS_REL"
  hcur=$(jq -S '.hooks // {}' "$CLAUDE_SETTINGS" 2>/dev/null || echo '{}')
  if [[ "$hcur" != "{}" ]]; then
    hrepo=$(jq -S . "$hrp" 2>/dev/null || echo '')
    if [[ "$hcur" != "$hrepo" ]]; then
      # Mirror of the restore-side report: exporting this machine's block replaces
      # the canonical one, so registrations only the REPO has would be destroyed
      # for every other machine. The stale-local warning on HOOKS_REL blocks the
      # stage; this names what would have been lost.
      if [[ -n "$hrepo" ]]; then
        dropped_hooks_json=$(dropped_hooks_between "$hrepo" "$hcur")
      fi
      if [[ "$mode" == "stage" ]]; then
        mkdir -p "$(dirname "$hrp")"
        printf '%s\n' "$hcur" > "$hrp"
        git -C "$REPO_DIR" add "$HOOKS_REL" >/dev/null 2>&1 || true
        if ! git -C "$REPO_DIR" diff --cached --quiet -- "$HOOKS_REL" 2>/dev/null; then
          extra_json=$(echo "$extra_json" | jq --arg f "$HOOKS_REL" '. + [$f]')
        fi
      else
        extra_json=$(echo "$extra_json" | jq --arg f "$HOOKS_REL" '. + [$f]')
      fi
    fi
  fi
}

# Reverse of process_extra (#5): pull the portable trees repo → home for
# --repo-to-user, so de-staling a second machine restores extra-tree files (e.g.
# agent-watcher scripts) — not just ~/.cursor. NO --delete: home-local state/secret
# files (credentials.json, pool.json, …) are excluded from the repo and must never
# be removed from home.
process_extra_reverse() {
  local mode="$1" tree src dest excludes destpath pair sfile rel rp pat line
  local exargs expats
  extra_json="[]"
  dropped_hooks_json="[]"   # reset: a dryrun then stage must not double-report
  for tree in "${EXTRA_TREES[@]+"${EXTRA_TREES[@]}"}"; do
    IFS='|' read -r src dest excludes <<< "$tree"
    destpath="$REPO_DIR/$dest"
    [[ -d "$destpath" ]] || continue
    exargs=(); expats=()
    IFS=',' read -ra expats <<< "$excludes"
    for pat in "${expats[@]+"${expats[@]}"}"; do [[ -n "$pat" ]] && exargs+=( "--exclude=$pat" ); done
    if [[ "$mode" == "stage" ]]; then
      mkdir -p "$src"
      # newer-local protection (see local_is_newer): exclude files whose local
      # copy postdates the repo file's last commit, report them in skippedNewer.
      while IFS= read -r line; do
        [[ -z "$line" || "$line" == */ ]] && continue
        case "$line" in
          "sending "*|"sent "*|"total "*|"created "*|"building "*|"delta"*|"Transfer "*|"transferred "*|"deleting "*|"deleting"|"."|"./") continue ;;
        esac
        if local_is_newer "$src/$line" "$dest/$line"; then
          exargs+=( "--exclude=/$line" )
          skipped_newer_json=$(echo "$skipped_newer_json" | jq --arg f "$dest/$line" '. + [$f]')
        fi
      done < <(rsync -rlptc -n -v "${exargs[@]}" "$destpath/" "$src/" 2>/dev/null)
      # Record what the real transfer actually moved (post newer-local excludes),
      # so a restore that rewrites the whole tree can't report extraTotal 0 and
      # read as "nothing happened". -v output is parsed, not discarded.
      while IFS= read -r line; do
        [[ -z "$line" || "$line" == */ ]] && continue
        case "$line" in
          "sending "*|"sent "*|"total "*|"created "*|"building "*|"delta"*|"Transfer "*|"transferred "*|"deleting "*|"deleting"|"."|"./") continue ;;
        esac
        extra_json=$(echo "$extra_json" | jq --arg f "$dest/$line" '. + [$f]')
      done < <(rsync -rlptc -v "${exargs[@]}" "$destpath/" "$src/" 2>/dev/null)
    else
      while IFS= read -r line; do
        [[ -z "$line" || "$line" == */ ]] && continue
        case "$line" in
          "sending "*|"sent "*|"total "*|"created "*|"building "*|"delta"*|"Transfer "*|"transferred "*|"deleting "*|"deleting"|"."|"./") continue ;;
        esac
        extra_json=$(echo "$extra_json" | jq --arg f "$dest/$line" '. + [$f]')
      done < <(rsync -rlptc -n -v "${exargs[@]}" "$destpath/" "$src/" 2>/dev/null)
    fi
  done
  for pair in "${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}"; do
    IFS='|' read -r sfile rel <<< "$pair"
    rp="$REPO_DIR/$rel"
    [[ -f "$rp" ]] || continue
    if [[ ! -f "$sfile" ]] || ! diff -q "$rp" "$sfile" >/dev/null 2>&1; then
      if [[ "$mode" == "stage" ]]; then
        mkdir -p "$(dirname "$sfile")"; cp "$rp" "$sfile"
      fi
      extra_json=$(echo "$extra_json" | jq --arg f "$rel" '. + [$f]')
    fi
  done
  # Hooks projection restore (#6): repo hooks.json → local settings.json,
  # replacing ONLY the .hooks key (all other keys are machine-local and stay).
  # Creates settings.json with just {hooks} on a fresh machine. Written via
  # temp+mv so a mid-write crash can't leave a truncated settings.json.
  local hrp hcur hnew merged
  hrp="$REPO_DIR/$HOOKS_REL"
  if [[ -f "$hrp" ]] && jq -e 'type == "object"' "$hrp" >/dev/null 2>&1; then
    hcur=$(jq -S '.hooks // {}' "$CLAUDE_SETTINGS" 2>/dev/null || echo '{}')
    hnew=$(jq -S . "$hrp")
    if [[ "$hnew" != "$hcur" ]]; then
      # Computed in BOTH modes so the dry run warns BEFORE anything is destroyed.
      dropped_hooks_json=$(dropped_hooks_between "$hcur" "$hnew")
      if [[ "$mode" == "stage" ]]; then
        if [[ -f "$CLAUDE_SETTINGS" ]]; then
          # Timestamped backup: the whole-block replace is unrecoverable
          # otherwise, and droppedHooks alone can't restore hook ordering.
          settings_backup="$CLAUDE_SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
          cp "$CLAUDE_SETTINGS" "$settings_backup"
          merged=$(jq -S --slurpfile h "$hrp" '.hooks = $h[0]' "$CLAUDE_SETTINGS")
        else
          mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
          merged=$(jq -nS --slurpfile h "$hrp" '{hooks: $h[0]}')
        fi
        [[ -n "$merged" ]] && printf '%s\n' "$merged" > "$CLAUDE_SETTINGS.tmp.$$" && mv "$CLAUDE_SETTINGS.tmp.$$" "$CLAUDE_SETTINGS"
      fi
      extra_json=$(echo "$extra_json" | jq --arg f "$HOOKS_REL" '. + [$f]')
    fi
  fi
}

extra_deletion_warnings() {
  # Flag repo extra-tree files MISSING from home (#5): a user→repo sync would
  # --delete them. Mirrors compare_dirs' deletion protection for the portable
  # trees, so a stale/incomplete machine can't silently remove another machine's
  # extra-tree work. Honors each tree's excludes.
  local tree src dest excludes destpath rel pat skip expats
  for tree in "${EXTRA_TREES[@]+"${EXTRA_TREES[@]}"}"; do
    IFS='|' read -r src dest excludes <<< "$tree"
    destpath="$REPO_DIR/$dest"
    [[ -d "$destpath" ]] || continue
    expats=(); IFS=',' read -ra expats <<< "$excludes"
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      skip=false
      for pat in "${expats[@]+"${expats[@]}"}"; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2053
        if [[ "$rel" == $pat || "$(basename "$rel")" == $pat || "$rel" == $pat/* ]]; then skip=true; break; fi
      done
      $skip && continue
      [[ -e "$src/$rel" ]] && continue
      add_warning "$dest/$rel" "deletion" "$(last_commit_short "$dest/$rel")"
    done < <(cd "$destpath" && find . -type f ! -name '.DS_Store' | sed 's|^\./||')
  done
}

extra_total=0
if [[ "$DIRECTION" == "user-to-repo" ]]; then
  compare_readme "$USER_README" "$REPO_ROOT_README"
  compare_dirs "$USER_DIR" "$REPO_CURSOR"

  if [[ -f "$LEGACY_REPO_README" ]] && ! is_ignored ".cursor/README.md"; then
    del_json=$(echo "$del_json" | jq '. + [".cursor/README.md"]')
  fi

  process_extra "dryrun"
  extra_total=$(echo "$extra_json" | jq 'length')

  # Extra-tree staleness warnings (#5): give the portable trees the same
  # protection as ~/.cursor. For each differing extra file, if the repo's last
  # commit is newer than the local copy, flag stale-local so the safety gate
  # above catches it before it can clobber another machine's work.
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    home_p="$(home_path_for_extra "$entry")" || continue
    commit_ts="$(last_commit_ts "$entry")"
    [[ -z "$commit_ts" ]] && continue
    home_mtime="$(file_mtime "$home_p")"
    [[ -z "$home_mtime" ]] && continue
    if [[ "$commit_ts" -gt "$home_mtime" ]]; then
      add_warning "$entry" "stale-local" "$(last_commit_short "$entry")"
    fi
  done < <(echo "$extra_json" | jq -r '.[]')

  extra_deletion_warnings            # #5: flag repo extra files home would --delete
else
  compare_readme "$REPO_ROOT_README" "$USER_README"
  compare_dirs "$REPO_CURSOR" "$USER_DIR"

  process_extra_reverse "dryrun"            # #5: reverse-sync the portable trees too
  extra_total=$(echo "$extra_json" | jq 'length')
fi

total=$(echo "$new_json $mod_json $del_json" | jq -s '.[0] + .[1] + .[2] | length')

# Compute upstream-divergence warnings (user-to-repo only).
# Compares each affected path's most-recent commit timestamp to the local
# file's mtime. If the upstream commit is newer, the local copy is likely
# stale and overwriting would clobber another machine's work.
if [[ "$DIRECTION" == "user-to-repo" ]]; then
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    repo_p="$(repo_path_for "$entry")"
    local_p="$(local_path_for "$entry")"
    commit_ts="$(last_commit_ts "$repo_p")"
    [[ -z "$commit_ts" ]] && continue
    local_mtime="$(file_mtime "$local_p")"
    [[ -z "$local_mtime" ]] && continue
    if [[ "$commit_ts" -gt "$local_mtime" ]]; then
      add_warning "$entry" "stale-local" "$(last_commit_short "$repo_p")"
    fi
  done < <(echo "$mod_json" | jq -r '.[]')

  # New files: warn if path has prior history (re-adding something previously
  # deleted upstream after our local was last written).
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    repo_p="$(repo_path_for "$entry")"
    local_p="$(local_path_for "$entry")"
    commit_ts="$(last_commit_ts "$repo_p")"
    [[ -z "$commit_ts" ]] && continue
    local_mtime="$(file_mtime "$local_p")"
    [[ -z "$local_mtime" ]] && continue
    if [[ "$commit_ts" -gt "$local_mtime" ]]; then
      add_warning "$entry" "re-adding-deleted" "$(last_commit_short "$repo_p")"
    fi
  done < <(echo "$new_json" | jq -r '.[]')

  # Deletions: always warn — no local mtime to compare against.
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    repo_p="$(repo_path_for "$entry")"
    last_c="$(last_commit_short "$repo_p")"
    [[ -z "$last_c" ]] && continue
    add_warning "$entry" "deletion" "$last_c"
  done < <(echo "$del_json" | jq -r '.[]')
fi

SCRIPT_DIR="${CONVENTION_SYNC_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Ensure ~/.claude/skills symlink points to ~/.cursor/skills
CLAUDE_SKILLS="$HOME/.claude/skills"
if [[ -L "$CLAUDE_SKILLS" ]]; then
  link_target="$(readlink "$CLAUDE_SKILLS")"
  if [[ "$link_target" != "$USER_DIR/skills" ]]; then
    rm "$CLAUDE_SKILLS"
    ln -s "$USER_DIR/skills" "$CLAUDE_SKILLS"
  fi
elif [[ ! -e "$CLAUDE_SKILLS" ]]; then
  mkdir -p "$(dirname "$CLAUDE_SKILLS")"
  ln -s "$USER_DIR/skills" "$CLAUDE_SKILLS"
fi

# Regenerate ~/.claude/CLAUDE.md from alwaysApply rules
if [[ -x "$SCRIPT_DIR/generate-claude-md.sh" ]]; then
  "$SCRIPT_DIR/generate-claude-md.sh" >/dev/null
fi

# Safety gate (#2/#3/#6): refuse a staging run that would DELETE or overwrite
# canonical files with stale local copies. These warnings used to be advisory —
# that was the exact hole that let a stale/incomplete machine clobber another
# machine's work. Block by default; override with --force.
if [[ "$DO_STAGE" == "true" && "$DIRECTION" == "user-to-repo" && "$FORCE_WARN" != "true" ]]; then
  blocking=$(echo "$warnings_json" | jq '[.[] | select(.kind=="deletion" or .kind=="stale-local" or .kind=="re-adding-deleted")] | length')
  if [[ "$blocking" -gt 0 ]]; then
    echo "ERROR: $blocking blocking warning(s) — this sync would delete or revert canonical files:" >&2
    echo "$warnings_json" | jq -r '.[] | select(.kind=="deletion" or .kind=="stale-local" or .kind=="re-adding-deleted") | "  [\(.kind)] \(.file)  (\(.lastCommit))"' >&2
    outgoing=$(echo "$new_json" | jq 'length')
    if [[ "$outgoing" -gt 0 ]]; then
      echo "Bidirectional divergence: also $outgoing local-only addition(s) to push." >&2
      echo "Fix order: 'convention-sync --repo-to-user --stage' (de-stale this machine), then re-run to push." >&2
    else
      echo "This machine is stale — run 'convention-sync --repo-to-user --stage' to update it instead of overwriting upstream." >&2
    fi
    echo "To overwrite upstream anyway: re-run with --force." >&2
    exit 1
  fi

  # Hook registrations the export would blank for every other machine. The
  # stale-local warning above is mtime-based and misses this whenever the local
  # settings.json was touched recently, so gate on the content diff directly.
  dropped_n=$(echo "$dropped_hooks_json" | jq 'length')
  if [[ "$dropped_n" -gt 0 ]]; then
    echo "ERROR: exporting this machine's hooks block would drop $dropped_n canonical registration(s):" >&2
    echo "$dropped_hooks_json" | jq -r '.[] | "  [\(.event)] \(.matcher)  ->  \(.command)"' >&2
    echo "The projecting machine is canonical for the WHOLE block, so these would stop firing everywhere." >&2
    echo "De-stale first: 'convention-sync --repo-to-user --stage', re-add any local-only hooks, then re-run." >&2
    echo "Machine-specific hooks belong in ~/.claude/settings.local.json (never projected)." >&2
    echo "To drop them anyway: re-run with --force." >&2
    exit 1
  fi
fi

if [[ "$DO_STAGE" == true ]] && (( total + extra_total > 0 )); then
  all_copy=$(echo "$new_json $mod_json" | jq -sr '.[0] + .[1] | .[]')
  all_del=$(echo "$del_json" | jq -r '.[]')

  if [[ "$DIRECTION" == "user-to-repo" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$f" == "README.md" ]]; then
        cp "$USER_DIR/$f" "$REPO_DIR/$f"
      else
        mkdir -p "$(dirname "$REPO_CURSOR/$f")"
        cp "$USER_DIR/$f" "$REPO_CURSOR/$f"
      fi
    done <<< "$all_copy"

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$f" == "README.md" ]]; then
        rm -f "$REPO_DIR/$f"
      elif [[ "$f" == ".cursor/README.md" ]]; then
        rm -f "$LEGACY_REPO_README"
      else
        rm -f "$REPO_CURSOR/$f"
      fi
    done <<< "$all_del"

    cd "$REPO_DIR"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$f" == "README.md" ]]; then
        git add "$f"
      else
        git add ".cursor/$f"
      fi
    done <<< "$all_copy"

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$f" == "README.md" ]]; then
        git rm -f --quiet "$f" 2>/dev/null || true
      elif [[ "$f" == ".cursor/README.md" ]]; then
        git rm -f --quiet "$f" 2>/dev/null || true
      else
        git rm -f --quiet ".cursor/$f" 2>/dev/null || true
      fi
    done <<< "$all_del"

    process_extra "stage"
    extra_total=$(echo "$extra_json" | jq 'length')

    if [[ "$DO_COMMIT" == true ]]; then
      git commit -m "$COMMIT_MSG" >&2   # keep stdout pure JSON
    fi
  else
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$f" == "README.md" ]]; then
        if local_is_newer "$USER_DIR/$f" "$f"; then
          skipped_newer_json=$(echo "$skipped_newer_json" | jq --arg f "$f" '. + [$f]'); continue
        fi
        cp "$REPO_DIR/$f" "$USER_DIR/$f"
      else
        if local_is_newer "$USER_DIR/$f" ".cursor/$f"; then
          skipped_newer_json=$(echo "$skipped_newer_json" | jq --arg f "$f" '. + [$f]'); continue
        fi
        mkdir -p "$(dirname "$USER_DIR/$f")"
        cp "$REPO_CURSOR/$f" "$USER_DIR/$f"
      fi
    done <<< "$all_copy"

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if local_is_newer "$USER_DIR/$f" ".cursor/$f"; then
        skipped_newer_json=$(echo "$skipped_newer_json" | jq --arg f "$f" '. + [$f]'); continue
      fi
      rm -f "$USER_DIR/$f"
    done <<< "$all_del"

    process_extra_reverse "stage"           # #5: restore portable trees to home
    extra_total=$(echo "$extra_json" | jq 'length')
  fi
fi

jq -n \
  --arg repoDir "$REPO_DIR" \
  --argjson new "$new_json" \
  --argjson modified "$mod_json" \
  --argjson deleted "$del_json" \
  --argjson ignored "$ignored_json" \
  --argjson warnings "$warnings_json" \
  --argjson total "$total" \
  --argjson extra "$extra_json" \
  --argjson extraTotal "${extra_total:-0}" \
  --argjson originAhead "$ORIGIN_AHEAD" \
  --arg originBranch "$ORIGIN_BRANCH" \
  --argjson skippedNewer "$skipped_newer_json" \
  --argjson droppedHooks "$dropped_hooks_json" \
  --arg settingsBackup "$settings_backup" \
  --arg staged "$DO_STAGE" \
  --arg committed "$DO_COMMIT" \
  '{repoDir: $repoDir, originBranch: $originBranch, originAhead: $originAhead, total: $total, new: $new, modified: $modified, deleted: $deleted, ignored: $ignored, warnings: $warnings, extra: $extra, extraTotal: $extraTotal, skippedNewer: $skippedNewer, droppedHooks: $droppedHooks, settingsBackup: $settingsBackup, staged: ($staged == "true"), committed: ($committed == "true")}'
