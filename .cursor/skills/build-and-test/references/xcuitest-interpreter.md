# XCUITest flow interpreter (iOS)

`scripts/xcuitest-run.sh` runs Maestro flow YAML natively. One generic XCUITest
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
| `openLink` | Scalar URL or `link:`. Hands the URL straight to the app under test (`XCUIApplication.open`), with no "Open in Edge?" system dialog, for custom-scheme (`edge://`) and `https://` links alike. Returns before the app navigates, so follow it with an `extendedWaitUntil` on the target scene. The Android-only keys `autoVerify` and `browser` are accepted and ignored. |
| `tapOn` / `longPressOn` | `text`, `id`, `index`, `enabled`, `point`, `waitToSettleTimeoutMs`, `retryTapIfNoChange`. `point` alone is a screen position: `"50%,80%"` (whole percentages of the screen) or `"120,640"` (points). `point` next to `text` or `id` is relative to the matched element. `longPressOn` holds for 3s, as Maestro does on iOS |
| `assertVisible` / `assertNotVisible` | `enabled: true/false` narrows the match to enabled or disabled elements. Maestro timeouts: 17s (7s when `optional`), minus time since the last interaction |
| `extendedWaitUntil` | `visible` / `notVisible`, `timeout` |
| `runFlow` | `file`, inline `commands`, `env`, `when` (`visible`, `notVisible`, `true`, `platform`) |
| `inputText` / `eraseText` / `pressKey` | `pressKey`: Enter, Backspace, Home, and Back (does nothing, as on Maestro iOS). `eraseText` defaults to 50 characters. When no element has keyboard focus (a hidden input, such as the PIN entry) the runner taps the on-screen keys instead, so only characters with their own key (digits, the current letter case, space) can be typed |
| `inputRandomText` | `length` (default 8). Types random lowercase letters |
| `copyTextFrom` / `pasteText` | `copyTextFrom` takes a selector and stores the element's text (title, else value, else placeholder, else label), also as `maestro.copiedText` for `evalScript` and `${}`. `pasteText` types it, and types nothing when nothing was copied |
| `hideKeyboard` | Maestro's iOS behavior: nothing when no keyboard is up, else a short swipe up from the screen center, then a short swipe left if the keyboard is still there. Fails when the keyboard survives both, which Maestro also does; tap a non-interactive element in that case |
| `back` | Accepted and does nothing, the same as Maestro on iOS |
| `scroll` / `scrollUntilVisible` / `swipe` | `scrollUntilVisible`: `element`, `direction`, `timeout`, `visibilityPercentage`, `centerElement`, `waitToSettleTimeoutMs`. With `centerElement`, an element that is on screen but outside the center band is dragged by its own distance from the screen center (Maestro repeats the full swipe, which can carry the element past the band and off screen). `swipe`: `from` + `direction`, or `start` / `end` points (`"50%,80%"`), `duration` |
| `repeat` / `retry` | `repeat`: `times`, `while`. `retry`: `maxRetries`, `file` or `commands` |
| `evalScript` | Full JavaScript (JavaScriptCore). `output.*` persists for the whole run |
| `waitForAnimationToEnd` | Two consecutive identical screenshots, `timeout` default 15s |
| `takeScreenshot` | Same path rules as `maestro test`: relative to the current directory, `.png` appended |

`optional: true` and `label` work on every command.

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
