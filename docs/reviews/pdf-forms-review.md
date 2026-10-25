# PDF forms review

Reviewed 2026-10-25 against `docs/PDF-FORMS.md`, `docs/PDF.md`, and `docs/research-pdf-forms.md`. No source files were changed. `ios/` was excluded.

Seven verified source findings follow. P2 means a correctness or robustness defect that should be fixed before relying on the affected behavior. The JavaScriptCore and Core Graphics runtime results are recorded separately because the probes reproduce them outside the form writer or bridge.

## Findings

### 1. P2: The reserved button state `Off` produces duplicate dictionary keys and loses selections

Locations: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Forms/AcroFormWriter.swift:171` and `:196`; `packages/swiftui/src/pdf-forms-validate.ts:74`.

A checked Checkbox with `exportValue: "Off"`, or a RadioGroup option with `value: "Off"`, passes TypeScript validation. The writer uses the export token as an appearance-state key and also writes its built-in `/Off` key. Both controls therefore contain duplicate `/Off` entries. The off appearance wins, and the reader returns `false` for the checked checkbox and `null` for the selected radio.

Verified on macOS, iOS 26.2, and iOS 27. `qpdf --check off.pdf` exits 3 with two duplicate-key warnings. Strict pypdf rejects the file. `validate.log` shows `valid: true` for this input; `probe.log` shows the lost values.

Fix: reject reserved on-state tokens in validation and handle them defensively in native rendering, or assign distinct internal appearance-state names and map them to export values. Choice fields such as Select can still use the string `Off`; the restriction concerns button appearance states.

### 2. P2: Empty off-state appearance streams become invalid objects when PDFKit saves

Locations: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Forms/AcroFormWriter.swift:303` and `:311`.

Unchecked checkbox and radio appearances are zero-length streams. The generated files pass qpdf, but macOS 27.0.1 and iOS 27 PDFKit serialize these streams as empty indirect objects when `dataRepresentation()` saves the document. Even the one-option radio probe changes from a clean qpdf check to `empty object treated as null`. The application fixture produces twelve such warnings after an unedited PDFKit save.

Fix: emit a valid non-empty no-op appearance such as `q Q` for the off state. Verified the workaround by changing only the empty appearance stream in a temporary one-radio PDF, saving it through PDFKit, and obtaining qpdf exit 0. Add qpdf verification of the saved round-trip file; the existing check covers the original render only.

Artifacts: `one-radio.pdf`, `one-radio-saved.pdf`, `one-radio-nonempty-saved.pdf`, `repair_empty.py`, and `pdfkit-save.swift`.

### 3. P2: FieldSet names can collide with terminal field names

Locations: `packages/swiftui/src/pdf-forms-validate.ts:153`; `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Forms/FormComponents.swift:15` and `:129`.

Render a top-level TextInput named `person`, followed by a FieldSet named `person` containing TextInput `name`. Validation returns `valid: true`. FieldSet names never enter either uniqueness registry, so the PDF contains two different top-level fields with the fully qualified name `person`. Strict pypdf's field map replaces the text field with the non-terminal FieldSet: `get_fields()["person"]` has `/Kids` but loses the text field's `/FT` and `/V`. qpdf does not diagnose this semantic collision.

Fix: allocate and validate names for non-terminal and terminal fields in the same namespace. Native defensive renaming must also update descendant qualified names and returned metadata. Reject duplicate FieldSet instances unless they are deliberately merged into one field-tree node.

Artifacts: `scope-collision.pdf`, `duplicate-sets.pdf`, `inspection.log`, and `validate.log`.

### 4. P2: Invalid PDF value types and checkbox tokens become accepted state updates

Locations: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Forms/PDFFormReader.swift:166`, `:189`, and `:90`.

For a known text field, `/FT /Tx /V 42` becomes an empty string. For a known checkbox whose expected export value is `Yes`, `/FT /Btn /V /Unrecognized` becomes `true`. `values(for:)` accepts both conversions, and `stateUpdates` emits `("/user/text", "")` and `("/user/consent", true)`. An unexpected numeric choice value similarly becomes an accepted empty multiselect array. This can erase existing state or enable a consent flag despite the promised type/token validation.

The unexpected-type probe passes qpdf. The behavior also reproduces after converting it to object and xref streams with qpdf. This is independent of PDF syntax errors.

Fix: retain enough raw type and button-token information to distinguish an absent value from an invalid one. Reject unexpected text/choice types, and validate a checkbox's on token against its expected export value before converting it to Bool. Do not turn invalid input into a valid clearing update.

Artifacts: `unexpected-types.pdf`, `unexpected-types-xref-stream.pdf`, `reader_cases.py`, `read.swift`, and `reader.log`.

### 5. P2: The reader's field limit does not bound traversal work

Locations: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Forms/PDFFormReader.swift:136` and `:148`.

