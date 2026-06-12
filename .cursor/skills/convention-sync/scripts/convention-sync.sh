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
  "$HOME/.config/agent-watcher|agent-watcher|credentials.json,*.log,*.state,pool.json,slots.json,watchdog-state.json,oom-repro/forensics,oom-repro/logs,.DS_Store,.git"
  "$HOME/.claude/memory-shared|memory-shared|.DS_Store,.git"
)
# Single committable files (home canonical) → repo relpath. Format: "SRC_FILE|REPO_RELPATH"
EXTRA_FILES=(
  "$HOME/.claude/link-shared-memory.sh|bin/link-shared-memory.sh"
)
extra_json="[]"

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

# Branch safety (#1, user-to-repo + stage). The top hazard is a fresh clone sitting
# on the default branch, where `git push origin HEAD` would bypass the sync PR and
# push straight to main. Refuse the default branch; if an open sync PR exists,
# require its head branch. Override with --force-branch.
if [[ "$DO_STAGE" == "true" && "$DIRECTION" == "user-to-repo" && "$FORCE_BRANCH" != "true" ]]; then
  cur_branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  def_branch="$(git -C "$REPO_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [[ -z "$def_branch" ]] && def_branch="main"
  sync_branch="$(cd "$REPO_DIR" && gh pr list --state open --json headRefName --jq '.[0].headRefName' 2>/dev/null || true)"
  if [[ "$cur_branch" == "$def_branch" ]]; then
    echo "ERROR: refusing to sync onto the default branch '$cur_branch'." >&2
    echo "convention-sync targets a PR branch, not '$def_branch'." >&2
    [[ -n "$sync_branch" ]] && echo "  cd $REPO_DIR && git checkout $sync_branch" >&2
    echo "(override with --force-branch only if you truly mean to commit to '$def_branch')." >&2
    exit 1
  fi
  if [[ -n "$sync_branch" && "$cur_branch" != "$sync_branch" ]]; then
    echo "ERROR: on branch '$cur_branch' but the open sync PR targets '$sync_branch'." >&2
    echo "  cd $REPO_DIR && git checkout $sync_branch   (or pass --force-branch)" >&2
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
      rsync -rlptc "${exargs[@]}" "$destpath/" "$src/" >/dev/null
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
    if [[ "$mode" == "stage" ]]; then
      mkdir -p "$(dirname "$sfile")"; cp "$rp" "$sfile"
    else
      if [[ ! -f "$sfile" ]] || ! diff -q "$rp" "$sfile" >/dev/null 2>&1; then
        extra_json=$(echo "$extra_json" | jq --arg f "$rel" '. + [$f]')
      fi
    fi
  done
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
  --arg staged "$DO_STAGE" \
  --arg committed "$DO_COMMIT" \
  '{repoDir: $repoDir, originBranch: $originBranch, originAhead: $originAhead, total: $total, new: $new, modified: $modified, deleted: $deleted, ignored: $ignored, warnings: $warnings, extra: $extra, extraTotal: $extraTotal, skippedNewer: $skippedNewer, staged: ($staged == "true"), committed: ($committed == "true")}'
