#!/usr/bin/env bash
# resolve-run.sh — resolve orchestrated agent run(s) into a compact JSON evidence manifest.
#
# Modes:
#   --since <ISO-date>   discover runs spawned at/after date (watcher log + worktrees), resolve each
#   --gid <task-gid>     resolve a single run
#   --list               with --since: print gid + name + spawned_at only (no deep resolution)
#
# Output: JSON array of manifests on stdout (the ONLY stdout). Diagnostics on stderr.
# Exit: 0 = ok (possibly empty array), 1 = error, 2 = usage.
#
# Read-only: never mutates Asana, tmux, slots, pool, or worktrees.
# Never prints credential VALUES; reads token only to query Asana.

set -euo pipefail

WATCHER_LOG="/tmp/asana-watcher.out"
WATCHDOG_LOG="/tmp/session-watchdog.out"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
WORKTREES_ROOT="$HOME/git/.agent-worktrees"
PROJECTS_DIR="$HOME/.claude/projects"
CONFIG="$HOME/.config/agent-watcher/asana-config.json"
CRED="$HOME/.config/agent-watcher/credentials.json"

GID="" SINCE="" LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gid) GID="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *) echo "usage: resolve-run.sh (--gid <gid> | --since <ISO-date>) [--list]" >&2; exit 2 ;;
  esac
done
[ -n "$GID" ] || [ -n "$SINCE" ] || { echo "usage: resolve-run.sh (--gid <gid> | --since <ISO-date>) [--list]" >&2; exit 2; }

command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }

