---
name: debugger
description: Set a breakpoint at a file:line in a React Native / Hermes app running under Metro, then capture the call stack, local variables, and arbitrary expressions at that point. Use when an agent needs to inspect runtime state — values of variables, what code path is taken, why a check evaluates to false, etc. — in a real running RN app. NOT for static code analysis; use grep/read for that.
metadata:
  author: j0ntz
---

<goal>Attach to a running React Native / Hermes JS VM via Metro's Chrome DevTools Protocol (CDP) inspector, set a precise file:line breakpoint, and capture runtime state when it fires.</goal>

<rules description="Non-negotiable constraints.">
<rule id="preflight-required">Always run `~/.cursor/skills/debugger/scripts/check-metro.sh` FIRST. If it exits 1 (Metro not reachable) or 2 (no Hermes target), surface the script's stderr verbatim and STOP. Do not try to start Metro yourself unless the user explicitly asks — Metro startup involves the project's own dev server and is the user's call.</rule>
<rule id="use-script">All CDP interaction MUST go through `~/.cursor/skills/debugger/scripts/cdp-attach.js`. Do NOT open raw WebSockets, do NOT shell out to `chrome-devtools-frontend`, do NOT use any other CDP harness inline.</rule>
<rule id="line-numbers-are-1-based">User-facing line numbers are 1-based (matches what editors and humans use). `cdp-attach.js` handles the CDP 0-based conversion internally. Always pass the line as you would see it in an editor.</rule>
<rule id="no-mutation">This skill does NOT edit source code, install npm packages into the target repo, commit, push, or change Asana state. It reads runtime state through CDP and reports it.</rule>
<rule id="one-breakpoint-per-invocation">Each `cdp-attach.js` invocation sets ONE breakpoint and reports ONE pause. For multi-breakpoint investigations, run multiple invocations (composable, predictable). Do NOT try to multiplex breakpoints in a single call — the report becomes ambiguous.</rule>
<rule id="report-is-stdout-json">`cdp-attach.js` writes a structured JSON report to stdout and status to stderr. When parsing for the caller (e.g. /one-shot), read stdout; show stderr only on failure or when diagnostic info is helpful.</rule>
</rules>

<step id="1" name="Preflight">

```bash
~/.cursor/skills/debugger/scripts/check-metro.sh
```

Expected: exit 0 with `>> check-metro: ready (Metro on :8081, N Hermes target(s))`.

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
