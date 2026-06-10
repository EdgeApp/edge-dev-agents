---
name: debugger
description: Inspect runtime state in a running React Native app (variable values, which code path ran, why a check is false). Two methods. (1) Hermes CDP breakpoints via Metro for main-thread JS. (2) inject-and-capture for code inside edge-core-js's plugin WebView (swap/currency/accountbased plugins under DEBUG_*), which Hermes CDP CANNOT reach. NOT for static code analysis; use grep/read for that.
metadata:
  author: j0ntz
---

<goal>Attach to a running React Native / Hermes JS VM via Metro's Chrome DevTools Protocol (CDP) inspector, set a precise file:line breakpoint, and capture runtime state when it fires.</goal>

<rules description="Non-negotiable constraints.">
<rule id="pick-the-right-method">FIRST decide which method fits. Hermes CDP (steps 1-4) reaches only MAIN-THREAD JS (the Metro/Hermes VM). Code inside edge-core-js's plugin WebView (the swap/currency/accountbased plugins loaded via `DEBUG_*` dev-servers, e.g. `edge-exchange-plugins` on `DEBUG_EXCHANGES`:8083) runs in a separate WKWebView VM that Hermes CDP CANNOT see (`setBreakpointByUrl` resolves 0 locations; the script isn't in the target). For that code use the **inject-and-capture** method (step 5). `ios-webkit-debug-proxy` / Safari do NOT rescue this on modern iOS sims: iwdp 1.9.2 returns no `webinspectord` device on the iOS 18.6 simulator. See `[[rango-sonic-and-webview-debugging]]`.</rule>
<rule id="preflight-required">For the Hermes-CDP method, always run `~/.cursor/skills/debugger/scripts/check-metro.sh` FIRST. If it exits 1 (Metro not reachable) or 2 (no Hermes target), surface the script's stderr verbatim and STOP. Do not try to start Metro yourself unless the user explicitly asks — Metro startup involves the project's own dev server and is the user's call.</rule>
<rule id="use-script">All CDP interaction MUST go through `~/.cursor/skills/debugger/scripts/cdp-attach.js`. Do NOT open raw WebSockets, do NOT shell out to `chrome-devtools-frontend`, do NOT use any other CDP harness inline.</rule>
<rule id="line-numbers-are-1-based">User-facing line numbers are 1-based (matches what editors and humans use). `cdp-attach.js` handles the CDP 0-based conversion internally. Always pass the line as you would see it in an editor.</rule>
<rule id="no-mutation">The Hermes-CDP method (steps 1-4) does NOT edit source code, install npm packages, commit, push, or change Asana state; it reads runtime state through CDP and reports it. The ONE exception is the inject-and-capture method (step 5), which TEMPORARILY edits the dep source served by its `DEBUG_*` dev-server to add diagnostic POSTs. That instrumentation is local-only (never committed) and MUST be reverted when done (step 5e).</rule>
<rule id="one-breakpoint-per-invocation">Each `cdp-attach.js` invocation sets ONE breakpoint and reports ONE pause. For multi-breakpoint investigations, run multiple invocations (composable, predictable). Do NOT try to multiplex breakpoints in a single call — the report becomes ambiguous.</rule>
<rule id="report-is-stdout-json">`cdp-attach.js` writes a structured JSON report to stdout and status to stderr. When parsing for the caller (e.g. /one-shot), read stdout; show stderr only on failure or when diagnostic info is helpful.</rule>
</rules>

<step id="1" name="Preflight">

```bash
~/.cursor/skills/debugger/scripts/check-metro.sh
```

Expected: exit 0 with `>> check-metro: ready (Metro on :8081, N Hermes target(s))`.

Both `check-metro.sh` (`--port`) and `cdp-attach.js` (`--metro`) default to `$AGENT_METRO_PORT` when it's set (watcher-spawned parallel slots), else 8081 — so in a slot you can omit the port flags and still hit the right Metro. An explicit flag always overrides.

If exit 1 (Metro down) or 2 (no Hermes target): report the error from stderr to the user/caller and stop. The fix is on their side (start Metro, launch the app on a sim/device).

</step>

<step id="2" name="Pick a breakpoint location and (optionally) a trigger">

Decide:

- **File and line to break on.** Use the source file's name (or a unique substring) plus the editor line number. Example: `src/plugins/ramps/rampConstraints.ts:51`.
- **Trigger mode** (one of):
  - **Passive wait**: someone else (a user driving the app, a maestro flow, a CI script) will cause the code path to be hit. The script waits up to `--timeout-ms`.
  - **Active trigger**: pass `--trigger '<js-expr>'` — a JS snippet evaluated in the live VM that invokes the code path. Use when the agent knows enough about the app's runtime to call into it directly.
- **What to report** (defaults to `stack,locals`):
  - `stack` — top 10 call frames
  - `locals` — local-scope variables of the top frame
  - `evaluate:<expr>` — evaluate an arbitrary expression in the paused top frame (repeatable). Use to see derived values, dotted paths into objects, etc.
