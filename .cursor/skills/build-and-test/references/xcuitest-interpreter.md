# XCUITest flow interpreter (iOS)

`scripts/xcuitest-run.sh` runs Maestro flow YAML natively, and reads or probes
the live screen without a flow file (`--inspect`, `--steps`). One generic XCUITest
bundle (`xcuitest/EdgeFlowRunner`) is built once per Xcode build, iOS runtime
and source hash (`scripts/xcuitest-build.sh`, cached under
`~/Library/Caches/edge-flow-runner`). Each run is then one
`xcodebuild test-without-building` against the slot UDID.

## Run sequence

1. `maestro-yaml-to-json.rb` converts the flow and inlines every `runFlow` /
   `retry` file (paths resolve relative to the including flow). `--env K=V`
   values ride along as CLI env.
2. The runner reads the JSON (`TEST_RUNNER_EDGE_FLOW_FILE`) and preflights the
   whole tree. Any unsupported command, argument, condition key, selector key
   or `pressKey` value fails the run before step 1 with exit 2, naming the
   flow and step. There is no Maestro fallback.
3. Commands run in order. Each prints
   `[edge-flow] <total>s (+<step>s) <flow> #<n> <command> <args> -> ok|skipped|FAILED`.

## Supported commands

| Command | Notes |
|---|---|
| `launchApp` | `appId`, `stopApp: false` (activate if running). `clearState: true` is rejected because it wipes the roster accounts. Passes `-EdgeTestAnimations <mode>` unless `--animations on`. |
| `stopApp` | |
| `openLink` | Scalar URL or `link:`. A custom-scheme link (`edge://`) goes through the system opener (`XCUIDevice.shared.system.open`): delivered in under a second to an app this session launched or only attached to, with no "Open in Edge?" system dialog. An `http(s)` link uses `XCUIApplication.open`, which works only after a `launchApp` in the same invocation started the app; without one the step fails at once and names the fix, so write links in their custom-scheme form (`edge://redirect/payment/?...` carries the same parameters as the `https://edge.app/redirect/payment/?...` form). Returns before the app navigates, so follow it with an `extendedWaitUntil` on the target scene. The Android-only keys `autoVerify` and `browser` are accepted and ignored. |
| `tapOn` / `longPressOn` | `text`, `id`, `index`, `enabled`, `point`, `waitToSettleTimeoutMs`, `retryTapIfNoChange`, `failIfNoChange` (runner-only; see "Input that changes nothing"). `point` alone is a screen position: `"50%,80%"` (whole percentages of the screen) or `"120,640"` (points). `point` next to `text` or `id` is relative to the matched element. `longPressOn` holds for 3s, as Maestro does on iOS |
| `assertVisible` / `assertNotVisible` | `enabled: true/false` narrows the match to enabled or disabled elements. Maestro timeouts: 17s (7s when `optional`), minus time since the last interaction. `assertNotVisible` therefore holds about 17s before it fails on text that is visible; for a fast absence check use `extendedWaitUntil: {notVisible: ..., timeout: 2000}` |
| `extendedWaitUntil` | `visible` / `notVisible`, `timeout` |
| `runFlow` | `file`, inline `commands`, `env`, `when` (`visible`, `notVisible`, `true`, `platform`). A `when: visible:` on an absent element, or `when: notVisible:` on a present one, waits 7s minus the time since the last interaction (launch, tap, drag, typing; waits, `evalScript` and `takeScreenshot` do not count), so about 7s right after a tap and nothing after a long wait. `when: notVisible:` on an absent element and `when: true:` return at once: gate on a value known before the run (`true:`) or probe absence first, never on the presence of something that is usually absent |
| `inputText` / `eraseText` / `pressKey` | `pressKey`: Enter, Backspace, Home, and Back (does nothing, as on Maestro iOS). `eraseText` defaults to 50 characters. Three typing paths, tried in order: the focused element (`typeText`); with no focused element (a hidden input, such as the PIN entry) the on-screen keys, which covers only characters with their own key (digits, the current letter case, space); when a key is missing or the keyboard's keys are off screen, key events sent to the app. The step line names the path when it is not the first. `--typing events` sends every string as key events |
| `inputRandomText` | `length` (default 8). Types random lowercase letters |
| `copyTextFrom` / `pasteText` | `copyTextFrom` takes a selector and stores the element's text (title, else value, else placeholder, else label), also as `maestro.copiedText` for `evalScript` and `${}`. `pasteText` types it, and types nothing when nothing was copied |
| `hideKeyboard` | Maestro's iOS behavior: nothing when no keyboard is up, else a short swipe up from the screen center, then a short swipe left if the keyboard is still there. Fails when the keyboard survives both, which Maestro also does; tap a non-interactive element in that case |
| `back` | Accepted and does nothing, the same as Maestro on iOS |
| `scroll` / `scrollUntilVisible` / `swipe` | `scrollUntilVisible`: `element`, `direction`, `timeout`, `visibilityPercentage`, `centerElement`, `waitToSettleTimeoutMs`. With `centerElement`, an element that is on screen but outside the center band is dragged by its own distance from the screen center (Maestro repeats the full swipe, which can carry the element past the band and off screen). `swipe`: `from` + `direction`, or `start` / `end` points (`"50%,80%"`), `duration`. The step's log line carries the resolved from and to points and, for a `from` element, its frame before the drag and after it settles (`gone` when it does not resolve): the data to read when a gesture reports ok but the app did not react |
| `repeat` / `retry` | `repeat`: `times`, `while`. `retry`: `maxRetries`, `file` or `commands` |
| `evalScript` | Full JavaScript (JavaScriptCore). `output.*` persists for the whole run |
| `waitForAnimationToEnd` | Two consecutive identical screenshots, `timeout` default 15s |
| `takeScreenshot` | Same path rules as `maestro test`: relative to the current directory, `.png` appended |
| `inspectScreen` | Runner-only (Maestro has no such command). Prints the screen as `--inspect` does. `full: true` lists every node; `verify: true` also checks each identified on-screen element's `hit` against `XCUIElement.isHittable` (about 1s per element) and prints the differences |

