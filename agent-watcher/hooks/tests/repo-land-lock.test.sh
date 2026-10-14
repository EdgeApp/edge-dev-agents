#!/usr/bin/env bash
# repo-land-lock.test.sh: one landing per repo at a time.
#
#   repo-land-lock.sh  a second owner is refused (exit 75) while a lease is
#                      live, an expired lease is taken over, the owner's own
#                      acquire renews and never shortens the lease, renew
#                      refuses another owner's or an expired lease, a plain
#                      release keeps a run-level hold, and only the owner
#                      releases.
#
# Runs the real script against a private state folder. Expired leases are
# written by hand with a past expiry, so the test never sleeps.
set -uo pipefail

LOCK="$HOME/.cursor/skills/pr-land/scripts/repo-land-lock.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/repo-land-lock-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
DIR="$XDG_STATE_HOME/agent-watcher/land-locks"
FAILS=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
rc() { "$LOCK" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
field() { jq -r "$2" "$DIR/$1.json" 2>/dev/null; }
# stale <repo> <owner> <seconds from now> [hold]: write a lease by hand.
stale() {
  mkdir -p "$DIR"
  jq -nc --arg o "$2" --argjson ex "$(( $(date +%s) + $3 ))" --argjson h "${4:-false}" \
    '{owner:$o, ts:0, expires:$ex} + (if $h then {hold:true} else {} end)' > "$DIR/$1.json"
}

# --- acquire ---
check "a free repo is leased" "$(rc acquire --repo alpha --owner one)" 0
check "the lease names its owner" "$(field alpha .owner)" one
check "a second owner is refused while the lease is live" "$(rc acquire --repo alpha --owner two)" 75
check "the refused acquire leaves the first owner in place" "$(field alpha .owner)" one
check "the owner's own acquire succeeds again" "$(rc acquire --repo alpha --owner one)" 0
check "owner/name is keyed by name" "$(rc acquire --repo EdgeApp/alpha --owner two)" 75

stale beta gone -60
check "an expired lease is taken over" "$(rc acquire --repo beta --owner two)" 0
check "the takeover names the new owner" "$(field beta .owner)" two

stale gamma one 5000
BEFORE=$(field gamma .expires)
check "a shorter acquire by the owner succeeds" "$(rc acquire --repo gamma --owner one --ttl 60)" 0
check "a shorter acquire never shortens the lease" "$(field gamma .expires)" "$BEFORE"
check "acquire without an owner is a usage error" "$(rc acquire --repo gamma)" 2

# --- renew ---
check "renew with no lease exits 3" "$(rc renew --repo nolease --owner one)" 3
[[ -s "$TMP/err" ]] && fail "renew with no lease is silent" || ok "renew with no lease is silent"
check "renew by another owner is refused" "$(rc renew --repo gamma --owner two)" 1
stale delta one 60
check "renew by the owner succeeds" "$(rc renew --repo delta --owner one --ttl 9000)" 0
[[ "$(field delta .expires)" -gt $(( $(date +%s) + 8000 )) ]] \
  && ok "renew extends the expiry" || fail "renew extends the expiry: $(field delta .expires)"
stale delta one 5000
BEFORE=$(field delta .expires)
"$LOCK" renew --repo delta --owner one --ttl 60 >/dev/null 2>&1
check "a shorter renew never shortens the lease" "$(field delta .expires)" "$BEFORE"
stale epsilon one -60
check "renew of the owner's expired lease is refused" "$(rc renew --repo epsilon --owner one)" 1
stale epsilon one 3
check "renew inside the 5-second margin is refused" "$(rc renew --repo epsilon --owner one)" 1

# --- release ---
check "release by another owner is refused" "$(rc release --repo alpha --owner two)" 1
[[ -f "$DIR/alpha.json" ]] && ok "the refused release keeps the lease" || fail "the refused release keeps the lease"
check "release by the owner succeeds" "$(rc release --repo alpha --owner one)" 0
[[ -f "$DIR/alpha.json" ]] && fail "the owner's release removes the lease" || ok "the owner's release removes the lease"
check "release with no lease succeeds" "$(rc release --repo alpha --owner one)" 0
check "status of a free repo prints free" "$("$LOCK" status --repo alpha)" free

# --- run-level hold ---
check "acquire with a hold succeeds" "$(rc acquire --hold --repo zeta --owner one --ttl 21600)" 0
check "the lease is marked as a hold" "$(field zeta .hold)" true
check "a plain release of a held lease succeeds" "$(rc release --repo zeta --owner one)" 0
[[ -f "$DIR/zeta.json" ]] && ok "a plain release keeps a held lease" || fail "a plain release keeps a held lease"
check "a held lease still refuses a second owner" "$(rc acquire --repo zeta --owner two)" 75
BEFORE=$(field zeta .expires)
"$LOCK" acquire --repo zeta --owner one --ttl 60 >/dev/null 2>&1
check "an inner acquire keeps the hold mark" "$(field zeta .hold)" true
check "an inner acquire never shortens the hold" "$(field zeta .expires)" "$BEFORE"
check "release with the hold flag by another owner is refused" "$(rc release --hold --repo zeta --owner two)" 1
check "release with the hold flag succeeds" "$(rc release --hold --repo zeta --owner one)" 0
[[ -f "$DIR/zeta.json" ]] && fail "release with the hold flag removes the lease" || ok "release with the hold flag removes the lease"
stale eta gone -60 true
check "an expired hold is taken over" "$(rc acquire --repo eta --owner two)" 0
check "the takeover drops the old hold mark" "$(field eta '.hold // false')" false

# --- usage ---
check "an unknown flag is a usage error" "$(rc acquire --repo alpha --owner one --bogus)" 2
check "an unknown command is a usage error" "$(rc grab --repo alpha --owner one)" 2
check "a missing repo is a usage error" "$(rc acquire --owner one)" 2

if [[ "$FAILS" -eq 0 ]]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
