#!/usr/bin/env bash
# node-modules-freshness.sh: shared "does node_modules match this lockfile?"
# logic plus the locks that keep installs and APFS clones from racing.
# Sourced (never executed) by:
#   setup-task-workspace.sh     stale check on fresh AND reuse paths
#   refresh-main-checkouts.sh   main-checkout npm ci decision + retry
#   lib/node-modules-reinstall.sh  the mv-aside + npm ci worker
#   install-deps.sh, ios-rn-build.sh  clear the marker / skip a no-op install
#
# FRESHNESS = normalized hash of <dir>/package-lock.json (what the branch wants)
# equals the normalized hash of <dir>/node_modules/.package-lock.json (npm's
# hidden lockfile: what is actually INSTALLED). Normalization keeps only the
# resolved tree, `path -> version|resolved|integrity`, and drops:
#   - the root entry and top-level name/version: a version-bump commit changes
#     only those, and a byte compare flagged it as a stale tree;
#   - optional/devOptional entries: the hidden lockfile omits optional packages
#     npm skipped for this platform (esbuild/linux-*, emnapi, ...), so keeping
#     them makes every real install look stale;
#   - extraneous entries (present only in the hidden lockfile).
# Verified 0 diff between the two sides on every clean ~/git main checkout.
# updot copies built files into node_modules/<dep> without touching the hidden
# lockfile, so an updot-linked tree still hashes fresh (callers rely on that to
# skip installs that would revert the link).
#
# MARKER: <dir>/.stale-node-modules. Human text first, then key=value lines
# (want=, have=, status=, installer_pid=, installer_log=). ios-rn-build.sh
# refuses to build while it exists and the hashes still mismatch.
#
# LOCKS (all under $NM_STATE_DIR, mkdir-based: macOS has no flock(1)):
#   npm-install.lock/        machine-wide: at most one npm ci from these tools
#                            at a time (a scratch install spawns ~1500 node
#                            workers; several at once OOM'd the machine).
#   main-clone/<repo>.clone.<pid>   a setup is APFS-cloning ~/git/<repo>/node_modules
#   main-clone/<repo>.refresh/      refresh-main-checkouts is rewriting that tree
# Clone (reader) and refresh (writer) each PUBLISH first and CHECK second, so
# the two can never both proceed; a loser backs off. Entries whose pid is dead
# are ignored and reaped.

NM_STATE_DIR="${NM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher}"
NM_MARKER_NAME=".stale-node-modules"
NM_WANT=""
NM_HAVE=""

