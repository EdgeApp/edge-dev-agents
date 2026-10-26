# Bugbot overlay for review-standards.mdc

Bugbot-only content that `generate-bugbot.js` merges into edge-react-gui's
`.cursor/BUGBOT.md`: one ``### <Title> (`<rule-id>`)`` heading per rule in
`../review-standards.mdc`, followed by optional code examples. The rule prose
itself comes from review-standards.mdc, so do not repeat it here.

The generator fails when a rule has no entry here or an entry names a rule the
source no longer has. When a rule is added, renamed or removed in
review-standards.mdc, update this file in the same change, regenerate, and copy
the result into edge-react-gui.

Everything above the first `###` heading is ignored.

### Preserve Stack Traces (`preserve-stack-traces`)

```ts
// Bad:
doSomething().catch(showError)

// Good:
doSomething().catch((error: unknown) => showError(error))
```

### Avoid `@ts-expect-error` (`avoid-ts-expect-error`)

```ts
// Bad:
// @ts-expect-error - cleaner can return undefined
items.map(renderItem)
```

```ts
// Good:
;(items ?? []).map(renderItem)
```

### Undefined vs Null Semantics (`undefined-vs-null-semantics`)

```ts
// Bad (treats null + undefined the same):
const changed = value != null

// Good:
const changed = value !== undefined
```

### Always Await Async (`always-await-async`)

```ts
// Bad:
wallet.saveTxMetadata(params).catch((error: unknown) => showError(error))

// Good:
await wallet.saveTxMetadata(params)
```

### No Redundant Catch (`no-redundant-catch`)

```ts
// Bad:
const handle = async () => {
  await op().catch((error: unknown) => showError(error))
}

// Good:
const handle = async () => {
  await op()
}
```

### TokenId Must Not Fallback to Null (`tokenid-no-null-fallback`)

```ts
// Bad:
const spendTokenId = tokenId ?? null

// Good:
if (tokenId == null) throw new Error('Missing tokenId')
const spendTokenId = tokenId
```

### No Redundant Error Handling (`no-redundant-error-handling`)

```ts
// Bad (double-report):
await doThing().catch((error: unknown) => showError(error))

// Good:
await doThing()
```

### Handle User Cancellation (`handle-user-cancellation`)

```ts
// Bad:
try {
  await showModal()
} catch (error) {
  showError(error)
}

// Good:
try {
  await showModal()
} catch (error) {
  if (error instanceof UserCancelledError) return
  showError(error)
}
```

### Do Not Mask Errors (`dont-mask-errors`)

```ts
// Bad:
catch (error) {
  throw new Error('Failed')
}

// Good:
catch (error) {
  if (isExpectedError(error)) throw new Error('Invalid request')
  throw error
}
```

### Check Array Bounds (`check-array-bounds`)

```ts
// Bad:
useAddress(vin.addresses[0])

// Good:
if (vin.addresses.length === 0) return
useAddress(vin.addresses[0])
```

### Compare Same Types (`compare-same-types`)

```ts
// Bad:
const isSpecial = SPECIAL_TOKEN_IDS.includes(request.fromCurrencyCode)

// Good:
const isSpecial = SPECIAL_TOKEN_IDS.includes(request.fromTokenId)
```

### Lookup Table Defensive Access (`lookup-table-defensive-access`)

```ts
// Bad:
const ok = TABLE[pluginId].includes(tokenId)

// Good:
const ok = TABLE[pluginId]?.includes(tokenId) ?? false
```

### Consolidate Guard Clauses (`consolidate-guard-clauses`)

```ts
// Bad:
if (mode === 'a') {
  if (!id) return
  doA(id)
} else {
  if (!id) return
  doB(id)
}

// Good:
if (!id) return
if (mode === 'a') doA(id)
else doB(id)
```

### Narrow Try Scope (`narrow-try-scope`)

### Check Response Status (`check-response-ok`)

### No Silent Success (`no-silent-success`)

### Structured Logging (`structured-logging`)

### Log Only Real Work (`log-only-real-work`)

### Surface Errors, Not Console (`surface-errors-not-console`)

### Prefer `useHandler` Over `useCallback` (`useHandler-over-useCallback`)

