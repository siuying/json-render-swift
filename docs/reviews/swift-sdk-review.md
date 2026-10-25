# Swift SDK review

Reviewed `swift/JSONRenderSwiftUI/**` against `docs/ARCHITECTURE.md`, the SDK README, parity fixtures, and the upstream core/native renderer sources on 2026-10-25. Excluded the generated bridge resource and `ios/`. No source files were changed.

## Verified findings

### 1. High: a failed submit does not stop the remaining event actions

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Actions/ActionDispatcher.swift:45` and `:69`.

`execute("submit")` returns `.halted` when validation fails, but `dispatch(binding)` consumes that outcome and returns `Void`. The array overload always proceeds. An event such as `[submit, resetForm]` consequently clears invalid input and its error captions. `[submit, customSave]` still calls `customSave` with invalid data, contrary to the contract's instruction to stop after validation failure.

Verified with a field containing `"abc"` and a minimum length of five. Dispatching `[submit, after]` called the registered `after` handler once, although submit failed.

Suggested fix: propagate the halted outcome through single-binding dispatch and stop the array loop. Cover invalid submit followed by a state write and a host action.

### 2. High: queued watchers from an old spec can overwrite a newly loaded form

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Session/FormSession.swift:165`.

`fireWatchers` creates an untracked task containing the old bindings. Changing the root resets state but neither cancels that task nor checks whether its originating element still exists. The old action subsequently executes against the new session state. A suspended watch action chain can similarly resume after its element disappears.

Verified by changing a watched `/name`, immediately assigning a spec with a different root and `state.derived = "new form"`, then yielding. An old watch binding changed `/derived` to `"fired"` in the new form. Upstream React's watch effect has cancellation checks between bindings and cancels on cleanup.

Suggested fix: associate watch tasks with the spec generation and element identity, cancel them on removal/root replacement, and check validity before dispatch and after every suspension.

### 3. Medium: array append and index aliases leave observable state permanently stale

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Runtime/StateStore.swift:96`.

Slot invalidation compares literal pointer segments, while JSON Pointer access interprets array segments with `parseInt`. Writing `/items/-` changes `/items/1`, but those segment lists do not overlap. The same problem occurs between `/items/00` and `/items/0`. Once a slot is cached, future reads continue returning its old value, even when its view re-renders for another reason. Visibility and bound controls can therefore disagree with validation and submitted data, which use uncached state.

Verified from `{"items":["a"]}`:

- Read `/items/1`, append `"b"` at `/items/-`: `value(at:)` remains absent; `peek(at:)` returns `"b"`. A registered Observation callback did not fire.
- Read `/items/0`, set `"edited"` at `/items/00`: `value(at:)` remains `"a"`; `peek(at:)` returns `"edited"`.

Actual upstream `createStateStore` reads return the updated values in both cases.

Suggested fix: compute affected array locations from the actual mutation, including append and accepted index aliases, or refresh observed slots by comparing their values in the next snapshot. Use the same normalized affected paths for change-triggered validation.

### 4. Medium: editing one array item prevents later streamed items from being seeded

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Session/StateMerge.swift:8`.

The merge recurses through objects but treats an array as one leaf. Once the user changes any bound value inside an array, the entire current array wins over all later seed patches. Newly streamed array items and additional properties inside existing items disappear from live state. This breaks the documented promise that newly streamed state values merge while user-entered values survive.

Verified merge:

```json
oldSeed: {"items":[{"name":""}]}
current: {"items":[{"name":"typed"}]}
newSeed: {"items":[{"name":""},{"name":"new"}]}
result:  {"items":[{"name":"typed"}]}
```

Suggested fix: merge arrays recursively where indices still correspond to seeded items, with an explicit policy for user insertions/deletions. Track edited paths if positional comparison cannot distinguish those cases. Test streamed appends and properties added inside an edited item.

### 5. Medium: spec-only changes retain obsolete validation results and field state

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Session/FormSession.swift:58`.

For an unchanged root and seed, spec assignment never reconciles validation. Updating a validated field's checks or messages leaves the previous errors visible until another state change or validation request. Removing a field also leaves its validation object intact; reusing its pointer inherits the old touched/validated state and result.

Verified by validating `"abc"` against `minLength: 5`, then patching only checks to `minLength: 2`. The caption remained `"Need 5"`, although running the current config returned valid. Removing all elements and restoring the field retained `validated == true`.

Suggested fix: reconcile reachable fields and their configurations after each spec update. Clear state for removed/rebound fields and revalidate previously validated fields when their config changes. Define deliberate retention behavior for temporarily hidden fields separately.

### 6. Medium: resetting a watched path silently suppresses its watchers

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Session/FormSession.swift:122`.

`withoutFieldValidation` suppresses the entire state-change callback, including `fireWatchers`. `resetForm(statePath:)` thus changes a mounted element's watched value without dispatching its binding. Derived state outside the reset subtree stays inconsistent, for example resetting country without clearing its dependent city.

Verified that an ordinary `/name` change fired its watcher. After setting `/derived` to `"fresh"`, resetting only `/name` restored the initial name but left `/derived` as `"fresh"`, despite the same mounted watcher declaring a write of `"fired"`.