- **Conditional** (optional): `--condition '<js-expr>'` — only fire when the expression is truthy in the breakpoint's scope. Filters out unrelated calls (e.g. only break when `paymentType === "ach"`).

</step>

<step id="3" name="Run cdp-attach.js">

Passive wait, default report (stack + locals):

```bash
node ~/.cursor/skills/debugger/scripts/cdp-attach.js \
  --break-at rampConstraints.ts:51 \
  --timeout-ms 30000
```

Conditional, with extra expressions evaluated on hit:

```bash
node ~/.cursor/skills/debugger/scripts/cdp-attach.js \
  --break-at rampConstraints.ts:51 \
  --condition 'params.paymentType === "ach"' \
  --report 'stack,locals,evaluate:params.paymentType,evaluate:params.regionCode.countryCode' \
  --timeout-ms 30000
```

Active trigger (force the breakpoint to fire by evaluating an app function in the VM):

```bash
node ~/.cursor/skills/debugger/scripts/cdp-attach.js \
  --break-at rampConstraints.ts:51 \
  --trigger 'require("./src/plugins/ramps/infinite/infiniteRampPlugin").default.checkSupport({ countryCode: "FR" })' \
  --report 'stack,locals'
```

(The exact `--trigger` form depends on the app's module layout and what's reachable from the VM. Active triggers can be brittle — prefer passive wait + maestro to drive the app naturally when possible.)

</step>

<step id="4" name="Parse the report and act">

`cdp-attach.js` writes a JSON envelope to stdout. Shape:

```json
{
  "breakpoint": { "pattern": "rampConstraints.ts", "line": 51, "column": null, "resolved": 1 },
  "paused": {
    "reason": "other",
    "callStack": [
      { "function": "supportsBuyACH", "url": "file:///.../rampConstraints.ts", "line": 51, "column": 4 }
    ],
    "locals": { "params": "<object>", "supported": "false" },
    "evaluated": { "params.paymentType": "ach", "params.regionCode.countryCode": "FR" }
  }
}
```

On exit 2 (timeout, no hit), the envelope is `{ "error": "timeout", "breakpoint": {...} }` — the location may not have been on the executed code path, the user may not have driven the app to the relevant scene, or `--condition` filtered out every hit.

Use the report to answer the original question (why this value, what code path, etc.). For follow-up breakpoints, run another invocation — do NOT try to keep one process alive across multiple pauses.

</step>

<step id="5" name="Inject-and-capture (code inside the core WebView)">

Use this when the target runs in edge-core-js's plugin WebView (per `pick-the-right-method`); Hermes CDP can't reach it. You instrument the dep's source (served by its `DEBUG_*` webpack dev-server, which hot-reloads), have it POST runtime data to a tiny local server, then drive the app and read the captured log. Confirmed in the Rango/Sonic investigation: it revealed Edge's swap engine never calls the plugin's `fetchSwapQuote` at all (only the factory-load diag fired, never the public-method-entry diag), proving the plugin was filtered upstream rather than a bug in the plugin.

