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

REPO_DIR=""
DO_STAGE=false
DO_COMMIT=false
COMMIT_MSG=""
DIRECTION="user-to-repo"

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
SYNCIGNORE="$USER_DIR/.syncignore"
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
      rsync -rlpt --delete "${exargs[@]}" "$src/" "$destpath/" >/dev/null
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
          "sending "*|"sent "*|"total "*|"created "*|"building "*|"delta"*|"Transfer "*|"transferred "*|"."|"./") continue ;;
        esac
        extra_json=$(echo "$extra_json" | jq --arg f "$dest/$line" '. + [$f]')
      done < <(rsync -rlpt -n -v --delete "${exargs[@]}" "$src/" "$destpath/" 2>/dev/null)
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

extra_total=0
if [[ "$DIRECTION" == "user-to-repo" ]]; then
  compare_readme "$USER_README" "$REPO_ROOT_README"
  compare_dirs "$USER_DIR" "$REPO_CURSOR"

  if [[ -f "$LEGACY_REPO_README" ]] && ! is_ignored ".cursor/README.md"; then
    del_json=$(echo "$del_json" | jq '. + [".cursor/README.md"]')
  fi

  process_extra "dryrun"
  extra_total=$(echo "$extra_json" | jq 'length')
else
  compare_readme "$REPO_ROOT_README" "$USER_README"
  compare_dirs "$REPO_CURSOR" "$USER_DIR"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
      git commit -m "$COMMIT_MSG"
    fi
  else
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ "$f" == "README.md" ]]; then
        cp "$REPO_DIR/$f" "$USER_DIR/$f"
      else
        mkdir -p "$(dirname "$USER_DIR/$f")"
        cp "$REPO_CURSOR/$f" "$USER_DIR/$f"
      fi
    done <<< "$all_copy"

    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      rm -f "$USER_DIR/$f"
    done <<< "$all_del"
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
  --arg staged "$DO_STAGE" \
  --arg committed "$DO_COMMIT" \
  '{repoDir: $repoDir, originBranch: $originBranch, originAhead: $originAhead, total: $total, new: $new, modified: $modified, deleted: $deleted, ignored: $ignored, warnings: $warnings, extra: $extra, extraTotal: $extraTotal, staged: ($staged == "true"), committed: ($committed == "true")}'