```ts
// Bad:
const onPress = useCallback(() => {
  void submit()
}, [submit])

// Good:
const onPress = useHandler(() => {
  void submit()
})
```

### Combine Related Effects (`combine-related-effects`)

```ts
// Bad: two effects update the same derived state
useEffect(() => setLabel(getLabel(a)), [a])
useEffect(() => setLabel(getLabel(b)), [b])

// Good:
useEffect(() => {
  setLabel(getLabel(a, b))
}, [a, b])
```

### Extract Display Logic (`display-logic-extraction`)

```ts
// Bad:
const title = a ? (b ? 'A+B' : 'A') : b ? 'B' : 'None'

// Good:
function getTitle(a: boolean, b: boolean): string {
  if (a && b) return 'A+B'
  if (a) return 'A'
  if (b) return 'B'
  return 'None'
}
```

### Use `StyleSheet.compose` (`stylesheet-compose`)

```ts
// Bad:
const style = [styles.base, maybeStyle]

// Good:
const style = StyleSheet.compose(styles.base, maybeStyle)
```

### Platform Keyboard Return Key (`platform-keyboard`)

```tsx
<TextInput
  keyboardType="number-pad"
  returnKeyType={Platform.OS === 'ios' ? undefined : 'done'}
/>
```

### Preserve Props When Replacing Components (`preserve-props-replacement`)

```tsx
// Bad:
<NewIcon />

// Good:
<NewIcon color={color} size={size} style={style} />
```

### Maintain Styling When Switching Icons (`maintain-styling-icon-switch`)

```tsx
// Good:
<View style={styles.iconSpacing}>
  <NewIcon color={color} size={size} />
</View>
```

### Wrap Navigation After Gestures (`interactionmanager-nav`)

```ts
InteractionManager.runAfterInteractions(() => {
  navigation.push('NextScreen')
})
```

### Disable UI During Async (`disable-ui-async`)

```ts
const [pending, setPending] = useState(false)

const onPress = useHandler(async () => {
  if (pending) return
  setPending(true)
  try {
    await submit()
  } finally {
    setPending(false)
  }
})
```

### React Native Render Cost (`rn-render-cost`)

### White-Label Neutral (`white-label-neutral`)

### No Duplicate Redux State in Local State (`no-duplicate-redux-local`)

```ts
// Bad:
const reduxValue = useSelector(selectValue)
const [value] = useState(reduxValue)

// Good:
const value = useSelector(selectValue)
```

### Avoid Module-Level Cache Bugs (`module-level-cache-bugs`)

```ts
let cached: Thing | undefined

export function clearThingCache(): void {
  cached = undefined
}
```

### Settings Belong in Redux (`settings-in-redux`)

```ts
// Good:
dispatch(settingsActions.setFoo(value))
```

### Use DataStore API (`datastore-api`)

```ts
// Bad:
await account.localDisklet.setText('settings.json', text)

// Good:
await account.dataStore.setItem('settings', text)
```

### Include Data Format Migrations (`data-format-migrations`)

```ts
const old = await account.dataStore.getItem('settings-v1')
if (old != null) {
  const migrated = migrateV1ToV2(old)
  await account.dataStore.setItem('settings-v2', migrated)
  await account.dataStore.removeItem('settings-v1')
}
```

### Merge Nested State Objects (`merge-state-objects`)

```ts
// Bad:
settings.notifState = newNotifState

// Good:
settings.notifState = { ...settings.notifState, ...newNotifState }
```

### No Module-Level Mutable State (`no-module-level-mutable-state`)

### Combine Related Dispatches (`combine-dispatches`)

### Use `makePeriodicTask` (`makePeriodicTask`)

```ts
const task = makePeriodicTask(async () => {
  await refresh()
}, 30_000)
```

### Background Services Location (`background-services-location`)

```tsx
// Good: mount service for lifecycle
return (
  <>
    <SomeScreen />
    <MyBackgroundService />
  </>
)
```

### Prevent Concurrent Execution (`prevent-concurrent-execution`)

```ts
if (pending) return
setPending(true)
try {
  await doWork()
} finally {
  setPending(false)
}
```

