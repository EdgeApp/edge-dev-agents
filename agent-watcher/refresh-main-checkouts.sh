#!/usr/bin/env bash
# refresh-main-checkouts.sh — keep the ~/git main checkouts (the APFS-clone
# SOURCES for every agent worktree's node_modules) current with origin.
#
# Why: setup-task-workspace.sh clones node_modules from these checkouts. They
# had NO refresh mechanism (only the GUI gets one via refresh-master-build), so
# a checkout that fell behind poisoned every worktree spawned from it — accb
# sat 64 commits behind with stellar-sdk 0.11.0 in node_modules, which is how
# the 2026-07-30 fleet-wide "Horizon.Server undefined" toast got baked into
# locally-built WebView bundles.
#
# SAFE BY CONSTRUCTION: a checkout is touched ONLY when it is (a) clean (no
# staged/unstaged/untracked changes) AND (b) on its default branch AND (c) no
# setup-task-workspace.sh is APFS-cloning its node_modules right now. Dirty or
# feature-branch checkouts are reported and left alone — never stash, never
# switch, never stomp operator work.
#
# CLONE HANDSHAKE (lib/node-modules-freshness.sh): each touched repo is claimed
# with nm_refresh_begin, which publishes a refresh claim and then backs off
# (HOLD, retried next sweep) if any live setup has registered a clone of that
# repo; setups that start afterwards wait for the claim to clear. Other repos
# and other run activity do not block a sweep.
#
# INSTALL: runs lib/node-modules-reinstall.sh (machine-wide install lock,
# mv-aside + `sfw npm ci`, previous tree restored on failure) when the checkout's
# installed tree differs from its lockfile by NORMALIZED hash, i.e. after a pull
# that really changed deps (a version-bump-only lockfile change does not
# reinstall), after a previous failed install (the mismatch persists, and a
# failure record under $FAIL_DIR forces the retry), or whenever the tree drifted.
# A checkout without node_modules is left uninstalled (reported).
#
# Usage:
#   refresh-main-checkouts.sh [--dry-run] [--require-idle] [--min-interval <sec>] [repo ...]
# Default repo set: the GUI-dependency repos + the GUI itself.
#
# SCHEDULING (launchd, two jobs — never manual):
#   com.jontz.refresh-main-checkouts-daily  04:15 daily, --require-idle
#   com.jontz.refresh-main-checkouts-idle   every 30 min, --require-idle --min-interval 21600
# --require-idle: accepted for the launchd jobs; the per-repo clone handshake
#   above replaced the old whole-sweep skip (any live run session or in_use pool
#   sim), which held every checkout for as long as the fleet was busy.
# --min-interval: skip when the last COMPLETE sweep (stamp file) is fresher than
#   this. The stamp is written only when at least one repo ended current (OK or
#   fast-forwarded) and no repo ended in a retryable state (fetch failure, clone
#   in progress, failed install); otherwise the next 30-min run sweeps again.
# Exit: 0 always (per-repo outcomes in the report; this is maintenance, not a gate).
set -uo pipefail
# launchd starts scripts with a bare PATH; add nvm/homebrew/~/.local/bin (lib header has the details).
source "$HOME/.config/agent-watcher/lib/launchd-env.sh"
source "$HOME/.config/agent-watcher/lib/node-modules-freshness.sh"
REINSTALL="$HOME/.config/agent-watcher/lib/node-modules-reinstall.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
STAMP="$STATE_DIR/main-checkouts-refresh.stamp"
FAIL_DIR="$STATE_DIR/main-checkouts-install-failed"
DRY=false
MIN_INTERVAL=0
REPOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=true; shift ;;
    --require-idle) shift ;;
    --min-interval) MIN_INTERVAL="${2:-0}"; shift 2 ;;
    *) REPOS+=("$1"); shift ;;
  esac
done