Prerequisite: the dep must be linked via its `DEBUG_*` dev-server (e.g. `DEBUG_EXCHANGES=true` in the gui `env.json` + the dep's `yarn start` on :8083) so your source edits are what the WebView loads. See `/build-and-test`'s `gui-dependency-integration` and `[[dep-linking-debug-flags]]`.

### 5a. Start the capture server (per-slot port + paths — parallel-agent safe)

The capture port and file paths MUST be unique per slot, or concurrent agents collide (EADDRINUSE, interleaved logs, truncating/killing each other's capture). Derive everything from the slot's Metro port:

```bash
DIAG_PORT=$(( ${AGENT_METRO_PORT:-8081} + 900 ))   # slot-unique: metro 8181→9081, 8182→9082…; manual 8981
DIAG_LOG="/tmp/diag-$DIAG_PORT.log"
DIAG_SRV="/tmp/diag-server-$DIAG_PORT.js"
```

Write `$DIAG_SRV` (substitute the literal values of `$DIAG_PORT`/`$DIAG_LOG`):

```js
const http = require('http'); const fs = require('fs')
http.createServer((req, res) => {
  let b = ''; req.on('data', c => (b += c))
  req.on('end', () => {
    fs.appendFileSync('<DIAG_LOG>', `[${new Date().toISOString()}] ${b}\n`)
    res.writeHead(200, { 'Access-Control-Allow-Origin': '*' }); res.end('ok')
  })
}).listen(<DIAG_PORT>, '127.0.0.1')
```

Run it backgrounded: `node "$DIAG_SRV" &`. Verify: `curl -X POST localhost:$DIAG_PORT --data test && cat "$DIAG_LOG"`.

### 5b. Add a diag helper to the dep source

In the plugin factory where the bridged fetch is in scope (e.g. `edge-exchange-plugins/src/swap/defi/rango.ts`, where `const { fetchCors = io.fetch } = io`), add:

```ts
const __diag = (label: string, data: unknown): void => {
  try {
    const p: any = fetchCors('http://localhost:<DIAG_PORT>/d', {
      method: 'POST', body: JSON.stringify({ label, data })
    })
    if (p != null && typeof p.catch === 'function') p.catch(() => {})
  } catch (e) {}
}
```

Hardcode YOUR computed `$DIAG_PORT` literal into the helper (the WebView bundle can't read your shell env; the instrumentation is temporary and reverted anyway). Never reuse another slot's port.

CRITICAL: use the plugin's BRIDGED fetch (`fetchCors` / `io.fetch`), NOT `globalThis.fetch`. Global fetch is unavailable in the core WebView and silently no-ops (this wasted a cycle). A plain string `body` defaults to `text/plain` (a CORS "simple request", so no preflight; the POST reaches the server even though the response is CORS-blocked from being read; fire-and-forget with `.catch`). Keep the helper type-clean: a TS or syntax error breaks the WHOLE plugin bundle and every swap silently fails.

### 5c. Place diag calls at decision points

Capture, in order of value: the factory body (fires on plugin load, proving the bundle reloaded AND the server is reachable), the PUBLIC method entry, each early gate/throw, the outbound API request, and the response/error. Instrument the PUBLIC entry SEPARATELY from inner helpers: if the factory-load diag fires but `public.entry` never does, the engine never called your plugin (it was filtered upstream), which is itself the answer.

### 5d. Reload the app, then drive it

The WebView loads the bundle at context creation, so you MUST relaunch to pick up edits:

```bash
xcrun simctl terminate "$AGENT_SIM_UDID" co.edgesecure.app
: > "$DIAG_LOG"
xcrun simctl launch "$AGENT_SIM_UDID" co.edgesecure.app
```

Confirm the dev-server recompiled cleanly first: `curl -s localhost:8083/edge-exchange-plugins.js | grep -c <your-label>` (expect ≥ 1). Then drive the app to the code path with maestro and read `$DIAG_LOG`. The factory-load line should appear first; if it never does, the WebView didn't reload the instrumented bundle (recheck the dev-server compile and the relaunch). (Remember the dep dev-server itself is a SINGLE-OCCUPANT host resource — see `/build-and-test`'s parallel-slot port rule; if another slot holds the dep's port, this method isn't available concurrently.)

### 5e. Clean up (MANDATORY)

Revert ALL injected `__diag` helper and calls from the dep source (`git checkout -- <file>`, or remove by hand) and stop YOUR server only — `pkill -f "diag-server-$DIAG_PORT"` (NEVER a bare `pkill -f diag-server`, which kills other slots' capture servers too). Remove `$DIAG_SRV` and `$DIAG_LOG`. The instrumentation is local-only and is never committed.

</step>

<edge-cases>
<case name="Breakpoint resolves to 0 locations">The source file URL Hermes reports may not match the pattern. Try a less specific pattern (e.g. just `rampConstraints` instead of `rampConstraints.ts`). If still 0, the source may be in a bundle without source maps — set the breakpoint by bundle URL instead (rare; usually means the dev build needs `--reset-cache`).</case>
<case name="Passive wait timed out (exit 2)">The breakpoint location was never executed within the budget. Either: (a) drive the app to the relevant scene first (maestro, manual user, etc.) then re-run with a fresh timeout; (b) widen `--timeout-ms`; (c) drop or loosen `--condition`; (d) verify the line you picked is actually executed (it might be inside an unused branch).</case>
<case name="Active trigger threw">The `--trigger` expression failed — usually because the function it tried to call is not reachable from the global scope at that moment (RN modules are lazily loaded). Fall back to passive wait + drive the app via maestro.</case>
<case name="Multiple Hermes targets">`cdp-attach.js` picks the first match for `--target-regex` (default `React Native|Hermes|Bridgeless`). If multiple devices/simulators are connected, narrow with a more specific `--target-regex` (e.g. the device name).</case>
<case name="Metro restarted mid-investigation">Scripts seen by the debugger reset. Re-run `check-metro.sh` and re-run the cdp-attach invocation.</case>
<case name="App crashes shortly after pause">Some RN debug builds are flaky (e.g. text-measure crashes on certain scenes). Resume happens automatically at the end of the report, but if you want to observe more state, capture everything in ONE invocation via `--report stack,locals,evaluate:...` — don't try to leave the VM paused for chained inspection.</case>
</edge-cases>

<notes-on-cdp description="Background on the underlying mechanism; the agent does not need to recite this, just know where it lives.">
The script speaks Chrome DevTools Protocol (CDP) directly via WebSocket — the same protocol Chrome DevTools and React Native DevTools use. Reference: https://chromedevtools.github.io/devtools-protocol/

Key CDP methods used:
- `Debugger.enable`, `Debugger.setBreakpointsActive`
- `Debugger.setBreakpointByUrl` — the canonical "break at file:line"
- `Debugger.paused` (event) — fired when execution stops
- `Runtime.getProperties` — read local-scope variables
- `Debugger.evaluateOnCallFrame` — evaluate expressions in the paused frame
- `Debugger.resume`

Metro exposes the CDP target list at `http://localhost:8081/json/list`. Each Hermes-backed app shows up as a target with a `webSocketDebuggerUrl` we connect to.
</notes-on-cdp>