# ---- discovery: gid<TAB>name<TAB>spawned_at from watcher log, plus worktree-dir fallback ----
discover() {
  local since="$1"
  {
    if [ -r "$WATCHER_LOG" ]; then
      # [2026-06-10T00:43:37.043Z] Spawning slot for: NAME (gid=GID, cwd=...)
      sed -n 's/^\[\([^]]*\)\] Spawning slot for: \(.*\) (gid=\([0-9]*\),.*$/\3\t\2\t\1/p' "$WATCHER_LOG" |
        awk -F'\t' -v s="$since" '$3 >= s'
    fi
    # worktree dirs whose mtime is in range (covers runs missing from a rotated log)
    if [ -d "$WORKTREES_ROOT" ]; then
      local cutoff_epoch; cutoff_epoch=$(node -e "process.stdout.write(String(Math.floor(new Date(process.argv[1]).getTime()/1000)))" "$since" 2>/dev/null || echo 0)
      for d in "$WORKTREES_ROOT"/*/; do
        local g; g=$(basename "$d")
        case "$g" in (*[!0-9]*) continue ;; esac
        local m; m=$(stat -f %m "$d" 2>/dev/null || echo 0)
        if [ "$m" -ge "$cutoff_epoch" ]; then printf '%s\t%s\t%s\n' "$g" "" ""; fi
      done
    fi
  } | sort -t$'\t' -k1,1 -u -s | awk -F'\t' '!seen[$1]++'
}

# ---- per-gid resolution ----
asana_fetch() { # $1=gid → JSON {name,status,blocked} (or status=__MISSING__ / __NO_AUTH__)
  local gid="$1" token
  token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)}"
  [ -n "$token" ] || { echo '{"name":null,"status":"__NO_AUTH__","blocked":null}'; return 0; }
  local resp; resp=$(curl -sf --max-time 20 "https://app.asana.com/api/1.0/tasks/$gid?opt_fields=name,custom_fields.name,custom_fields.gid,custom_fields.display_value" \
    -H "Authorization: Bearer $token" 2>/dev/null) || { echo '{"name":null,"status":"__MISSING__","blocked":null}'; return 0; }
  local ag_gid bl_gid
  ag_gid=$(jq -r '.custom_fields.agent_status.field_gid // .custom_fields.agent_status.gid // empty' "$CONFIG" 2>/dev/null)
  bl_gid=$(jq -r '.custom_fields.blocked.field_gid // .custom_fields.blocked.gid // empty' "$CONFIG" 2>/dev/null)
  echo "$resp" | jq -c --arg ag "$ag_gid" --arg bl "$bl_gid" '{
    name: .data.name,
    status: (first(.data.custom_fields[]? | select((.gid == $ag) or ((.name // "") | ascii_downcase | test("agent.?status"))) | .display_value) // null),
    blocked: (first(.data.custom_fields[]? | select((.gid == $bl) or ((.name // "") | ascii_downcase == "blocked")) | .display_value) // null)
  }'
}

# Followup-scope evidence. The agent attaches an `agent-run-report*.md` at each Complete;
# that attachment's created_at is the "agent reported done here" WATERMARK. Any operator
# comment newer than the PRIOR report is scope THIS run was responsible for — the eval
# checks its work was DELIVERED (a PR shipped, on the parent or a per-repo subtask) before
# Complete (catches the silent descope where a followup comment's asks are deferred to a
# false Complete). Subtasks are unwatched PR/context holders, not separate runs; the list
# is captured as evidence (which extra-repo PRs were attached), not as proof of discharge.
asana_followup() { # $1=gid → {last_report_attached_at, prev_report_attached_at, comments_after_prev_report:[...], subtasks:[...]}
  local gid="$1" token
  token="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)}"
  local empty='{"last_report_attached_at":null,"prev_report_attached_at":null,"comments_after_prev_report":[],"subtasks":[]}'
  [ -n "$token" ] || { echo "$empty"; return 0; }
  local att sto sub reports last prev
  att=$(curl -sf --max-time 20 "https://app.asana.com/api/1.0/tasks/$gid/attachments?opt_fields=name,created_at" -H "Authorization: Bearer $token" 2>/dev/null || echo '{"data":[]}')
  sto=$(curl -sf --max-time 20 "https://app.asana.com/api/1.0/tasks/$gid/stories?opt_fields=resource_subtype,created_at,text" -H "Authorization: Bearer $token" 2>/dev/null || echo '{"data":[]}')
  sub=$(curl -sf --max-time 20 "https://app.asana.com/api/1.0/tasks/$gid/subtasks?opt_fields=name,completed,created_at" -H "Authorization: Bearer $token" 2>/dev/null || echo '{"data":[]}')
  # ISO8601-UTC created_at strings sort lexicographically, so no date parsing needed.
  reports=$(echo "$att" | jq -c '[.data[]? | select((.name // "") | test("agent-run-report")) | .created_at] | sort | reverse' 2>/dev/null || echo '[]')
  last=$(echo "$reports" | jq -r '.[0] // empty' 2>/dev/null || echo "")
  prev=$(echo "$reports" | jq -r '.[1] // empty' 2>/dev/null || echo "")
  echo "$sto" "$sub" | jq -cs --arg prev "$prev" --arg last "$last" '
    .[0] as $s | .[1] as $t |
    { last_report_attached_at: (if $last=="" then null else $last end),
      prev_report_attached_at: (if $prev=="" then null else $prev end),
      comments_after_prev_report: ( [ $s.data[]?
        | select(.resource_subtype=="comment_added")
        | select(($prev=="") or (.created_at > $prev))
        | {created_at, text: ((.text // "")[0:500])} ] | .[-20:] ),
      subtasks: [ $t.data[]? | {gid, name, completed, created_at} ] }' 2>/dev/null || echo "$empty"
}

find_transcript() { # $1=gid → newest RUN jsonl whose FIRST asana URL gid equals the target
  # (mirrors resume-task.sh's first-URL semantics: a later MENTION of the gid in
  #  another session must not match — six runs once resolved to one shared
  #  interactive transcript)
  #
  # RUN SIGNATURE required: the head must carry an actual `/one-shot --yolo` USER
  # message (JSON string starting with it). Fresh spawns open with it; watcher
  # resumes receive it right after the resume summary. `resume-agent --chat`
  # DISCUSSION FORKS inherit the run's first URL but never receive a /one-shot,
  # so without this gate an active chat (newest mtime) would be graded as the
  # run: friction/probe counts from the discussion, chat messages counted as
  # operator nudges, eval window misaligned.
  local gid="$1" best="" best_m=0 f m first_url
  for f in "$PROJECTS_DIR"/*"$gid"*/*.jsonl "$PROJECTS_DIR"/*git*/*.jsonl; do
    [ -r "$f" ] || continue
    first_url=$(head -c 16384 "$f" | grep -oE 'app\.asana\.com[A-Za-z0-9/._-]*' | head -1 || true)
    [ -n "$first_url" ] || continue
    # the task gid is the LAST long numeric segment of the URL (handles /0/<proj>/<task> and /f suffix)
    echo "$first_url" | grep -oE '[0-9]{12,}' | tail -1 | grep -qx "$gid" || continue
    # run signature; excludes resume-agent --chat discussion forks. Line-based head
    # (the resume-summary record is one huge line, so a byte-based head truncates
    # before the /one-shot message). Captured to a var first: `head | grep -q`
    # under pipefail returns 141 on a MATCH (grep -q quits, head SIGPIPEs), which
    # `|| continue` would misread as no-match, skipping every genuine run.
    # herestring, NOT a pipe: `printf | grep -q` under pipefail returns 141 on a
    # match past the pipe buffer (grep quits, printf SIGPIPEs), misread as no-match.
    # -a: BSD grep binary-detects transcript heads and silently misses without it.
    sig_head=$(head -50 "$f" 2>/dev/null || true)
    grep -qa '"/one-shot --yolo' <<<"$sig_head" || continue
    m=$(stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$m" -gt "$best_m" ]; then best="$f"; best_m=$m; fi
  done
  echo "$best"
}

resolve_one() { # $1=gid $2=name-hint $3=spawned-hint → one manifest JSON on stdout
  local gid="$1" name_hint="$2" spawned="$3"

  local session_state="gone" tmux_session=""
  if tmux has-session -t "claude-asana-$gid" 2>/dev/null; then session_state="live"; tmux_session="claude-asana-$gid"
  elif tmux has-session -t "done-asana-$gid" 2>/dev/null; then session_state="retired"; tmux_session="done-asana-$gid"; fi

  local worktree="" repo="" branch=""
  if [ -d "$WORKTREES_ROOT/$gid" ]; then
    worktree=$(find "$WORKTREES_ROOT/$gid" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
    [ -n "$worktree" ] && repo=$(basename "$worktree") && branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  local transcript; transcript=$(find_transcript "$gid")
  local win_start="" win_end="" prs="[]" revive_pings=0 operator_msgs=0 probe_index="{}"
  if [ -n "$transcript" ]; then
    # first/last lines are often timestamp-less meta records (mode, bridge-session);
    # take the first and last lines that carry a timestamp
    win_start=$(grep -m1 -o '"timestamp":"[^"]*"' "$transcript" 2>/dev/null | cut -d'"' -f4 || true)
    win_end=$(tail -300 "$transcript" | grep -o '"timestamp":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)
    prs=$(grep -oE 'https://github\.com/[A-Za-z0-9._/-]+/pull/[0-9]+' "$transcript" 2>/dev/null | grep -viE 'github\.com/(owner/repo|org/repo|example)' | sort -u | head -5 | jq -R . | jq -cs . || true)
    [ -n "$prs" ] || prs="[]"
    # actual watchdog pings arrive as a user message whose content STARTS with the marker;
    # the marker also appears mid-sentence in one-shot SKILL.md rule text read into the
    # transcript — that must not count, so anchor on the JSON key boundary
    revive_pings=$(grep -cE '"(content|text)":"<watchdog-revive-ping>' "$transcript" 2>/dev/null || true)
    revive_pings=${revive_pings:-0}
    # mid-run human nudges: ANY human-authored message counts — the "Operator:"
    # prefix is a courtesy convention, not required. Two delivery shapes exist
    # in the transcript (validated 2026-06-12):
    #   1. idle-composer sends → user records whose text STARTS with a
    #      "<system-reminder>Message sent at ..." stamp followed by the text
    #   2. mid-turn sends → queue-operation records; "dequeue" = delivered
    #      ("enqueue"/"remove" churn is composer editing, not delivery)
    # Harness artifacts (tool results, slash-command spawn, skill bodies,
    # revive pings, task notifications) carry no sent-at stamp and don't count.
    operator_msgs=$(node -e '
      const fs = require("fs"); const rl = require("readline");
      (async () => {
        let n = 0;
        const r = rl.createInterface({ input: fs.createReadStream(process.argv[1]), crlfDelay: Infinity });
        for await (const line of r) {
          let j; try { j = JSON.parse(line) } catch { continue }
          if (j.type === "queue-operation" && j.operation === "dequeue") { n++; continue }
          if (j.type !== "user" || !j.message) continue;
          const c = j.message.content;
          const texts = typeof c === "string" ? [c] : (Array.isArray(c) ? c.filter(b => b && b.type === "text").map(b => b.text || "") : []);
          let t = texts.join("\n").trim();
          if (!/^<system-reminder>Message sent at /.test(t)) continue;
          t = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim();
          if (t) n++;
        }
        console.log(n);
      })().catch(() => console.log(0));
    ' "$transcript" 2>/dev/null || echo 0)
    operator_msgs=${operator_msgs:-0}
    # Deterministic probe index: ONE pass over the transcript pre-computes the
    # standard evidence probes both evaluators otherwise re-derive with ad-hoc
    # greps (counts + sample line numbers, and the update-status ladder for A4/O8).
    # Counts are ADVISORY (skill bodies quoted into the transcript can inflate
    # them) — evaluators verify hits at the given lines instead of re-discovering.
    probe_index=$(node -e '
      const fs = require("fs"); const rl = require("readline");
      const PROBES = {
        lint_commit: /lint-commit\.sh/,
        raw_git_commit: /git (commit|-C [^ ]+ commit)/,
        amend: /commit --amend/,
        self_respawn: /ScheduleWakeup|CronCreate|claude --resume|claude &|\/loop /,
        pr_create: /gh pr create|\/pr-create/,
        pr_land: /pr-land/,
        watch_pr: /watch-pr\.sh/,
        build_and_test: /build-and-test/,
        set_tested: /set-tested\.sh/,
        log_attempt: /log-attempt\.sh/,
        maestro: /maestro/,
        skill_reads: /skills\/[a-z-]+\/SKILL\.md/,
        tool_errors: /"is_error":\s*true/,
      };
      const STATUS = /update-status\.sh ([0-9]+) (Pending|Planning|Developing|Testing|Reviewing|Complete)/;
      // Friction: how hard the run had to grind, not whether it got there (the
      // outcome dimensions grade that). Collected mechanically so the eval and
      // the scorecard read the same numbers. Counts share the probe caveat:
      // skill text quoted into the transcript inflates them; graders confirm.
      const HOOK_BLOCK = /PreToolUse:\w+ hook error: \[[^\]]*\/([a-z0-9-]+\.sh)\]/;
      const BUILD = /ios-rn-build\.sh/;
      const MAESTRO_CALL = /"name":"mcp__maestro__run"/;
      const TS = /"timestamp":"([^"]+)"/;
      (async () => {
        const out = {}; for (const k of Object.keys(PROBES)) out[k] = { count: 0, lines: [] };
        out.update_status = { count: 0, ladder: [] };
        const fr = { hook_blocks: { total: 0, by_hook: {} }, tool_errors: 0, build_invocations: 0,
                     maestro_run_calls: 0, first_testing_ts: null, first_maestro_run_ts: null,
                     first_hook_block_ts: null, compact_boundaries: 0 };
        let n = 0;
        const r = rl.createInterface({ input: fs.createReadStream(process.argv[1]), crlfDelay: Infinity });
        for await (const line of r) {
          n++;
          for (const [k, re] of Object.entries(PROBES)) {
            if (re.test(line)) { out[k].count++; if (out[k].lines.length < 5) out[k].lines.push(n); }
          }
          const m = line.match(STATUS);
          if (m) {
            out.update_status.count++;
            if (out.update_status.ladder.length < 20) out.update_status.ladder.push({ line: n, status: m[2] });
            if (m[2] === "Testing" && !fr.first_testing_ts) fr.first_testing_ts = (line.match(TS) || [])[1] || null;
          }
          const hb = line.match(HOOK_BLOCK);
          if (hb) {
            fr.hook_blocks.total++;
            fr.hook_blocks.by_hook[hb[1]] = (fr.hook_blocks.by_hook[hb[1]] || 0) + 1;
            if (!fr.first_hook_block_ts) fr.first_hook_block_ts = (line.match(TS) || [])[1] || null;
          }
          if (/"is_error":\s*true/.test(line)) fr.tool_errors++;
          if (BUILD.test(line)) fr.build_invocations++;
          if (MAESTRO_CALL.test(line)) {
            fr.maestro_run_calls++;
            if (!fr.first_maestro_run_ts) fr.first_maestro_run_ts = (line.match(TS) || [])[1] || null;
          }
          if (/"subtype":"compact_boundary"/.test(line)) fr.compact_boundaries++;
        }
        out.friction = fr;
        console.log(JSON.stringify(out));
      })().catch(() => console.log("{}"));
    ' "$transcript" 2>/dev/null || echo "{}")
    [ -n "$probe_index" ] || probe_index="{}"
  fi

  local asana; asana=$(asana_fetch "$gid" || true)
  [ -n "$asana" ] || asana='{"name":null,"status":null,"blocked":null}'
  local followup; followup=$(asana_followup "$gid" || true)
  [ -n "$followup" ] || followup='{"last_report_attached_at":null,"prev_report_attached_at":null,"comments_after_prev_report":[],"subtasks":[]}'

  local slot
  slot=$(node "$HOME/.config/agent-watcher/lib/slots.js" get --task-gid "$gid" 2>/dev/null | jq -c . 2>/dev/null || true)
  [ -n "$slot" ] || slot="null"
  local pool_entry="null"
  if [ -r "$STATE_DIR/pool.json" ]; then
    pool_entry=$(jq -c --arg g "$gid" '[.[] | select(.task_gid == $g)] | first // null' "$STATE_DIR/pool.json" 2>/dev/null || true)
    [ -n "$pool_entry" ] || pool_entry="null"
  fi

  local watchdog_mentions=0
  if [ -r "$WATCHDOG_LOG" ]; then
    watchdog_mentions=$(grep -c "$gid" "$WATCHDOG_LOG" 2>/dev/null || true)
    watchdog_mentions=${watchdog_mentions:-0}
  fi
  local forensics="[]"
  if [ -d "$STATE_DIR/forensics" ]; then
    forensics=$(find "$STATE_DIR/forensics" -type f -name "*.txt" 2>/dev/null | head -5 | jq -R . | jq -cs . || true)
    [ -n "$forensics" ] || forensics="[]"
  fi

  local run_report=""
  run_report=$(find "$WORKTREES_ROOT/$gid" /tmp -maxdepth 3 \( -iname "*run-report*" -o -iname "*report*$gid*" \) -type f 2>/dev/null | head -1 || true)
  [ -z "$run_report" ] && run_report="asana-attachment"

  # durable release receipt written by the watchdog at retirement (O1/O6 evidence).
  # If the gid is LIVE again (re-fired for a followup), any receipt on disk is the
  # PRIOR incarnation's retirement — surfacing it would let a consumer mis-grade O6
  # as a clean release of the CURRENT run. Null it out when live, with a flag so the
  # eval knows a prior receipt exists but does not apply to this run.
  local release_receipt="null"
  if [ "$session_state" = "live" ]; then
    [ -r "$STATE_DIR/releases/$gid.json" ] && release_receipt='{"stale_prior_incarnation":true,"note":"gid is live again; prior retirement receipt suppressed"}'
  elif [ -r "$STATE_DIR/releases/$gid.json" ]; then
    release_receipt=$(jq -c . "$STATE_DIR/releases/$gid.json" 2>/dev/null || true)
    [ -n "$release_receipt" ] || release_receipt="null"
  fi

  # Concession-decision evidence: the attempt-log (authoritative record of value-moving
  # actions / test-drives, written by log-attempt.sh — agent-location-independent, so
  # it holds the attempt even when a separate tester subagent performed it), plus the
  # last blocker reason + the concession-validator verdict. The verdict file is shared by
  # BOTH concession kinds and carries `kind: block|downgrade`, so a downgrade-finalize
  # (Complete/pr-create without reaching in-app success) surfaces here too even though it
  # set no formal block (last_reason stays null; the verdict's reason_hash is the binding).
  # The eval grades A7 (premature yield) and the concession-gating O-dimension against
  # these instead of transcript prose.
  local attempt_log="[]"
  if [ -r "$STATE_DIR/attempts/$gid.jsonl" ]; then
    attempt_log=$(jq -cs . "$STATE_DIR/attempts/$gid.jsonl" 2>/dev/null || echo "[]")
    [ -n "$attempt_log" ] || attempt_log="[]"
  fi
  # Orch-version stamps: one line per spawn/resume segment (stamp-orch-version.sh).
  # Lets evals slice findings by the orch version actually in force per segment, and
  # makes "run predates rule X" determinations mechanical via repo_head.
  local versions="[]"
  if [ -r "$STATE_DIR/versions/$gid.jsonl" ]; then
    versions=$(jq -cs . "$STATE_DIR/versions/$gid.jsonl" 2>/dev/null || echo "[]")
    [ -n "$versions" ] || versions="[]"
  fi
  local blocker_reason="null"
  [ -r "/tmp/agent-concession-reason-$gid.txt" ] && blocker_reason=$(jq -Rs . "/tmp/agent-concession-reason-$gid.txt" 2>/dev/null || echo null)
  local blocker_verdict="null"
  [ -r "/tmp/agent-concession-verdict-$gid.json" ] && blocker_verdict=$(jq -c . "/tmp/agent-concession-verdict-$gid.json" 2>/dev/null || echo null)

  jq -cn \
    --arg gid "$gid" --arg name_hint "$name_hint" --arg spawned "$spawned" \
    --arg session_state "$session_state" --arg tmux_session "$tmux_session" \
    --arg transcript "$transcript" --arg ws "$win_start" --arg we "$win_end" \
    --arg worktree "$worktree" --arg repo "$repo" --arg branch "$branch" \
    --argjson prs "$prs" --argjson asana "$asana" --argjson slot "$slot" --argjson pool "$pool_entry" \
    --arg run_report "$run_report" --argjson revive "$revive_pings" --argjson operator "$operator_msgs" --argjson wd "$watchdog_mentions" \
    --argjson release_receipt "$release_receipt" \
    --argjson attempt_log "$attempt_log" --argjson blocker_reason "$blocker_reason" --argjson blocker_verdict "$blocker_verdict" \
    --argjson followup "$followup" --argjson probe_index "$probe_index" \
    --argjson versions "$versions" \
    --argjson forensics "$forensics" --arg state_dir "$STATE_DIR" --arg watchdog_log "$WATCHDOG_LOG" --arg watcher_log "$WATCHER_LOG" \
    --argjson runaway_log_exists "$([ -f "$STATE_DIR/runaway-guard.log" ] && echo true || echo false)" \
    '{
      gid: $gid,
      task_name: ($asana.name // (if $name_hint == "" then null else $name_hint end)),
      spawned_at: (if $spawned == "" then null else $spawned end),
      asana: { status: $asana.status, blocked: $asana.blocked },
      in_flight: (($asana.status != null) and ($asana.status != "Complete") and ($asana.status != "Archived") and ($asana.blocked != "Yes") and ($session_state == "live")),
      session: { state: $session_state, tmux: (if $tmux_session == "" then null else $tmux_session end) },
      transcript: (if $transcript == "" then null else $transcript end),
      window: { start: (if $ws == "" then null else $ws end), end: (if $we == "" then null else $we end) },
      worktree: (if $worktree == "" then null else $worktree end),
      repo: (if $repo == "" then null else $repo end),
      branch: (if $branch == "" then null else $branch end),
      prs: $prs,
      slot: $slot,
      pool_entry: $pool,
      run_report: $run_report,
      release_receipt: $release_receipt,
      blocking: { attempt_log: $attempt_log, last_reason: $blocker_reason, validator_verdict: $blocker_verdict },
      followup: $followup,
      versions: $versions,
      friction: ($probe_index.friction // {}),
      probe_index: ($probe_index | del(.friction)),
      auto_na: ( {}
        + (if ($prs | length) == 0 then {A13: "no PR created this run", A14: "no PR, so no review threads to address"} else {} end)
        + (if (($probe_index.pr_land.count // 0) == 0) then {A15: "pr-land never invoked"} else {} end)
        + (if $followup.last_report_attached_at == null
           then {A23: "not a followup (no prior run-report attached)", A24: "not a re-engagement (no prior run-report attached)"}
           else (if ($followup.comments_after_prev_report | length) == 0 then {A23: "no operator comments after the prior report"} else {} end)
           end)
        + (if ($blocker_verdict == null and $blocker_reason == null and ($asana.blocked != "Yes")) then {O7: "never blocked (no reason file, no verdict, blocked field != Yes)"} else {} end)
      ),
      signals: { revive_pings_in_transcript: $revive, operator_messages: $operator, watchdog_log_mentions: $wd, forensics_files: $forensics },
      logs: { watcher: $watcher_log, watchdog: $watchdog_log,
              runaway_guard: ($state_dir + "/runaway-guard.log"),
              runaway_log_exists: $runaway_log_exists,
              memory_monitor: "/tmp/memory-monitor.log",
              mem_trace_dir: ($state_dir + "/oom-repro/logs"),
              forensics_dir: ($state_dir + "/forensics") }
    }'
}

# ---- main ----
if [ -n "$GID" ]; then
  resolve_one "$GID" "" "" | jq -cs .
  exit 0
fi

rows=$(discover "$SINCE")
if [ "$LIST" -eq 1 ]; then
  echo "$rows" | jq -Rn '[inputs | select(length > 0) | split("\t") | {gid: .[0], name: (.[1] // ""), spawned_at: (.[2] // "")}]'
  exit 0
fi

out="["; first=1
while IFS=$'\t' read -r g n s; do
  [ -n "$g" ] || continue
  echo "resolving $g (${n:-?})" >&2
  m=$(resolve_one "$g" "$n" "$s") || { echo "WARN: failed to resolve $g" >&2; continue; }
  [ $first -eq 1 ] && first=0 || out="$out,"
  out="$out$m"
done <<< "$rows"
out="$out]"
echo "$out" | jq -c .
