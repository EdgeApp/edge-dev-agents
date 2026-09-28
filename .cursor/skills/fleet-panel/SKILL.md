---
name: fleet-panel
description: Own the Fleet artifact (the mobile session-tui with a Resume button). Use in the dedicated `fleet` anchor session on eddy: publish the page once, then on every `fleet-request` comment the page sends to Claude read the page, hand its state and the request to fleet-panel.sh, republish the result, and resolve the thread. Not for other sessions.
metadata:
  author: j0ntz
---

<goal>Keep the Fleet artifact current and execute the resume requests viewers queue on it, doing only the things that need the Artifact tool (read, publish, watch, reply, resolve) and leaving every decision and execution to `~/.config/agent-watcher/fleet-panel.sh`.</goal>

<rules description="Non-negotiable constraints.">
<rule id="script-executes">Never resume, spawn, kill or rename a session yourself. `fleet-panel.sh apply` is the only thing that acts on a request; it validates each uuid against the list the page itself published and runs `resume-agent.sh --uuid <id> --chat`. If a request looks wrong, the script records it as `error`; you do not work around it.</rule>
<rule id="comment-is-the-wake">A tap reaches you ONLY as an `[Artifact comment sent to Claude]` turn whose text starts `fleet-request {...}`. A page republish never starts a turn, so there is no "artifact changed" wake to wait for. The comment path works only while the watch's `status` row says auto-replies armed; when it does not, run step 3.</rule>
<rule id="read-before-publish">Every publish is preceded by an Artifact read of the live page in the same turn. The read carries requests the comment did not (earlier taps); a publish without it overwrites them.</rule>
<rule id="publish-by-url">Publish with `url` set to the value in `~/.config/agent-watcher/fleet-panel.json`, never by file path alone: this session may be a resume of the original publisher, and only the url form is guaranteed to update the same artifact.</rule>
<rule id="declare-both-capabilities">Every publish passes `capabilities: {"artifact": {}, "comments": {}}`. The page's taps need both; a publish that omits `comments` leaves Resume and Refresh unable to wake you.</rule>
<rule id="all-pending">Process everything `apply` reports, not one request. Several comments can arrive in one turn; pass each one's request (step 2) and apply once per request file.</rule>
<rule id="quiet">One wake is one turn: read, apply, publish, reply, resolve, one line of output naming what was applied. No other commentary, no Asana writes, no commits.</rule>
<rule id="conflict-means-reread">A publish rejected as conflict means a viewer published between your read and your publish. Re-read, re-apply, publish again, once. Never force.</rule>
</rules>

<step id="1" name="Init (once per artifact)">
Only when `~/.config/agent-watcher/fleet-panel.json` does not exist:

1. `~/.config/agent-watcher/fleet-panel.sh render --out /tmp/fleet-page.html`
2. Publish `/tmp/fleet-page.html` with the Artifact tool: icon `satellite`, `capabilities: {"artifact": {}, "comments": {}}`, `contract: "latest"`, description "Live sessions and resumable transcripts on eddy; tap Resume to bring a transcript back as a remote-control chat session."
3. Write `{"url": "<published url>"}` to `~/.config/agent-watcher/fleet-panel.json` (Write tool).
4. Run step 3.
</step>

<step id="2" name="Sync (every fleet-request comment, or when asked to sync)">
1. For each `fleet-request {...}` comment in the turn, write the JSON after `fleet-request ` to `/tmp/fleet-request-<n>.json` (Write tool), and note its thread id. An operator's "sync" has no comment: skip this sub-step.
2. Artifact `read` with the url from fleet-panel.json. Write the page's `<script type="application/json" id="state">` JSON to `/tmp/fleet-incoming.json` (Write tool). When the read named a file, use `~/.config/agent-watcher/fleet-panel.sh extract-state <file> > /tmp/fleet-incoming.json` instead.
3. Run, once per request file (or once with no `--request-file` when there is none):
   `~/.config/agent-watcher/fleet-panel.sh apply /tmp/fleet-incoming.json --request-file /tmp/fleet-request-<n>.json --out /tmp/fleet-page.html`
   Allow up to 5 minutes: a resume waits for claude to boot. It prints `APPLIED <id> <status> [<rc>]` lines and `RENDERED /tmp/fleet-page.html`. Exit 1 with `request file: bad id` means the comment was not a page tap; reply saying so and resolve.
4. Publish `/tmp/fleet-page.html` with `url` from fleet-panel.json and `capabilities: {"artifact": {}, "comments": {}}`.
5. For each thread from sub-step 1: Artifact `reply` with its APPLIED line, then Artifact `resolve`.
6. Output one line: the APPLIED lines joined, or `synced, no requests`.
</step>

<step id="3" name="Arm the watch">
Run Artifact `status` with the url. When no watch is listed, or its row does not say auto-replies armed:
1. Artifact `watch` with the url.
2. Artifact `status` again. If auto-replies are still not armed, a sync (step 2) publish arms them when comment auto-replies are on for this session; run step 2 and check `status` once more.
3. Still not armed: output one line saying taps cannot wake this session and that the operator must turn comment auto-replies on for it (or paste the artifact link into this session and ask it to watch). Do not loop.
</step>

<step id="4" name="Periodic refresh">
The page's timestamps age while nothing happens. If the operator asks for a fresher page, run step 2 with no request file: `apply` with no new requests re-renders from the current fleet.
</step>

<edge-cases>
<case name="Read returns a stale-looking page">The live page is the truth; the ledger in fleet-state.json is yours. `apply` merges by request id, so re-processing an already-applied page or comment is harmless.</case>
<case name="Page shows 'The fleet anchor was not notified'">The viewer's tap published but its comment did not go out (the reason is on the page). The request is in the page state; the next sync applies it. Check step 3.</case>
<case name="resume-agent asks for a summary choice or reports a daemon-held transcript">The script answers the resume menu itself and records a daemon-held refusal as `error` with the script's own message; the operator reads it on the page and runs `claude stop <id>` from a terminal.</case>
<case name="Publish rejected as rate_limited">The artifact service caps publish frequency (no published number). Wait 60 seconds, re-read, re-apply, publish once more. If it is rejected again, stop and report the two rejections; do not loop.</case>
<case name="Session resumed or restarted">Watches are session-local. Run step 3 before anything else.</case>
</edge-cases>
