---
name: resume-session
description: Find and resume the RIGHT past claude session (orch run, chat fork, or interactive) and hand it to the operator remote-controlled. Use when the user says "resume my X session", "talk to the session that did X", "find the session where <phrase>", or a resume/reattach attempt grabbed the wrong session. NOT for re-running orch task work (that is agent_status=Pending → the watcher).
compatibility: Requires tmux, node, jq. ASANA_TOKEN/credentials.json for task names.
metadata:
  author: j0ntz
---

<goal>Resolve a fuzzy session reference ("my nym mixfetch session", "the one where I drafted the letter") to exactly one session across the four identity spaces (Asana task, transcript uuid, tmux name, RC name), resume it in the mode its kind requires, verify it is the right one, and tell the operator what to look for in their session list.</goal>

<rules description="Non-negotiable constraints.">
<rule id="scripts-do-the-mechanics">`~/.config/agent-watcher/session-index.sh` owns inventory and content search; `~/.config/agent-watcher/resume-agent.sh` owns the resume execution. Do not hand-roll transcript greps, tmux spawns, or `claude --resume` invocations.</rule>
<rule id="live-first">ALWAYS check the live inventory before touching transcripts. If a live session already answers the request, the deliverable is its name (tmux + RC), not a resume — resuming a transcript that is live in another pane creates a divergent duplicate.</rule>
<rule id="mode-follows-kind">The resume mode is determined by the matched transcript's kind, never by habit: LIVE → point at it. Dead CHAT fork → `--uuid <id> --chat --in-place` (continue it; forking a fork re-duplicates history and pollutes future search). RUN or INTERACTIVE transcript → `--uuid <id> --chat` (fork; the original stays pristine for evals and watcher resumes). NEVER plain-resume a RUN transcript for discussion — that mutates the run's conversation.</rule>
<rule id="echo-aware-search">Content search runs through `session-index.sh --grep`, and its classification is binding: hits marked `inherited_from` are fork copies of the parent's text — prefer the parent. `authored` hits in OTHER sessions can still be quotes (an operator pasting the phrase into a different chat), so authored-count alone never decides: cross-check task identity and kind, and when more than one plausible original remains, ask.</rule>
<rule id="never-newest-guess">Ambiguity is resolved by ASKING with a table (uuid, kind, task, mtime, live name), never by silently taking the newest mtime. The newest transcript is frequently a fork or an unrelated echo.</rule>
<rule id="verify-before-handoff">After the session boots, CONFIRM it is the right one before reporting success: grep the resumed transcript (or for --in-place, the same uuid) for the user's anchor (the quoted phrase, or the task name/gid) and check the pane booted without "No conversation found". A failed check is a STOP-and-report, not a shrug — kill the wrong spawn before trying the next candidate.</rule>
<rule id="orch-boundary">This skill NEVER re-engages orch task WORK. New scope on a finished task goes through `agent_status=Pending` → the watcher (one-shot `followup-reopens-status`). If the user's real intent is a followup run, say so and offer to arm Pending instead. Chat sessions must not do deliverable work; insights that should drive a run belong in an Asana comment before the bounce.</rule>
<rule id="session-hygiene-facts">Sessions this skill creates are `claude-asana-chat-<slug>` / RC `chat-<slug>`: watchdog RC-revived, exempt from the completion sweep, reaped after 48h idle (transcript survives; resurrection is this same skill). Tell the user the RC name to look for, every time.</rule>
</rules>

<step id="1" name="Parse the reference">
Classify the user's reference (combinable):
1. Task-ish: task name words, an Asana URL, or a bare gid → identity search.
2. Content-ish: a quoted phrase / "the one where ..." → content search.
3. Exact: a transcript uuid or tmux/RC name → direct.
If the reference implies WORK on a task (fix, continue implementing, address review), stop and apply `orch-boundary`.
</step>

<step id="2" name="Inventory">
ONE call (add `--grep` only for content references; quote the phrase exactly):

```bash
~/.config/agent-watcher/session-index.sh [--grep "<phrase>"]
```

Read `live` first (per `live-first`): match the reference against tmux names, RC names, and the task gid/name of each live session's `resume_uuid` transcript. Then match `transcripts` by task_gid/task_name (identity) or `grep` results (content, per `echo-aware-search`).
</step>

<step id="3" name="Decide">
Priority order:
1. Exactly one LIVE match → report its RC name + tmux name; done (no resume).
2. Exactly one dead match → resume per `mode-follows-kind`.
3. Multiple matches for DIFFERENT underlying conversations → present the table, ask (per `never-newest-guess`). A run and its registered fork chain count as ONE conversation: prefer the chat fork for "continue our discussion" intents, the run for "what did the run do" intents; say which you picked and why.
4. Zero matches → report what was searched and the nearest misses; do not spawn anything.
</step>

<step id="4" name="Execute">
```bash
cd ~/git && ~/.config/agent-watcher/resume-agent.sh --uuid <uuid> --chat [--in-place]
```

`--in-place` per `mode-follows-kind` (dead chat forks only). Use `--summary` only if the user explicitly wants a cheap skim, never by default. On "already exists", that IS the answer — report the existing names.
</step>

<step id="5" name="Verify and report">
Per `verify-before-handoff`: confirm boot + anchor. Then report, bulleted: the RC name to find in the session list, what the session is (kind, task, last activity date), which mode was used (continued vs forked), and the 48h-reap note when a new chat session was created.
</step>

<edge-cases>
<case name="Reference matches this session or a desktop session">Desktop/interactive transcripts are indexed and can be forked (`--uuid --chat`), but flag it: the user may just mean the app conversation they already have open.</case>
<case name="Anchor phrase only in pre-registry forks">Historical forks (before the lineage registry) classify as `interactive` and their copies look authored. If two transcripts share large authored counts and sizes, suspect an unregistered fork: prefer the one with the `/one-shot` run signature or the older birth time, and say the lineage is uncertain.</case>
<case name="The matched run's task is live again (watcher respawned it)">Do not fork a transcript whose conversation is actively being driven by the orch (`live` shows claude-asana-<gid>). Point the user at the live run session, or wait.</case>
<case name="User wants the chat killed">`tmux kill-session -t claude-asana-chat-<slug>`; the transcript survives. Mention resurrection is one invocation away.</case>
</edge-cases>