`optional: true` and `label` work on every command.

## Input that changes nothing

A tap that lands on nothing raises no XCUITest error. The runner compares the
screen before the tap with the screen up to 1.0s after it:

- Default (`--tap-check note`): the step line ends
  `-> ok, but the screen did not change within 1.0s`. The step still passes;
  the scene-advanced check after it is what fails the flow. `--tap-check off`
  skips the two screenshots per tap.
- `retryTapIfNoChange: true` (a Maestro argument) taps once more and reports
  `ok after a second tap (the first changed nothing)`.
- `failIfNoChange: true` fails the step: `the tap changed nothing on screen
  within 1.0s`. Maestro rejects the key, so a flow that uses it runs on the
  interpreter only; library flows that run on both drivers keep the check in
  YAML (a short `extendedWaitUntil` after the tap).

Before step 1 the preflight prints one `[edge-flow] lint: <flow> #<n>: a <N>s
wait directly follows <input>; put a short scene-advanced check between them`
line for every `extendedWaitUntil` over 20s placed directly after a tap, long
press, swipe or key press (`waitForAnimationToEnd`, `takeScreenshot` and
`evalScript` between them do not count as a check). A lint line does not fail
the run.

## Roster login

`--login-role <role>` reads that role's account from the local roster and
passes it to the flow as env `EXPECT_USERNAME` and `PIN_DIGIT`.
`common/login-if-needed.yaml` then fails within 5s, before any digit is
tapped, when the PIN scene shows another account. Step lines and inspect
output show the account name and the tapped digits as they are.

