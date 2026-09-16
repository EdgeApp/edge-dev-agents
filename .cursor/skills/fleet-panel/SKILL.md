---
name: fleet-panel
description: Own the Fleet artifact (the mobile session-tui with a Resume button). Use in the dedicated `fleet` anchor session on eddy: publish the page once, then on every artifact-changed notification read the page, hand its state to fleet-panel.sh, and republish the result. Not for other sessions.
metadata:
  author: j0ntz
---

<goal>Keep the Fleet artifact current and execute the resume requests viewers queue on it, doing only the three things that need the Artifact tool (read, publish, watch) and leaving every decision and execution to `~/.config/agent-watcher/fleet-panel.sh`.</goal>

<rules description="Non-negotiable constraints.">
<rule id="script-executes">Never resume, spawn, kill or rename a session yourself. `fleet-panel.sh apply` is the only thing that acts on a request; it validates each uuid against the list the page itself published and runs `resume-agent.sh --uuid <id> --chat`. If a request looks wrong, the script records it as `error`; you do not work around it.</rule>
<rule id="read-before-publish">Every publish is preceded by an Artifact read of the live page in the same turn. The read is where new requests arrive; a publish without it overwrites them and the viewer's taps vanish.</rule>
<rule id="publish-by-url">Publish with `url` set to the value in `~/.config/agent-watcher/fleet-panel.json`, never by file path alone: this session may be a resume of the original publisher, and only the url form is guaranteed to update the same artifact.</rule>
<rule id="all-pending">Notifications coalesce. On each wake, process everything `apply` reports, not one request. Two taps ten seconds apart arrive as one "changed 2 times" notice.</rule>
<rule id="quiet">One wake is one turn: read, apply, publish, one line of output naming what was applied. No commentary, no Asana writes, no commits. The operator sees results on the page and in their Remote Control list, not here.</rule>
<rule id="conflict-means-reread">A publish rejected as conflict means a viewer published between your read and your publish. Re-read, re-apply, publish again, once. Never force.</rule>
</rules>

<step id="1" name="Init (once per artifact)">
Only when `~/.config/agent-watcher/fleet-panel.json` does not exist:

1. `~/.config/agent-watcher/fleet-panel.sh render --out /tmp/fleet-page.html`
2. Publish `/tmp/fleet-page.html` with the Artifact tool: favicon `🛰️`, `capabilities: {"artifact": {}}`, description "Live sessions and resumable transcripts on eddy; tap Resume to bring a transcript back as a remote-control chat session."
3. Write `{"url": "<published url>"}` to `~/.config/agent-watcher/fleet-panel.json` (Write tool).
4. Confirm the watch with the Artifact `status` action; it must say connected. Report the url once.
</step>

<step id="2" name="Sync (every artifact-changed notification, or when asked to sync)">
1. Artifact `read` with the url from fleet-panel.json. The result is the page's raw HTML, or names a local file when large.
2. Write the page's `<script type="application/json" id="state">` JSON to `/tmp/fleet-incoming.json` (Write tool). When the read named a file, use `~/.config/agent-watcher/fleet-panel.sh extract-state <file> > /tmp/fleet-incoming.json` instead.
3. `~/.config/agent-watcher/fleet-panel.sh apply /tmp/fleet-incoming.json --out /tmp/fleet-page.html` (allow up to 5 minutes: a resume waits for claude to boot). It prints `APPLIED <id> <status> [<rc>]` lines and `RENDERED /tmp/fleet-page.html`.
4. Publish `/tmp/fleet-page.html` with `url` from fleet-panel.json. Favicon and capabilities carry forward; do not pass them.
5. Output one line: the APPLIED lines joined, or `synced, no requests`.
</step>

<step id="3" name="Periodic refresh">
The page's timestamps age while nothing happens. If the operator asks for a fresher page, or a wake finds the page older than an hour with no requests, run step 2 anyway: `apply` with an empty request list re-renders from the current fleet.
</step>

<edge-cases>
<case name="Read returns a stale-looking page">The live page is the truth; the ledger in fleet-state.json is yours. `apply` merges by request id, so re-processing an already-applied page is harmless.</case>
<case name="resume-agent asks for a summary choice or reports a daemon-held transcript">The script answers the resume menu itself and records a daemon-held refusal as `error` with the script's own message; the operator reads it on the page and runs `claude stop <id>` from a terminal.</case>
<case name="Publish rejected as rate_limited">The artifact service caps publish frequency (no published number). Wait 60 seconds, re-read, re-apply, publish once more. If it is rejected again, stop and report the two rejections; do not loop. The page itself never retries a rate-limited publish.</case>
<case name="Watch missing after a resume">Artifact `status` shows no connected watch: run `watch` with the url. Without it no tap reaches this session.</case>
</edge-cases>