### Polling Race Conditions (`polling-race-conditions`)

```ts
while (!cancelled) {
  const result = await fetchStuff()
  if (cancelled) return
  onResult(result)
}
```

### Refresh State in Delayed Callbacks (`refresh-state-callbacks`)

```ts
setTimeout(() => {
  const latest = store.getState().someSlice
  void doThing(latest)
}, 1000)
```

### Cleanup Timeouts on Shutdown (`cleanup-timeouts-shutdown`)

```ts
const timeouts = new Set<ReturnType<typeof setTimeout>>()

function addTimeout(id: ReturnType<typeof setTimeout>): void {
  timeouts.add(id)
}

function shutdown(): void {
  for (const id of timeouts) clearTimeout(id)
  timeouts.clear()
}
```

### Serialize Event Handlers (`serialize-event-handlers`)

```ts
const pendingByRepo = new Map<string, Promise<void>>()

async function runSerialized(repoId: string, fn: () => Promise<void>) {
  const prev = pendingByRepo.get(repoId) ?? Promise.resolve()
  const next = prev.then(fn, fn)
  pendingByRepo.set(repoId, next)
  await next
}
```

### Order State Around Awaits (`order-state-around-awaits`)

### Stale Async Generation Check (`stale-async-generation-check`)

### Bound Pagination and Timeouts (`bound-pagination-and-timeouts`)

### Recover From Network Failures (`recover-from-network-failures`)

### Release Resources on Error (`release-resources-on-error`)

### Clean All External Data (`clean-all-external-data`)

```ts
// Good:
const cleaned = asMyType(raw)
```

### Derive Types From Cleaners (`derive-types-from-cleaners`)

```ts
export type MyType = ReturnType<typeof asMyType>
```

### `asOptional` Also Accepts Null (`asoptional-handles-null`)

```ts
// Good:
const asField = asOptional(asEither(asNull, asString), null)
```

### New Persisted Fields Must Be Optional (`new-fields-optional`)

```ts
// Good:
const asSettings = asObject({
  version: asNumber,
  newField: asOptional(asString)
})
```

### Remove Unused Cleaner Fields (`remove-unused-cleaner-fields`)

```ts
// Good: delete unused field, or comment why it remains
```

### Normalize at the Boundary (`normalize-at-the-boundary`)

### Explicit Units (`units-explicit`)

### Delete Unnecessary Code (`delete-unnecessary-code`)

```ts
// Bad:
// TODO: maybe use later
// const unused = 123

// Good: delete it
```

### Put Parameters Inline (`put-parameters-inline`)

```ts
// Bad:
const x = 1
doThing(x)

// Good:
doThing(1)
```

### Use Existing Helpers (`use-existing-helpers`)

```ts
// Good:
const tokenId = getTokenId(wallet, currencyCode)
```

### Avoid Duplicated Mocks (`avoid-duplicated-mocks`)

```ts
// Good:
import { fakeWallet } from '../../util/fake/fakeWallet'
```

### No Hardcoded Debug URLs (`no-hardcoded-debug-urls`)

```ts
// Bad:
const baseUrl = 'https://sandbox.example.com'

// Good:
const baseUrl = envConfig.apiUrl
```

### No Local Path Dependencies (`no-local-path-deps`)

```json
// Bad:
{ "some-lib": "file:../some-lib" }
```

### Guard Debug Logging (`guard-debug-logging`)

```ts
// Bad:
console.log('debug', value)

// Good:
if (ENV.DEBUG_VERBOSE_LOGGING) console.log('debug', value)
```

### Validation Single Source (`validation-single-source`)

```ts
const error = validateForm(values)
setError(error)
if (error != null) return
```

### Local Helpers for Amount Conversion (`local-helpers-amount-conversion`)

```ts
// Good:
const display = div(nativeAmount, multiplier, 18)
```

### No Hand-Rolled Standard Ops (`no-hand-rolled-ops`)

```ts
// Good:
import { base64 } from 'rfc4648'
```

### Keep Config Consistent (`keep-config-consistent`)

```ts
// Good:
export const POLL_MS = 30_000
```

### Remove Unused Styles (`remove-unused-styles`)