Every run also gets env `LOGIN_MODE` and `AGENT_TEST_MODE`, read from the
config of the gui checkout that the Metro on `$AGENT_METRO_PORT` serves
(the script header has the derivation). `LOGIN_MODE=yolo` means the bundle
signs in on launch: `common/login-if-needed.yaml` waits for the home scene
and probes no PIN scene. YOLO signs in once per app process, so a flow that
signs out and back in without a relaunch passes `LOGIN_MODE: pin` in that
`runFlow`'s env. `AGENT_TEST_MODE=true` means the app raises no post-login
modal, notification card or LogBox warning toast, and
`common/dismiss-startup-modals.yaml` skips its modal gates. In either mode,
a LogBox toast with any label but `! Open debugger to view warnings.` is an
error: the session that meets it fixes the cause, and a dismissal is not a
fix.

## Inspect and probe

`--inspect` prints the app's screen from one accessibility snapshot (about
0.1 to 0.8s inside a 4 to 7s run) and sends no event; it never launches the
app and exits 2 when the app is not running. The header gives the app state,
screen size and element count; each line is
`Type id="" label="" value="" placeholder="" frame=x,y,WxH hit|nohit|offscreen [disabled]`,
indented by nesting. Compact mode keeps elements that have an identifier or
readable text and drops unnamed containers, a leaf repeating its parent's
label, icon-font glyphs, scroll bars and off-screen nodes without an id (it
prints how many); keyboard keys fold into one line. A SpringBoard alert over
the app prints in its own section.

`hit` is computed from the snapshot, not by touching the app: XCTest's
snapshot hit test must pass (`-[XCElementSnapshot hitPoint:]`) and no element
later in tree order may cover the element's center. React Native draws later
siblings on top. Covers are elements with an id, non-container types, and
labelled containers that overlap only part of the element (one that holds
the whole element is a pass-through scene wrapper). `nohit covered-by="..."`
names the cover, `screen edge` when the center is off screen. A tap is still
the ground truth; `inspectScreen: {verify: true}` measures the estimate
against XCTest.

`--steps '<yaml>'` runs a command list, one `command: args` map or a bare
command name against the app as it is. Probes default to a 3s element lookup
(`--lookup-timeout`) and skip xcodebuild's failure diagnostics, so a missed
selector fails in about 11s instead of 42s.

## Maestro semantics the runner keeps

- `text` and `id` selectors are case-insensitive regexes (dot matches newline)
  that must match the WHOLE attribute, or equal it literally. `text` checks
  label, value and placeholderValue. The deepest matching element wins;
  `index` orders on-screen matches top to bottom, then left to right.
- `${...}` and `evalScript` are JavaScript. A script error fails the step and
  prints the source. `when: { true: ... }` is false for blank, `false`, `0`,
  `null` and `undefined`.
- A subflow's header `env:` is evaluated after the caller's `runFlow env:`, so
  the header's `KEY: ${KEY || default}` idiom sees the caller's value.

## Quiescence cap

XCUITest waits for the app to go idle before and after every event. React
Native apps with timers or loading spinners can hold that wait for many
seconds. The runner swizzles `XCUIApplicationProcess`'s quiescence waits (the
WebDriverAgent approach) to give up after `--quiescence-cap` seconds (default
1; 0 skips the wait). Every wait that reaches the cap prints
`[edge-flow] quiescence cap hit ... step: <step>`, and the last line of the run
counts them. A flow sets its own cap with env `EDGE_QUIESCENCE_CAP`.

## Test-mode animations (edge-react-gui debug builds)

`--animations off` (default) passes `-EdgeTestAnimations off` on `launchApp`
and writes it to the sim's defaults for manual relaunches. UIKit animations
then complete immediately, and Reanimated runs in reduced motion, so looping
shimmers and chart pulses stop after one cycle. `fast` runs Core Animation at
100x instead. Both modes also freeze native `ActivityIndicator` spinners in
place, so `waitForAnimationToEnd` settles on a loading screen (0.2s, versus
the full timeout with `on`). `on` clears the flag. Release builds ignore it.
Spinners do not hold the quiescence wait in any mode.

## Not supported (preflight rejects)

`launchApp clearState: true` and any command missing from the table above.
To drive a flow that needs one, rewrite the step or run that flow on the
maestro CLI and name it in the run report.
Inspect reads only the app under test and a SpringBoard alert; read another
app's screen (Safari, Settings) with the maestro CLI's `hierarchy` subcommand.
