#!/usr/bin/env bash
# spawn-chat-session.sh -- start a FRESH discussion session (no Asana task, no
# slot) in a watchdog-covered tmux session with remote control armed, and hand
# it a brief. The brief lives in a FILE; the session receives only a short
# pointer prompt. A long prompt typed into a just-started TUI via tmux
# send-keys loses its head (a 2 KB brief arrived as its last 731 characters on
# 2026-09-09), so the pointer is kept under 300 characters, pasted through a
# tmux buffer, and verified against the session transcript before this script
# reports success.
#
# Usage:
#   spawn-chat-session.sh --name <slug> --brief-file <path> [--model <id>]
#                         [--cwd <dir>] [--effort low|medium|high|xhigh|max]
#                         [--pointer "<one sentence>"] [--no-chrome]
#   --name        session slug; tmux session = claude-asana-chat-<slug>, RC name chat-<slug>
#   --brief-file  the full brief (markdown or text); the session is told to read it
#   --model       claude model id (default: the CLI default)
#   --pointer     optional one-sentence summary appended to the pointer prompt
#   --no-chrome   omit --chrome (default: Chrome bridge on)
#   --anchor      name the session claude-asana-<slug> with RC <slug> (a named
#                 anchor, exempt from the chat idle reaper once the slug is in
#                 watcher.persistent_anchors) instead of the chat-<slug> shape
# Exit: 0 spawned and pointer verified in the transcript; 1 usage or spawn
#       failure; 3 spawned but the pointer did not arrive intact (session left
#       running for inspection; resend by hand with tmux paste-buffer).
set -uo pipefail
NAME="" BRIEF="" MODEL="" CWD="$HOME/git" EFFORT="" POINTER="" CHROME=true ANCHOR=false
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --brief-file) BRIEF="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --pointer) POINTER="$2"; shift 2 ;;
    --no-chrome) CHROME=false; shift ;;
    --anchor) ANCHOR=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$NAME" ] && [ -n "$BRIEF" ] || { echo "usage: spawn-chat-session.sh --name <slug> --brief-file <path> [--model <id>] [--cwd <dir>] [--pointer <text>] [--no-chrome]" >&2; exit 1; }
BRIEF="${BRIEF/#\~/$HOME}"
[ -r "$BRIEF" ] || { echo "brief file not readable: $BRIEF" >&2; exit 1; }
[ -d "$CWD" ] || { echo "cwd not a directory: $CWD" >&2; exit 1; }
NAME="${NAME#chat-}"
if $ANCHOR; then S="claude-asana-$NAME"; RC="$NAME"; else S="claude-asana-chat-$NAME"; RC="chat-$NAME"; fi
tmux has-session -t "$S" 2>/dev/null && { echo "session already exists: $S (kill it first or pick another --name)" >&2; exit 1; }

cmd="claude"
[ -n "$MODEL" ] && cmd="$cmd --model $MODEL"
[ -n "$EFFORT" ] && cmd="$cmd --effort $EFFORT"
$CHROME && cmd="$cmd --chrome"
cmd="$cmd --dangerously-skip-permissions --remote-control $RC"

# Transcripts land under the project dir derived from cwd; note the newest
# BEFORE spawning so the new one can be identified afterwards.
enc=$(printf '%s' "$CWD" | sed 's#/#-#g')
pdir="$HOME/.claude/projects/$enc"
before=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1 || true)

tmux new-session -d -s "$S" -c "$CWD"
tmux send-keys -t "$S" C-u
tmux send-keys -t "$S" "$cmd" Enter
ready=""
for _ in $(seq 1 30); do
  sleep 2
  if tmux capture-pane -p -t "$S" | grep -q -E 'bypass permissions on'; then ready=1; break; fi
done
[ -n "$ready" ] || { echo "claude did not reach its prompt in 60s; pane tail:" >&2; tmux capture-pane -p -t "$S" | grep -v '^\s*$' | tail -6 >&2; exit 1; }
sleep 3   # let the TUI finish attaching its input handler before any paste

pointer="Read $BRIEF and execute it exactly; it is your full brief."
[ -n "$POINTER" ] && pointer="$pointer $POINTER"
if [ "${#pointer}" -gt 300 ]; then echo "pointer too long (${#pointer} > 300); shorten --pointer" >&2; tmux kill-session -t "$S"; exit 1; fi
tmux send-keys -t "$S" C-u
printf '%s' "$pointer" | tmux load-buffer -b "spawn-$NAME" -
tmux paste-buffer -b "spawn-$NAME" -d -t "$S"
sleep 1
tmux send-keys -t "$S" Enter

# Verify: the newest transcript in the project dir should be new and its first
# human message should equal the pointer.
ok=""
for _ in $(seq 1 20); do
  sleep 2
  newest=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1 || true)
  [ -n "$newest" ] && [ "$newest" != "$before" ] || continue
  first=$(python3 - "$newest" <<'EOF'
import json,sys
for line in open(sys.argv[1], errors='ignore'):
    try: o=json.loads(line)
    except: continue
    if o.get('type')!='user': continue
    c=o.get('message',{}).get('content')
    txt = c if isinstance(c,str) else ' '.join(x.get('text','') for x in c if isinstance(x,dict) and x.get('type')=='text')
    if not txt or txt.startswith('<') or 'tool_result' in str(c)[:30]: continue
    print(txt); break
EOF
)
  [ -n "$first" ] || continue
  if [ "$first" = "$pointer" ]; then ok=1; break; fi
  echo "pointer arrived altered (len ${#first} vs ${#pointer}); session left running: $S" >&2
  echo "  got: ${first:0:160}" >&2
  exit 3
done
[ -n "$ok" ] || { echo "could not confirm the pointer in a transcript within 40s; session running: $S" >&2; exit 3; }
echo "SPAWNED tmux=$S rc=$RC transcript=$(basename "$newest") brief=$BRIEF"
exit 0
