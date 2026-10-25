# iOS demo review

Reviewed 2026-10-25 against the "Demo app" section of `docs/ARCHITECTURE.md`. Scope is `ios/**`; SDK sources were read only to understand the APIs. No app or SDK source files were changed.

Four verified findings: three medium, one low. No high-severity finding.

## 1. Medium: a cancelled run can still start an HTTP request

**Location:** `ios/FormDemo/Models/GenerationController.swift:158`, also lines 72-82 and 151-159.

**Failure scenario:** Start a generation and immediately stop it, clear the form, or replace it with another run before its task executes. `cancelRun()` cancels the task and changes `runID`, but `run()` does not check either before setup. The generation factory awaits prompt construction and then calls `generator.streamText(request)` even for an abandoned run. The live client starts an unstructured producer task as soon as that method is called. The first `runID` guard occurs only when consuming a chunk, after the HTTP request can already have started. The UI looks stopped while the cancelled operation can still initiate upstream generation.

**Verification:** In a scratch test on `MainActor`, call `generate()`, immediately call `stop()`, then await the returned task. The mock generator recorded one request. Repeating this with the real `OpenAIClient` and a holding `URLProtocol` recorded `startLoading()` in all **20 of 20** cancelled runs. This uses no OpenAI key or external request. Existing cancellation after a stream has started does work: cancelling its consumer invoked the protocol's `stopLoading()`.

**Suggested fix:** Check cancellation and run identity at the start of `run()` and after asynchronous preparation. In particular, check immediately before `generator.streamText(request)`, inside the factory after the prompt-building awaits. Keep the existing guards that prevent stale runs from publishing UI state.

## 2. Medium: a refused follow-up edit silently succeeds

**Location:** `ios/FormDemo/Services/ResponsesStreamEvent.swift:42` and `ios/FormDemo/Models/GenerationController.swift:191`.

**Failure scenario:** Load an existing form, then send an edit that the model refuses. Responses emits `response.refusal.delta` / `response.refusal.done`, followed by `response.completed`. Both refusal events fall through to `.ignored`, so the text stream finishes successfully without patches. The compiler was initialized with the current spec, so the final spec still has a root and passes the controller's "no form" check. The prompt disappears, activity returns to idle, the form stays unchanged, and no error or refusal explanation appears. The same silent outcome occurs for a prose-only follow-up with no patches.

**Verification:** A scratch integration test loaded the registration example and used the real client with a stubbed SSE response containing refusal delta/done and completion events. The result was `errorMessage == nil`, `patchCount == 0`, and an unchanged spec. These refusal event types and their payloads are documented in the [official Responses streaming reference](https://developers.openai.com/api/reference/resources/responses/streaming-events).

**Suggested fix:** Decode refusal events and propagate the refusal explanation to the controller. Also distinguish a completed edit that applied no patches from successful generation; checking whether the final spec has a root cannot detect this when the compiler starts with an existing form. Account for a valid final patch flushed by `finish()` when determining whether patches were applied.

## 3. Medium: Settings offers an unsupported effort for the default model

**Location:** `ios/FormDemo/Services/AppSettings.swift:10`, surfaced by `ios/FormDemo/Views/SettingsView.swift:58` and encoded by `ios/FormDemo/Services/OpenAIClient.swift:96`.

**Failure scenario:** Leave the model at the default `gpt-5.4`, choose "Minimal" reasoning effort, and generate. Settings offers this combination without qualification, and the client sends `"reasoning":{"effort":"minimal"}` unchanged. GPT-5.4's documented supported efforts are `none`, `low`, `medium`, `high`, and `xhigh`, so this produces an unsupported API request. The effort persists across launches, so the incompatible setting continues to affect subsequent generations.

**Verification:** A scratch settings/request test selected `minimal` and inspected the encoded body, confirming `model: "gpt-5.4"` together with `reasoning.effort: "minimal"`. The [official GPT-5.4 model page](https://developers.openai.com/api/docs/models/gpt-5.4) establishes the supported values. The unsupported combination was verified against that contract; no live API request was made.

**Suggested fix:** Offer model-compatible efforts for the suggested models, and reset or validate an incompatible saved effort when the model changes. For arbitrary model IDs, retain "Model default" as a usable fallback and make effort compatibility explicit. At minimum, remove `minimal` from the default model's options.

## 4. Low: the auto-repair banner cannot be dismissed

**Location:** `ios/FormDemo/Views/ContentView.swift:139` and `ios/FormDemo/Views/ContentView.swift:143`.

**Failure scenario:** Generate a spec that `autoFixSpec` repairs. The banner is visible whenever `didAutoFix` is true, but its Dismiss action only empties `issues`. `didAutoFix` remains true, so the banner immediately remains visible. The user cannot dismiss it until another load, clear, replay, or generation resets output. This also keeps the banner's space occupied above the prompt bar.

**Verification:** A scratch pipeline test generated a field with misplaced `props.visible`, confirmed `didAutoFix == true`, and executed the exact dismissal mutation, `controller.issues = []`. The banner's visibility expression remained true.

**Suggested fix:** Add a controller command that dismisses the validation presentation, including the auto-fix notice, or track banner dismissal separately from whether the latest spec was repaired.

## Build and verification

The requested command passed without an SDK-related retry:

```sh
cd ios && xcodegen generate && xcodebuild \
  -project FormDemo.xcodeproj -scheme FormDemo \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  build test
```

Xcode 27.0, build 27A266a, XcodeGen 2.46.0, Swift 6 language mode. **Build succeeded; all 28 app tests in five suites passed.** No app concurrency or Sendable diagnostic appeared. Build log: `/tmp/json-render-ios-demo-review-build.log`.

Additional probes used a separate project and app-source copy under `/tmp/ios-demo-review-probes/`, with the local SDK dependency. Tests are in `Tests/ReviewProbes.swift` and `UITests/ScrollProbe.swift`. The findings above intentionally fail assertions for the expected correct behavior; those failures are separate from the passing original suite. Probe output is in `results-2.log` and `results-3.log`.

Other checked behavior:

- Request construction sends `instructions`, string `input`, the configured `model`, `stream: true`, and `store: false`. The existing tests cover the request body, incremental SSE framing, Unicode/chunk boundaries, HTTP errors, response failure, incomplete/error event decoding, and a stream ending before completion.
- Progressive spec publication, current-spec/current-state follow-ups, validation/autofix, and replay pass the existing pipeline tests. MainActor isolation and run identity checks protect publication after the relevant awaits. The early request-start problem is finding 1.
- Keychain add, update, read, removal, whitespace trimming, environment fallback, and settings restoration passed a scratch round-trip test. New items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; write/delete errors propagate to the Settings alert. Keychain reads collapse errors into a missing result. No concrete user-visible read-error defect was reproduced. No API-key logging path was found in app source; the custom `log` action prints its form-action parameters.
- The rows visible underneath the prompt bar in `03-validation.png` and `04-event-rsvp.png` do **not** establish an unreachable last row. A simulator UI probe scrolled both forms to the bottom, including registration with validation errors. Both final submit buttons were hittable, at y=703.7 to 762.0 points, above the prompt text field at y=796.0. Tapping each button triggered field validation. The UI probe passed. Keyboard interaction and VoiceOver were inspected in code but were not exercised by this probe.

No live OpenAI call was made because no key was available. SDK implementation findings belong to its separate review.