if [[ "$MIN_INTERVAL" -gt 0 && -f "$STAMP" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$STAMP" 2>/dev/null || echo 0) ))
  if [[ "$age" -lt "$MIN_INTERVAL" ]]; then
    echo "SKIP: last sweep ${age}s ago (< ${MIN_INTERVAL}s)"
    exit 0
  fi
fi

[[ ${#REPOS[@]} -gt 0 ]] || REPOS=(edge-currency-accountbased edge-exchange-plugins edge-core-js edge-currency-plugins edge-login-ui-rn edge-react-gui)

CLAIMED=""
trap '[[ -z "$CLAIMED" ]] || nm_refresh_end "$CLAIMED"' EXIT
current=0     # repos that ended OK or fast-forwarded (installed tree matching)
retryable=0   # repos whose outcome the next sweep should retry

for r in "${REPOS[@]}"; do
  d="$HOME/git/$r"
  [[ -d "$d/.git" ]] || { echo "$r: SKIP (no checkout)"; continue; }
  cd "$d" || continue
  git fetch origin --quiet 2>/dev/null || { echo "$r: SKIP (fetch failed: offline?)"; retryable=$((retryable + 1)); continue; }
  def=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')
  def=${def:-master}
  cur=$(git branch --show-current)
  behind=$(git rev-list --count "HEAD..origin/$def" 2>/dev/null || echo '?')
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "$r: HOLD (dirty; on $cur; behind origin/$def by $behind) — resolve manually"
    continue
  fi
  if [[ "$cur" != "$def" ]]; then
    echo "$r: HOLD (on branch '$cur', not $def; behind origin/$def by $behind) — switch manually when done"
    continue
  fi

  # Does the installed tree need a reinstall even with no new commits?
  # (a previous install failed, or the tree drifted from the lockfile)
  hrc=0; nm_hashes "$d" || hrc=$?
  prior_fail=false; [[ -f "$FAIL_DIR/$r" ]] && prior_fail=true
  [[ "$NM_HAVE" == "absent" ]] && hrc=2
  if [[ "$behind" == "0" ]] && ! $prior_fail && [[ "$hrc" -ne 1 ]]; then
    echo "$r: OK (current)"
    current=$((current + 1))
    continue
  fi
  if $DRY; then
    if [[ "$behind" == "0" ]]; then
      echo "$r: WOULD reinstall node_modules (installed tree differs from lockfile$($prior_fail && echo "; previous install failed"))"
    else
      echo "$r: WOULD fast-forward $def by $behind commits$(git diff --quiet "HEAD" "origin/$def" -- package-lock.json 2>/dev/null || echo ' + reinstall if the lockfile deps changed')"
    fi
    continue
  fi

  if ! nm_refresh_begin "$r"; then
    echo "$r: HOLD (a task setup is cloning its node_modules right now); retried next sweep"
    retryable=$((retryable + 1))
    continue
  fi
  CLAIMED="$r"

  lock_before=$(git rev-parse "HEAD:package-lock.json" 2>/dev/null || true)
  ffmsg=""
  if [[ "$behind" != "0" ]]; then
    if ! git merge --ff-only "origin/$def" --quiet; then
      echo "$r: HOLD (ff-only merge failed: diverged history); resolve manually"
      nm_refresh_end "$r"; CLAIMED=""
      continue
    fi
    ffmsg="FF'd $def by $behind commits"
  fi
  lock_after=$(git rev-parse "HEAD:package-lock.json" 2>/dev/null || true)

  hrc=0; nm_hashes "$d" || hrc=$?
  need=false
  if [[ "$NM_HAVE" == "absent" ]]; then
    need=false
  elif [[ "$hrc" -eq 1 ]] || $prior_fail; then
    need=true
  elif [[ "$hrc" -eq 2 && "$lock_before" != "$lock_after" ]]; then
    need=true   # no hidden lockfile to compare: fall back to "the pull changed package-lock.json"
  fi

  did=""
  if $need; then
    log="/tmp/refresh-ci-$r.log"
    if NM_NO_MARKER=1 "$REINSTALL" "$d" >"$log" 2>&1; then
      rm -f "$FAIL_DIR/$r"
      did="node_modules reinstalled OK"
      current=$((current + 1))
    else
      mkdir -p "$FAIL_DIR"
      printf 'failed_at=%s\nhead=%s\nlog=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse --short HEAD)" "$log" > "$FAIL_DIR/$r"
      did="node_modules reinstall FAILED (see $log; previous tree kept, retried next sweep)"
      retryable=$((retryable + 1))
    fi
  else
    rm -f "$FAIL_DIR/$r"
    [[ "$NM_HAVE" == "absent" ]] && did="no node_modules in checkout; not installed"
    current=$((current + 1))
  fi
  nm_refresh_end "$r"; CLAIMED=""
  echo "$r: ${ffmsg:-current}${did:+ + $did}"
done

# Stamp a COMPLETE sweep (used by --min-interval): something ended current and
# nothing is waiting on a retry. HOLDs for dirty/feature/diverged checkouts are
# operator-owned and do not block the stamp once another repo succeeded.
if ! $DRY; then
  if [[ "$current" -gt 0 && "$retryable" -eq 0 ]]; then
    mkdir -p "$(dirname "$STAMP")"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP"
  else
    echo "NOSTAMP: $current repo(s) current, $retryable retryable; the next scheduled run sweeps again"
  fi
fi
