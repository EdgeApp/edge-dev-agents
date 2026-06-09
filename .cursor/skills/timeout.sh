#!/usr/bin/env bash
# timeout.sh — portable `timeout(1)` shim.
#
# macOS ships no `timeout` and often no coreutils `gtimeout`, yet the agent skills
# (build-and-test `blocking-in-turn-waits`, one-shot `pr-watch-bounded-poll` /
# `never-self-respawn`) prescribe `timeout <seconds> <cmd>` to bound every wait.
# Symlinked onto PATH as `timeout`, this makes those bare `timeout <s> ...` calls
# work everywhere: it execs a real gtimeout/timeout if present, else falls back to
# a perl `alarm()` implementation (perl is always present on macOS).
#
# Supported form (what the skills actually use):
#   timeout <duration> <command> [args...]
# <duration> may be a bare number (seconds) or have a coreutils suffix (s/m/h).
# Exit codes mirror coreutils: 124 on timeout, else the command's own exit code.
set -uo pipefail

# Prefer a real implementation if one is on PATH (but never recurse into ourselves).
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
for real in gtimeout timeout; do
  p="$(command -v "$real" 2>/dev/null || true)"
  if [[ -n "$p" && "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")" != "$self" ]]; then
    exec "$p" "$@"
  fi
done

[[ $# -ge 2 ]] || { echo "usage: timeout <duration> <command> [args...]" >&2; exit 125; }
dur="$1"; shift

# perl fallback: parse duration suffix → seconds, run cmd under alarm().
exec perl -e '
  my $d = shift @ARGV;
  my %mult = (s=>1, m=>60, h=>3600, d=>86400);
  if ($d =~ /^([0-9.]+)([smhd])?$/) { $d = $1 * ($2 ? $mult{$2} : 1); }
  my $pid = fork();
  if (!defined $pid) { die "fork: $!"; }
  if ($pid == 0) { exec @ARGV or do { warn "exec: $!"; exit 127 }; }
  $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; exit 124; };
  alarm($d);
  waitpid($pid, 0);
  my $rc = $?;
  alarm(0);
  exit($rc & 127 ? 128 + ($rc & 127) : $rc >> 8);
' "$dur" "$@"