The global guard counts successfully collected values, while each `/Kids` array gets another independent 10,000-entry allowance. A 133,317-byte PDF with 1,000 parents pointing to one shared array of 10,000 repeated child references causes ten million child inspections. The child has no usable value, so the value count stays zero. The visited-node set prevents recursive revisits only after the caller has scanned and decoded the entire child array again.

Verified with `repeated-kids.pdf`: qpdf exits 0, and a standalone reader call takes 5.31 seconds on this host before returning an empty dictionary. Increasing the parent count remains within the existing root limit and multiplies that work. A synchronous import can therefore occupy a caller's thread for seconds on a small input.

Fix: share an operation budget across tree nodes, child-array entries, page annotations, and fallback traversal. Consume it before decoding or collecting child entries. Bound work even when nodes are malformed, duplicated, or have no values.

Artifact generator: `reader_budget.py`.

### 6. P2: `formFields` includes fields that do not exist in the output PDF

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Render/PDFRenderer.swift:132`.

Metadata comes from every model field, while the writer emits only fields with placements. A 200-field spec rendered with `maxPages: 1` returns 200 metadata entries but has only 21 widgets and 21 readable fields. An empty RadioGroup also returns a metadata entry despite producing no PDF field. If form writing throws, the same return statement still reports all fields after falling back to static frames.

Verified on macOS and both iOS runtimes. This breaks the contract of the returned list as a description and import mapping of the rendered form.

Fix: return metadata for successfully emitted terminal fields. Have the writer return the emitted field IDs, and return no form fields when the AcroForm update fails. Keep any desired diagnostics about omitted model fields in a separate report.

Artifacts: `truncated.pdf`, `empty.pdf`, and the platform probe logs.

### 7. P2: An oversized PageNumber footer can silently eliminate the form

Locations: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Render/PDFRenderer.swift:153`; `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Model/DocumentBuilder.swift:29`.

Footer height has no bound relative to page height. A valid spec containing one normal text field and a PageNumber with `fontSize: 500` and `format: "Footer ".repeat(30)` reserves about 66,000 points on an A4 page. The content rectangle falls back to one point high. Output contains two pages, no field widgets, footer text at large negative Y coordinates, and no warnings. The returned metadata still lists the missing field.

Verified on macOS, iOS 26.2, and iOS 27. The normal small-bottom-margin tests pass, but do not cover a footer taller than the page.

Fix: bound footer geometry while preserving usable page content. Clip, truncate, or reject an oversized footer with an explicit warning; do not let footer reservation collapse the content area silently.

Artifact: `huge-footer.pdf`; geometry is in the probe logs.

## JavaScriptCore investigation

The default iOS 26.2 package run crashed during `JSONRenderBridge.swift:59`, inside `JSRopeString::resolveToBuffer`, called by RegExp construction during `evaluateScript`. The PDF test process completed its 49 tests, while the other test host crashed and the build stalled. I interrupted the stalled build. The crash report is `xctest-2026-10-25-143155.ips` under `~/Library/Logs/DiagnosticReports`.