Suggested fix: suppress validation independently of watcher dispatch. Continue ignoring old-form watchers during root reseeding, using the lifecycle checks in finding 2.

### 7. Medium: Swift Unicode equality changes validation and drops real state writes

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Runtime/JSSemantics.swift:24`, `Model/JSONValue.swift:10`, and `Runtime/StateStore.swift:61`, under the same source root.

Swift string equality treats canonically equivalent Unicode sequences as equal; JavaScript `===` compares UTF-16 code units. Consequently `matches`, `equalTo`, `eq`, and `neq` disagree with core for composed versus decomposed text. Synthesized `JSONValue` equality also makes `StateStore` discard a normalization-only edit before storing it or notifying watchers.

Verified that `matches("é", "e\u0301")` returns true natively and false in actual upstream core. Setting a stored composed `"é"` to decomposed `"e\u0301"` left its UTF-16 representation at `[233]` instead of `[101, 769]`.

Suggested fix: use code-unit equality for runtime strings and state change detection. Audit synthesized equality and hashing where exact JSON string distinctions matter, including key storage.

### 8. Medium: container references from the same state location never compare equal

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Runtime/JSSemantics.swift:25`.

The assumption that containers reaching `strictEquals` are always distinct is false. Core resolves two references to the same state object/array to the same JavaScript reference. Native value copies lose that identity and always compare unequal. The README documents this behavior, but it conflicts with the architecture's core-parity requirement.

Verified with state `{"a":[1]}` and visibility `{"$state":"/a","eq":{"$state":"/a"}}`. Upstream returns true; Swift returns false, hiding the element. The corresponding `neq` is inverted as well.

Suggested fix: preserve state-container identity or reference provenance through expression/comparison evaluation. Do not replace reference equality with deep equality, since two separate equal-looking arrays must still compare unequal. Add same-reference and distinct-reference parity cases.

### 9. Medium: ICU patterns accept inputs rejected by core's JavaScript regexes

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Validation/Validation.swift:115`.

Passing the core pattern directly to `NSRegularExpression` changes its language. A common example is `\d`, which matches Unicode decimal digits in ICU but ASCII digits in JavaScript. Generated phone, PIN, and postal-code checks can therefore accept values rejected by the same spec in core. The README's ICU note describes the implementation but does not satisfy the parity contract.

Verified that `^\d{3}$` accepts `"١٢٣"` natively and fails in actual upstream `runValidationCheck`.

Suggested fix: provide an explicitly supported JavaScript-compatible regex subset with translation and rejection of unsupported syntax, or use a compatible regex implementation. Include character classes and anchor behavior in parity fixtures.

### 10. Medium: the URL validator accepts malformed file URLs without parsing them

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Validation/URLSyntax.swift:24`.

Every string with the `file:` scheme passes immediately. Invalid authorities, ports, and host syntax never reach validation. This is unrelated to the documented IDNA limitation and allows malformed values through a built-in check that core rejects.

Verified that `file://example.com:999999/x` passes Swift's `url` check and fails actual upstream `runValidationCheck`, whose `new URL(...)` throws.

Suggested fix: implement file URL parsing and authority restrictions rather than accepting the scheme alone. Add invalid ports, credentials, and malformed bracketed hosts to parity fixtures.

### 11. Medium: zone-less date-times shift by an hour on daylight-saving transition dates

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderSwiftUI/Components/ISODate.swift:42`.

The zone-less parser adds elapsed seconds to local midnight. On a day when the UTC offset changes after midnight, elapsed hours do not equal wall-clock hours. DatePicker selection and bounds consequently use the wrong time. The README explicitly supports local date-times without a zone.

Verified with a Gregorian calendar in `America/New_York`: parsing `2026-03-08T09:15` produces local 10:15; parsing `2026-11-01T09:15` produces local 08:15.

Suggested fix: parse and validate all date/time components, then construct the date through the calendar with an explicit policy for nonexistent/ambiguous local times. Avoid adding a duration to midnight.

## Verification and review limits

Both requested test routes passed, each reporting 54 tests in 11 suites:

```sh
cd swift/JSONRenderSwiftUI
xcrun swift test
xcodebuild -scheme JSONRenderSwiftUI \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test
```

Logs are `/tmp/json-render-swift-sdk-tests.log` and `/tmp/json-render-swift-sdk-ios-tests.log`. Additional probes compiled the actual model/runtime/session/action/validation/ISO-date Swift files into `/tmp/swift-sdk-review-probes`; source and output are `/tmp/swift-sdk-review-probes.swift` and `/tmp/swift-sdk-review-probes.log`. JavaScript parity counterexamples ran against a temporary esbuild bundle of the actual read-only upstream core sources, `/tmp/swift-sdk-upstream-probes.cjs`.

The existing pointer-observation test passes for ordinary independent object paths. Source inspection shows all catalog component types and listed props wired. The production Swift sources contain no `@unchecked Sendable` or `nonisolated(unsafe)` escapes. The bridge serializes calls through an actor, although its synchronous initializer loads/evaluates JavaScript on its caller. No measured bridge latency or concurrency defect is claimed here. Rendering tests are layout smoke tests; they do not establish keyboard/focus behavior, VoiceOver quality, or interactive re-render counts, and no finding above relies on an unverified claim about those behaviors.
