#!/usr/bin/env bash
# cmd-executes.sh — shared trigger-precision helper for PreToolUse(Bash) hooks.
# Reads a (mention-stripped) command string on stdin; exit 0 iff the named
# script is being EXECUTED, i.e. its token sits in command position: start of
# a command (^ or after ; & | ( or $( ) or after an explicit bash/sh/source.
# Wrapper prefixes that still run the program are transparent: VAR=x
# assignments, timeout/gtimeout [flags] N, env [flags] [VAR=x ...], nice [-n N],
# nohup, command [-p], exec, time [-p]. 'command -v' only prints a path, so it
# is NOT a wrapper.
# A read-only command that merely NAMES the script path in argument position
# (grep/sed/cat/ls against it) exits 1 and must not fire the calling hook —
# that substring shape produced false blocks across 3 eval cohorts
# (require-subtasks on eCash/Swapuz 2026-08-19; require-concession-validation
# on a read-only sed the same day).
#
# Usage: printf '%s' "$CMD_M" | cmd-executes.sh <script-basename>
# The basename is embedded in an ERE — pass a plain name like "pr-create.sh"
# (dots are escaped here; no other regex metacharacters are expected).
set -uo pipefail
NAME="${1:?usage: cmd-executes.sh <script-basename>}"
ERE="$(printf '%s' "$NAME" | sed 's/\./\\./g')"
W='[[:space:]]'
NS='[^[:space:]]'
ASSIGN="[A-Za-z_][A-Za-z0-9_]*=$NS*"
WRAP="(g?timeout($W+(-[sk]$W+$NS+|-$NS+))*$W+[0-9.]+[smhd]?|env($W+(-u$W+$NS+|-$NS+|$ASSIGN))*|nice($W+(-n$W*-?[0-9]+|-[0-9]+))?|nohup|command($W+-p)?|exec|time($W+-p)?|$ASSIGN)"
grep -qE '(^|[;&|(]|\$\(|\b(bash|sh|source)'"$W"'+)'"$W*($WRAP$W+)*$NS*$ERE"'([[:space:]]|$)'