# Normalized hash of a package-lock.json / .package-lock.json. Prints 16 hex
# (`resolved` drops a leading "git+": npm writes git deps as ssh:// in one file
# and git+ssh:// in the other for the same commit, a false stale otherwise.)
# chars; returns 1 when the file is missing or not parseable.
nm_lockfile_hash() {
  local f="$1" out
  [[ -f "$f" ]] || return 1
  out=$(jq -S '(.packages // {}) | del(.[""])
    | with_entries(select(((.value.optional // false) or (.value.devOptional // false) or (.value.extraneous // false)) | not)
      | .value = ((.value.version // "") + "|" + ((.value.resolved // "") | sub("^git\\+"; "")) + "|" + (.value.integrity // "")))' "$f" 2>/dev/null) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | shasum -a 256 | cut -c1-16
}

# nm_hashes <dir> [fallback-lockfile]
# Sets NM_WANT / NM_HAVE. Returns 0 fresh, 1 stale, 2 not determinable
# (no package-lock.json, i.e. yarn or no deps; or unparseable input).
# NM_HAVE comes from node_modules/.package-lock.json; when node_modules exists
# without one, the fallback lockfile (the clone source's) stands in; with no
# fallback the state is unknown (2). A missing node_modules is stale ("absent").
nm_hashes() {
  local dir="$1" fallback="${2:-}"
  NM_WANT=""; NM_HAVE=""
  [[ -f "$dir/package-lock.json" ]] || return 2
  NM_WANT=$(nm_lockfile_hash "$dir/package-lock.json") || { NM_WANT=""; return 2; }
  if [[ ! -d "$dir/node_modules" ]]; then
    NM_HAVE="absent"; return 1
  fi
  if [[ -f "$dir/node_modules/.package-lock.json" ]]; then
    NM_HAVE=$(nm_lockfile_hash "$dir/node_modules/.package-lock.json") || NM_HAVE="unparseable"
  elif [[ -n "$fallback" && -f "$fallback" ]]; then
    NM_HAVE=$(nm_lockfile_hash "$fallback") || NM_HAVE="unparseable"
  else
    NM_HAVE="unknown"; return 2
  fi
  [[ "$NM_WANT" == "$NM_HAVE" ]] && return 0
  return 1
}

nm_marker_path() { printf '%s/%s' "$1" "$NM_MARKER_NAME"; }

# nm_marker_field <dir> <key>: prints the value of the last key= line.
nm_marker_field() {
  local m; m=$(nm_marker_path "$1")
  [[ -f "$m" ]] || return 1
  sed -n "s/^$2=//p" "$m" 2>/dev/null | tail -1
}

# nm_marker_set <dir> <key> <value>: replace-or-append one key= line.
nm_marker_set() {
  local m tmp; m=$(nm_marker_path "$1")
  [[ -f "$m" ]] || return 0
  tmp="$m.tmp.$$"
  { grep -v "^$2=" "$m" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } > "$tmp" && mv -f "$tmp" "$m"
}

# nm_marker_write <dir> <source-description>: uses NM_WANT/NM_HAVE.
nm_marker_write() {
  local dir="$1" src="$2"
  {
    echo "node_modules here does not match this branch's package-lock.json"
    echo "(normalized hash compare; source: $src)."
    echo "Fix: ~/.config/agent-watcher/lib/node-modules-reinstall.sh <this dir>"
    echo "(moves the tree aside, then npm ci; plain npm ci over an APFS clone fails ENOTEMPTY)."
    echo "Do NOT build, bundle, or bake this repo until this file is gone."
    echo "want=$NM_WANT"
    echo "have=$NM_HAVE"
    echo "status=stale"
  } > "$(nm_marker_path "$dir")"
}

# nm_pid_is <pid> <command-substring>: pid alive AND running that command
# (guards against pid reuse).
nm_pid_is() {
  local pid="$1" pat="$2"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -z "$pat" ]] && return 0
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$pat"
}

nm_installer_alive() {
  local pid; pid=$(nm_marker_field "$1" installer_pid 2>/dev/null) || return 1
  nm_pid_is "$pid" node-modules-reinstall
}

# nm_wait_installer <dir> <max-seconds>: 0 when no live installer remains.
nm_wait_installer() {
  local dir="$1" max="${2:-0}" waited=0
  while nm_installer_alive "$dir"; do
    [[ "$waited" -ge "$max" ]] && return 1
    sleep 5; waited=$((waited + 5))
  done
  return 0
}

# nm_clear_marker_if_fresh <dir>: removes the marker when the tree now matches.
# Returns 0 when no marker remains, 1 when it stays.
nm_clear_marker_if_fresh() {
  local dir="$1" m rc=0
  m=$(nm_marker_path "$dir")
  [[ -f "$m" ]] || return 0
  nm_installer_alive "$dir" && return 1
  nm_hashes "$dir" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$m"
    echo ">> node-modules-freshness: node_modules matches package-lock.json ($NM_WANT); cleared $m" >&2
    return 0
  fi
  return 1
}

# ── machine-wide install lock ─────────────────────────────────────────────────
NM_INSTALL_LOCK_HELD=false
nm_install_lock_acquire() {
  local max="${1:-1800}" waited=0 lock="$NM_STATE_DIR/npm-install.lock" pid
  mkdir -p "$NM_STATE_DIR"
  while ! mkdir "$lock" 2>/dev/null; do
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"; continue
    fi
    # A lock dir with no pid file older than 60s is a crashed acquirer.
    if [[ -z "$pid" && -d "$lock" ]] && [[ $(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) )) -gt 60 ]]; then
      rm -rf "$lock"; continue
    fi
    [[ "$waited" -ge "$max" ]] && return 1
    sleep 5; waited=$((waited + 5))
  done
  echo "$$" > "$lock/pid"
  NM_INSTALL_LOCK_HELD=true
}
nm_install_lock_release() {
  $NM_INSTALL_LOCK_HELD || return 0
  rm -rf "$NM_STATE_DIR/npm-install.lock"
  NM_INSTALL_LOCK_HELD=false
}

# ── main-checkout clone (reader) / refresh (writer) handshake ────────────────
nm__refresh_alive() {
  local d="$NM_STATE_DIR/main-clone/$1.refresh" pid
  [[ -d "$d" ]] || return 1
  pid=$(cat "$d/pid" 2>/dev/null || true)
  if [[ -z "$pid" ]]; then
    # just created; the writer has not written its pid yet
    [[ $(( $(date +%s) - $(stat -f %m "$d" 2>/dev/null || date +%s) )) -le 60 ]] && return 0
    rm -rf "$d"; return 1
  fi
  kill -0 "$pid" 2>/dev/null && return 0
  rm -rf "$d"; return 1
}
nm__live_clones() {
  local f pid n=0
  for f in "$NM_STATE_DIR/main-clone/$1.clone."*; do
    [[ -e "$f" ]] || continue
    pid="${f##*.clone.}"
    if kill -0 "$pid" 2>/dev/null; then n=$((n + 1)); else rm -f "$f"; fi
  done
  [[ "$n" -gt 0 ]]
}

# nm_clone_begin <repo> <max-wait-seconds>: returns 1 when a refresh kept the
# tree busy past the wait (caller must not clone).
nm_clone_begin() {
  local repo="$1" max="${2:-30}" waited=0 f
  mkdir -p "$NM_STATE_DIR/main-clone"
  f="$NM_STATE_DIR/main-clone/$repo.clone.$$"
  while :; do
    : > "$f"
    nm__refresh_alive "$repo" || return 0
    rm -f "$f"
    [[ "$waited" -ge "$max" ]] && return 1
    sleep 5; waited=$((waited + 5))
  done
}
nm_clone_end() { rm -f "$NM_STATE_DIR/main-clone/$1.clone.$$"; }

# nm_refresh_begin <repo>: 0 = exclusive; 1 = a clone is live (hold this repo).
nm_refresh_begin() {
  local repo="$1" d
  mkdir -p "$NM_STATE_DIR/main-clone"
  d="$NM_STATE_DIR/main-clone/$repo.refresh"
  nm__refresh_alive "$repo" && return 1
  mkdir "$d" 2>/dev/null || return 1
  echo "$$" > "$d/pid"
  if nm__live_clones "$repo"; then
    rm -rf "$d"; return 1
  fi
  return 0
}
nm_refresh_end() { rm -rf "$NM_STATE_DIR/main-clone/$1.refresh"; }

# ── build-script helpers (ios-rn-build.sh) ────────────────────────────────────
# nm_build_gate <dir> [max-wait]: 0 = may build (no marker, or it cleared after
# waiting for a live reinstall and re-checking hashes); 1 = still stale.
nm_build_gate() {
  local dir="$1" max="${2:-900}"
  [[ -f "$(nm_marker_path "$dir")" ]] || return 0
  if nm_installer_alive "$dir"; then
    echo ">> node-modules-freshness: waiting up to ${max}s for the background node_modules reinstall (pid $(nm_marker_field "$dir" installer_pid))" >&2
    nm_wait_installer "$dir" "$max" || return 1
  fi
  nm_clear_marker_if_fresh "$dir"
}

# nm_install_skippable <dir>: 0 when node_modules already matches the lockfile,
# so an install would change nothing except reverting updot-baked deps.
nm_install_skippable() {
  local rc=0
  nm_hashes "$1" || rc=$?
  [[ "$rc" -eq 0 ]]
}