```ts
// Good: remove styles.unused if nothing references it
```

### Existing User Paths (`existing-user-paths`)

### No Debug Scaffolding (`no-debug-scaffolding`)

### File Placement Conventions (`file-placement-conventions`)

### Logic Belongs in the Owning Layer (`logic-belongs-in-owning-layer`)

### Name Magic Values (`name-magic-values`)

### No Hardcoded Config (`no-hardcoded-config`)

### Avoid Repeated Work (`avoid-repeated-work`)

### Follow Repo Naming Conventions (`follow-repo-naming-conventions`)

### Match Sibling Behavior (`match-sibling-behavior`)

### Plain Functions Over IIFEs (`plain-functions-over-iife`)

### Declare Direct Dependencies (`declare-direct-dependencies`)

### Guard Parsed Numbers and Divisors (`guard-numeric-inputs`)

### Refactors Keep Every Case (`refactor-preserves-behavior`)

### Fix the Root Cause (`fix-root-cause`)

### Names Match What They Hold (`names-match-role`)

### Match the Local Form (`match-local-form`)

### Methods Without this Become Functions (`methods-without-this`)

### Const and Ternary Over Reassigned Let (`const-over-reassigned-let`)

### Reuse Existing Strings (`reuse-existing-strings`)

```ts
// Good:
const text = sprintf(lstrings.get_started_button)
```

### Context-Based Key Names (`context-based-key-names`)

```text
Bad: signup_screen_get_started
Good: get_started_button
```

### Avoid "Tap to ..." (`avoid-tap-to-x`)

```text
Bad: Tap to select a country
Good: Select a country
```

### Localization Happens in the GUI Layer (`localization-gui-level`)

```ts
// Good (plugin/API):
throw new NetworkError('CONNECTION_FAILED')

// Good (GUI):
showError(lstrings.connection_failed)
```

### Add Non-Obvious Constraints (`add-non-obvious-constraints`)

```ts
// EVM-only: assumes EVM contract address format
```

### Remove Stale Comments (`remove-stale-comments`)

```ts
// Bad: comment says "only mainnet" but code supports testnet too
```

### Comments Explain Why, Not What (`comments-why-not-what`)

```ts
// Bad:
// Loop through items and filter by status

// Good:
// Only active items can be edited; archived items are read-only
```

### Doc Links Resolve (`doc-links-resolve`)

### JSDoc for APIs and Deprecations (`jsdoc-for-api-and-deprecations`)

### Commit Subjects Fit in 50 Characters (`commit-subject-50`)

### No Attribution Trailers (`no-attribution-trailers`)

### CHANGELOG Section and Verb (`changelog-section-and-verb`)

### CHANGELOG Entry for User-Visible Changes (`changelog-entry-with-change`)

### Clean Commit History (`clean-commit-history`)

### Split Unrelated Fixes (`split-unrelated-fixes`)

### Commit Message Matches Diff (`commit-message-matches-diff`)

### No Unrelated Lockfile Churn (`no-unrelated-lockfile-churn`)

### tokenId, Not currencyCode (`tokenid-not-currencycode`)

### tokenId Typed and Required (`tokenid-typed-and-required`)

### No Sentinel Empty Values (`no-sentinel-empty-values`)

### Map and Set for Dictionaries (`map-set-for-dictionaries`)

### Discriminated Unions Over Flags (`discriminate-over-flags`)

### Narrowest Accurate Types (`narrowest-accurate-types`)

### Deprecated Fields Last (`deprecated-fields-last`)

### No Secrets in Dumps or Logs (`no-secrets-in-dumps-or-logs`)

### Test Each Guard (`test-each-guard`)

### No Redundant Tests (`no-redundant-tests`)

### Server devDependencies (`server-devdependencies`)

```text
All deps go in devDependencies except cleaner packages.
```

### Separate Server/Client Config (`separate-configs`)

```text
Validate serverConfig.json and clientConfig.json with cleaners.
```

### PM2 Process Management (`pm2-process-management`)

```text
API in cluster mode; engines as single instances.
```

### Build Both Frontend/Backend (`build-both`)

```text
build script must build both (parallel ok).
```
