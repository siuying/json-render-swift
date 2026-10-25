# iOS demo review 2

Reviewed 2026-10-25. Scope is `ios/**`, concentrating on the Form/Document split, PDF previews and exports, provider settings, and the Anthropic client added since [the first review](ios-demo-review.md). The repository has no commits, so the earlier report is the baseline rather than a Git revision. SDK sources were read to understand APIs. No app or SDK source files were changed.

Six verified findings, all medium severity. The requested build and all 79 existing app tests passed.

## 1. Medium: streaming fallback discards output that the fallback model continues

**Location:** `ios/FormDemo/Models/GenerationController.swift:254-262`, triggered by `ios/FormDemo/Services/AnthropicClient.swift:80-81`.

**Scenario:** Claude emits some JSONL, then a `fallback` content block, then continues the JSONL on the fallback model. The client calls this a restart, and the controller disposes the compiler, clears its pending line and applied patches, and restores the pre-run spec. Anthropic's streaming contract preserves earlier output and continues from it. Only non-streaming fallback discards the declined attempt's output. See the [official fallback streaming documentation](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback#streaming).

This loses completed patches. A boundary inside a JSONL line also loses the beginning of that patch. New generations can lose their root and render nothing; follow-up edits can silently lose part of the requested change.

**Verification:** A scratch integration test used the real `AnthropicClient` with a stubbed HTTP/SSE response. It emitted a title patch, the documented `content_block_start` fallback shape with `from.model` and `to.model`, then an author patch and normal completion. The author changed, the title reverted, `patchCount` was 1 rather than 2, and no error appeared. Existing fallback tests assume the replacement model starts its output again, so they enforce the wrong streaming behavior.

**Fix:** Treat a server-side streaming fallback as a serving-model notification. Preserve the compiler, pending JSONL, raw text, patch count, and current spec. Keep the toast. Replace the restart tests with continuation cases, including a fallback inside an unfinished JSONL line.

## 2. Medium: an unowned final render can replace a newer PDF and erase edits

**Location:** `ios/FormDemo/Views/DocumentPreview.swift:30-32`; publication in `ios/FormDemo/Models/PDFPreviewModel.swift:66-73`.

**Scenario:** Stopping or completing a stream launches an unstructured `Task` to render its final spec. A slow image can keep that render suspended. Load another document, or Apply to state while the old render is pending. The new spec renders, and the user can edit its fields. The old task survives changes to the view's `.task(id: spec)` and later publishes its older document. Its equality guard only rejects the same spec; it accepts an obsolete different spec and overwrites the newer PDF, field metadata, and user edits. MainActor isolation does not prevent this ordering across awaits.

**Verification:** An injected image loader held the old render at an await. The same preview model then rendered a newer application spec, whose first name was edited to Alex. Releasing the old render replaced `renderedSpec` with the older spec and changed the PDF's first name back to Jane. The probe used the production model with no source changes.

**Fix:** Own the final render through the cancellable view task, with both spec and streaming status in its identity. Also track the latest requested render in the model and reject obsolete results before publication. Invalidate pending work on reset, even when the desired spec already equals the displayed spec. Read/apply controls should require a preview matching the current document revision.

## 3. Medium: Share PDF silently exports the original values instead of in-place edits

**Location:** `ios/FormDemo/Views/WorkspaceView.swift:150-151` and `ios/FormDemo/Services/PDFExport.swift:28-29`. The submission sheet has the same issue at `ios/FormDemo/Views/SubmissionSheet.swift:61-65` and `:125-133`.

**Scenario:** Edit fields directly in a fillable preview, then use Share PDF or Export as fillable PDF. Both actions create a fresh PDF from the spec. They never serialize the edited `PDFDocument`. The exported file therefore differs from the visible form. Read filled values confirms the edits exist, but Apply to state only helps bound fields. Unbound fields, such as the rental application's date of birth, have no way to reach the exported file. The submission preview also loses its edits when switching away from its tab because it owns its model inside that conditional view.

**Verification:** In the application fixture, changed first name from Jane to Alex and filled the unbound date of birth with `01/02/1990`. Reading the preview returned both edits. Running the exact `PDFExport(spec:)` path used by the toolbar and reading its output returned Jane and an empty date of birth.

**Fix:** Export a snapshot of the current edited document's `dataRepresentation()` when that preview matches the current spec. Hoist the submission preview model to the sheet so edits survive tab changes and are available to its export action. Use spec rendering for exports that have no edited preview.

## 4. Medium: Clear leaves the filled PDF cached and reuses it on reload

**Location:** `ios/FormDemo/Views/WorkspaceView.swift:53-56` and `:65-83`; deduplication in `ios/FormDemo/Models/PDFPreviewModel.swift:52-55`.

**Scenario:** Load the rental application, enter values, Clear, and load the same example again. Clear only resets the controller. `DocumentPreview` disappears when `hasSpec` becomes false, so its render task never calls `show(nil)` to reset the preview. The workspace retains the old `PDFPreviewModel`. Reloading the same spec then returns immediately because it equals `renderedSpec`, retaining the cleared document's edits. Read filled values and Apply to state can restore those old values into the fresh spec.

**Verification:** A simulator UI test filled Alex, opened Read filled values, dismissed it, used More → Clear and confirmed, verified the empty screen, and reloaded Rental Application (fillable). Read filled values still showed Alex. A model probe separately confirmed the reloaded spec's state contained Jane while the retained PDF contained Alex. A screenshot is attached to the UI test result.

**Fix:** Explicitly reset the PDF preview when clearing or replacing the document session, including cancellation/invalidation of pending renders. Keep rendering lifecycle observation outside the conditional preview, or give explicit document replacements an identity separate from spec equality.

## 5. Medium: suffix-based submitted-value lookup assigns one field's value to another

**Location:** `ios/FormDemo/Models/SubmissionSummary.swift:113-118`, also used by `ios/FormDemo/Models/FillablePDFMapper.swift:143-145`.

**Scenario:** A form has `/billing/email` and `/shipping/email`, and its submit action sends the `/shipping` subtree. `submittedValue` strips leading pointer segments until any suffix matches. It consequently assigns the submitted shipping email to both fields. The summary falsely lists an unsubmitted billing value, and the fillable mapper seeds the billing widget with the shipping address instead of using the real billing value from live state. The same ambiguity occurs within one submitted object when a nested field is absent but a top-level field has the same final name.

**Verification:** A scratch mapper test supplied live billing and shipping addresses and submitted only `{ "email": "shipping@example.com" }`. The summary included `Billing email: shipping@example.com`; the fillable spec's billing widget also contained that value. Both use the production lookup helper.

**Fix:** Carry the submit action's source state pointer or an explicit field-to-data mapping into the submission. Resolve against that known root once. Do not repeatedly strip segments per field. Omit fields outside the submitted subtree from the summary and use the documented live-state fallback for their fillable values.

## 6. Medium: context-window exhaustion is presented as successful generation

**Location:** `ios/FormDemo/Services/AnthropicClient.swift:82-89`.

**Scenario:** A large follow-up reaches the model's context-window limit. The Messages API returns `stop_reason: "model_context_window_exceeded"`, followed by `message_stop`. The app only handles refusal and max_tokens; it accepts this other truncation reason as normal completion. If at least one valid patch arrived, the controller validates the partial spec and returns to idle without explaining that the requested work was cut off. This is most likely when editing a large existing spec close to the input limit. Anthropic documents this reason as [truncated output](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons#model_context_window_exceeded).

**Verification:** A real-client/controller probe used a stubbed SSE response containing one valid edit patch, this stop reason in `message_delta`, and `message_stop`. The partial edit remained and `errorMessage` was nil.

**Fix:** Treat `model_context_window_exceeded` as a truncation error alongside `max_tokens`, with a useful explanation. Preserve already published patches, but do not report the stream as complete.

## Build and verification

The requested command passed without an SDK-related retry:

```sh
cd ios && xcodegen generate && xcodebuild \
  -project FormDemo.xcodeproj -scheme FormDemo \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  build test
```

Xcode 27.0, build 27A266a; XcodeGen 2.46.0; Swift 6 with complete strict concurrency. All 79 app tests in 10 suites passed. No app MainActor/Sendable diagnostic appeared. Log: `/tmp/ios-demo-review-2-build.log`.

Additional verification used an isolated app-source copy under `/tmp/ios-demo-review-2-probes/`, linked to the existing local SDK. All six tests in `FormDemoTests/Review2Probes.swift` passed by asserting the observed defective behavior. Their output is in `results.log`. The Clear/reload UI reproduction in `UITests/ClearReloadProbe.swift` also passed; output and its screenshot attachment are in `ui-results.log` and `DD/Logs/Test/Test-FormDemo-2026.10.25_14-53-13-+0000.xcresult`. App Swift files still matched that copy at the end of review. All provider requests in the probes used URLProtocol stubs; no live provider calls were made.

Other checks:

- Anthropic request headers, single user message, system prompt caching, optional `output_config.effort`, and the fallback parameter/beta header for Opus 5.5 and Sonnet 5.5 match the checked contract. No thinking, sampling parameters, or assistant prefill are encoded. All offered Claude efforts are listed for the preset models in the [official effort documentation](https://platform.claude.com/docs/en/build-with-claude/effort). Event parsing handles the stated fallback block shape, refusal explanation, max_tokens, usage-only message deltas, ping, stream errors, and early EOF. HTTP errors preserve API error text and distinguish authentication, rate limiting, overload, and server failures. Usage is ignored rather than accumulated, so cumulative token counts are not double-counted. Findings 1 and 6 cover the verified protocol failures.
- OpenAI still uses Responses with instructions, string input, stream enabled, store disabled, and optional reasoning effort. The offered low/medium/high values fit the GPT-6 presets checked against the [official GPT-6 guide](https://developers.openai.com/api/docs/guides/latest-model). Refusal events and empty follow-up edits are now reported. The earlier cancellation and validation-banner findings have regression coverage and passed.
- Separate controllers preserve Form and Document state. Provider/model/effort snapshots remain stable during a run, and settings/key persistence tests passed. The verified asynchronous preview failure is finding 2.
- `git check-ignore ios/Secrets.xcconfig` confirmed the ignore rule. The generated scheme contains build-setting references, with no literal keys. No local Secrets.xcconfig existed during this review. The built app bundle contained neither secret/config resources nor OpenAI/Anthropic key entries in Info.plist. No build path compiles the key settings into source. Keychain accounts are separate per provider and use `AfterFirstUnlockThisDeviceOnly`; no API-key logging path was found.
- Existing mapper tests verify SecureField masking in summaries, no password value in fillable specs, hidden fields, options, dates, and live-state fallback. They passed. The source-root ambiguity missed by those tests is finding 5.
- Visually inspected the document, streaming, JSON, filled-values, submission PDF/fillable, and both provider-settings screenshots in `docs/screenshots/`. They show no additional independently verified app defect. The edited-preview and export flow is covered by finding 3. PDF layout defects belong to the separate SDK review.