I found no demonstrated cross-VM value transfer, exported Swift closure retaining a JSValue, or concurrent bridge access. Context construction uses the shared queue at line 54; actor calls use that executor; only decoded JSON leaves invocation. Strong `context` and `api` properties retain their JS objects. Queue thread hopping alone is supported: [Apple's JSVirtualMachine documentation](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine) explicitly permits API calls from any thread and documents VM-level locking.

Temporary test packages have no project module imports and use only Foundation, JavaScriptCore, and Swift Testing. They load the bridge JavaScript as input, so this isolates the native host rather than reducing the JavaScript bundle:

| Probe | iOS 26.2 | iOS 27 |
| --- | --- | --- |
| Main-thread contexts, 20 parameterized cases with 20 evaluations each | Passed | Not rerun |
| Worker cases, separate VM/context per case, no values shared between cases | Crashed across all three test-host launches | Passed |
| One shared VM, every JS operation inside one serial queue, no JS objects escape the queue closure | Crashed during script evaluation | Passed |
| Same worker or serialized stress tests with concurrent JIT disabled | Still crashed | Not needed |

The worker crash reports include `JSC::CodeOrigin::approximateHash` on a JIT helper and `JSRopeString::resolveToBuffer` on a worker. The serialized probe traps in generated JavaScript code beneath `evaluateScript`, at `SerialTests.swift:13`. Its crash report is `xctest-2026-10-25-143836.ips`.

The real package suite passed once with `TEST_RUNNER_JSC_useConcurrentJIT=false`, but the isolated stress failures show that this is not a complete workaround. The supported, serialized minimal host also fails, so the evidence points to the iOS 26.2 simulator's JSC runtime rather than a demonstrated bridge ownership/threading defect. This does not establish an affected physical-device version or identify an exact WebKit defect. Main-thread confinement passed the minimal probes and is a candidate workaround to validate in the real test suite. A shared queue alone does not solve the runtime failure.

Reproducers and logs: `/tmp/pdf-forms-review/jsc-package`, `jsc-serial-package`, `jsc-xctest26-workers.log`, `jsc-serial-xctest26.log`, `jsc-serial26-no-jit.log`, `jsc-workers27.log`, and `jsc-serial27.log`. Standalone command-line evaluation probes also passed; they did not reproduce the test-host failure.

## Core Graphics xref limitation found on iOS

The special-character probe has another qpdf warning on both iOS runtimes: an unused object is marked in-use with offset zero in the original CG xref table. The warning already exists in the base PDF before the incremental update. A minimal static Text containing `漢字` reproduces it without any AcroForm; a text field with an ASCII label and CJK/emoji only in its value passes qpdf. This is separate from the writer's string escaping.

On iOS, `unicode-label.pdf` and `unicode-static.pdf` warn about object 6; `special.pdf` warns about object 7. Those slots are unreferenced in the inspected base file. Marking the zero-offset slot free in a temporary copy makes qpdf pass. Treat this as an outstanding portability/check-gate limitation: exercise iOS-generated artifacts with host qpdf, and either avoid the affected CG font path or safely repair these proven unused slots. It is not evidence of an offset calculation error in the incremental update.

## Verification and coverage

Environment: macOS 27.0.1, build 26A434; Apple Swift 6.4; installed iOS 26.2 and 27.0 simulators. Python pypdf 6.21.2 was installed in a temporary virtual environment. `mutool` and `pdftk` were unavailable.

| Requested check | Result |
| --- | --- |
| `cd swift/JSONRenderSwiftUI && xcrun swift test` | Passed, 81 runtime tests and 50 PDF tests |
| `xcodebuild -scheme JSONRenderSwiftUI-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test` | Passed, 81 runtime tests and 49 PDF tests |
| `pnpm -r test` | Passed, 214 tests |
| iOS 26.2 package suite, defaults | JSC crash and stalled build, as described above |
| iOS 26.2 package suite, `TEST_RUNNER_JSC_useConcurrentJIT=false` | Passed, 81 runtime tests and 49 PDF tests |

The standalone Swift renderer probe was linked against the built package on macOS and both simulators. Every renderer-probe output was opened with PDFKit and CGPDFDocument; handcrafted reader inputs went through the CG-based reader. Host checks used `qpdf --check`, `qpdf --json`, `qpdf --qdf --object-streams=disable`, and strict pypdf field inspection, including saved variants. Exceptions to a clean check are identified above; PDFKit also drops the AcroForm tree and multiselect values in the iOS 26.2 saved fixture, consistent with the existing test's OS-specific limitation.

The application fixture has 31 terminal fields and 38 widgets. Across all three platforms, explicit checks verified every xref object's offset against its `n g obj` header, the `/Prev` pointer to the original table, generation-zero live objects, page references, widget rectangles, and appearance `/BBox` and font resources. All three observed CG outputs use classic xref tables and PDF 1.3. General xref-stream or nonzero-generation *writing* is unsupported; those formats were not emitted by the tested CG contexts, so I did not report that scoped limitation as a writer bug. The reader successfully opened a qpdf-produced xref/object-stream variation.

The 200-field probe produces ten pages and preserves all fields. Repeat names and `$bindItem` mappings resolve to `guest_one` / `/people/0/email` and `guest_two` / `/people/1/email`. A combined link, decoded image, and form probe preserves both `/Link` and `/Widget` annotations. Parentheses, backslashes, accented text, CJK, and emoji round-trip in `/T`, `/V`, and choice `/Opt`; non-ASCII dictionary text is BOM-prefixed UTF-16BE. `/TU` follows the renderer's existing label normalization. One-option radio and 2,000-option list probes parse. Empty radio options expose finding 6.

Reader probes also cover cyclic parent/kid references, duplicate field names, malformed value types, a 200,000-character value, and a field named `/admin/role`. Cycles terminate, the large text is capped at 100,000 characters, and the pointer-shaped field name produces no new state pointer: updates use only the supplied trusted metadata. Duplicate terminal names currently use the first value. The verified type-coercion and work-budget defects are findings 4 and 5.

All six fixtures and the many-field probe had no footer/content intersections. Field geometry and text alignment pass the existing dictionary/layout tests and the fixture inspection. An oversized label probe also confirms the current generic pagination fallback can split a label across pages before placing its widget; strict label/widget grouping therefore has an oversized-content limit. Ordinary labels and widgets stayed together, and no individual widget split.

PDFKit rasterizations and a Quick Look thumbnail of the application fixture were generated and inspected. The application fixture's fields, selected controls, alignment, and footer render correctly. The existing fallback-loader test passes for bundled data, data URLs, and failure fallback; no additional source defect was established there. Form prompt guidance covers scoped names, choices, state prefills, repeated names, and layout; the actionable catalog gaps are reflected in the findings.

All temporary sources, PDFs, QDF/JSON dumps, images, and logs are under `/tmp/pdf-forms-review/`, except package-suite logs under `/tmp/pdf-review-*.log`. Reproduction entry points are `probe.swift`, `validate.ts`, `reader_cases.py`, `reader_budget.py`, `check_pdfs.py`, and `check_structure.py`.
