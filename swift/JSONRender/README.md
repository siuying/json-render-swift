# JSONRender

The Swift package of json-render for Swift. It has two libraries:

- `JSONRenderSwiftUI`: native SwiftUI renderer and runtime for [json-render](https://github.com/vercel-labs/json-render)
  form specs. An LLM generates a spec against the `@json-render/swift` catalog; the library renders it with
  real SwiftUI controls, two-way state binding, validation, visibility rules and actions.
- `JSONRenderPDF`: lays out and paginates documents built from the PDF catalog
  (see [PDF documents](#pdf-documents-jsonrenderpdf)).

- **Native hot path**: state store, expressions, visibility, validation and action dispatch are Swift. They
  match `@json-render/core` semantics, and the parity fixtures generated from core check that.
- **JavaScriptCore for the rest**: system prompt, user (edit) prompt, catalog manifest, spec validation and
  autofix, and the JSONL patch stream compiler come from the bundled `json-render-bridge.js`.

Requirements: iOS 26 / macOS 26, Swift 6 language mode, no third-party dependencies.

```swift
.package(path: "../swift/JSONRender")   // then depend on "JSONRenderSwiftUI" (and "JSONRenderPDF")
```

## Quick start

```swift
import JSONRenderSwiftUI
import SwiftUI

struct SignUpScreen: View {
    @State private var session = FormSession(spec: try! Spec(jsonString: specJSON))
    @State private var submitted: JSONValue?

    var body: some View {
        NavigationStack {
            JSONRenderView(session: session)
                // Runs only after every visible field passes validation.
                .onJSONRenderAction("submit") { params, session in
                    submitted = params["data"]
                }
        }
    }
}
```

## Streaming from an LLM

```swift
let bridge = try JSONRenderBridge()                       // loads the bundled JS once; keep it around
let system = try await bridge.systemPrompt()              // catalog.prompt()
let user = try await bridge.buildUserPrompt(prompt, currentSpec: session.spec, state: session.store.state)

let compiler = try await bridge.makeStreamCompiler()
do {
    for try await chunk in llmTextStream {                // arbitrary chunk boundaries are fine
        let update = try await compiler.push(chunk)
        if !update.newPatches.isEmpty { session.spec = update.spec }
    }
    session.spec = try await compiler.finish()            // flushes the last line and frees the compiler
} catch {
    await compiler.dispose()                              // cancelled/failed: free without flushing
}

// .valid, .issues [{severity, message, path, code}]; host actions/validators aren't reported as unknown
let report = try await bridge.validateSpec(session.spec!, hostActions: ["track"], hostValidators: ["postalCode"])
```

You can assign `session.spec` on every patch. A partial spec renders whatever has arrived so far, and
missing child keys are skipped. State is re-seeded from `spec.state` only when `root` changes; that also
clears validation and cancels pending `watch` chains. Otherwise newly streamed state is merged in and
values the user has already entered are kept:

- A value still equal to what was last seeded takes the new seed.
- Objects merge key by key; keys only the user added are kept.
- Arrays merge by index for previously seeded positions. Newly streamed seed items (beyond the previously
  seeded length) are appended after the live items, so user-added and user-removed items are respected.
- Any other value the user edited wins.

Seeding and merging do not fire `watch` bindings or change-validation. After a same-root update,
validated fields re-validate against their possibly changed checks. Fields no longer in the spec (removed
or rebound) lose their validation state; hidden-but-present fields keep it.

## Public API

| Type | Purpose |
|---|---|
| `FormSession` (`@Observable`, `@MainActor`) | Owns `store`, `validation`, `actions`. Holds `spec`, `initialState`, `alert`, `confirmation`, `runningActions`. Methods: `validateAll()`, `validate(_:)`, `visibleFields`, `fieldDidBlur(_:)`, `resetForm(statePath:value:)`, `emit(_:from:)`, `perform(_:params:)`, `resolveConfirmation(_:)`. `validators:` adds custom check types. |
| `JSONRenderView(session:)` | Renders the spec and presents `showAlert` and `confirm` dialogs. |
| `.onJSONRenderAction(_:perform:)` | Host handler for an action name (`submit` or a custom action). Signature: `(params: [String: JSONValue], session: FormSession) async throws`. Environment handlers attach when the `JSONRenderView` first renders; for actions performed before that (e.g. `session.perform` in tests) register on the session with `session.actions.register`. |
| `.jsonRenderComponent(_:content:)` / `.jsonRenderRegistry(_:)` | Override or add component renderers by type name. |
| `ComponentRegistry` | `.standard`, `register(_:content:)`, `registering(_:content:)`, `renderer(for:)`. |
| `FieldContainer(context:control:)` / `FieldTitle(text:)` | The built-in field chrome (inline red error caption, caption-style title) for custom input components. |
| `ComponentContext` | Passed to renderers: `props` (resolved, typed accessors), `binding(_:)`, `emit(_:)`, `children`, `errors`, `field`, `didFinishEditing()`, `session`, `element`. |
| `ActionDispatcher` (`session.actions`) | `register(_:handler:)`, `unregister(_:)`, `dispatch(_:)`. |
| `StateStore` (`session.store`) | `value(at:)` (observes one pointer), `peek(at:)`, `state` (observes everything), `set(_:at:)`, `update(_:)`, `replace(with:)`, `addObserver(_:)`. |
| `Spec`, `Element`, `ActionBinding`, `ActionConfirm`, `JSONValue` | Tolerant models. `Spec(json:)` never fails, and `spec.json` keeps the raw document. `JSONValue.jsonString(prettyPrinted:)` writes sorted keys, JS-style numbers, and in pretty mode two-space indentation, `"key": value`, and `[]`/`{}` for empty containers. |
| `Expressions`, `Visibility`, `Validation`, `JSONPointer` | Pure core-parity functions: `resolve`, `resolveProps`, `bindings`, `evaluate`, `run`, `runCheck`, `builtInFunctions`, `value(at:)`, `setting(_:at:)`. |
| `ValidationConfig`, `ValidationCheck`, `ValidationResult`, `FieldValidation`, `FormField` | Validation types and per-field `touched`, `validated` and `result`. |
| `JSONRenderBridge` (actor) | `init()` (bundled script) or `init(script:sourceURL:)` (an app's own bundle). `version()`, `systemPrompt(customRules:mode:catalog:)`, `buildUserPrompt(_:currentSpec:state:maxPromptLength:)`, `catalogManifest(catalog:)`, `jsonSchema(strict:catalog:)`, `validateSpec(_:hostActions:hostValidators:catalog:)`, `autoFixSpec(_:catalog:)`, `makeStreamCompiler(initial:)`. JS exceptions are thrown as `JSONRenderBridgeError.javaScript`. |
| `JSONRenderBridge.Catalog` | The catalog a call targets, by name: `.swiftui` (the default) and `.pdf` are built in. An open `RawRepresentable` struct: apps add their own names with `Catalog("database")` or a string literal (see [Custom catalogs](#custom-catalogs)). `allCases` is the built-ins only; `init?(rawValue:)` never fails. A name the script doesn't know throws `.javaScript` (`Unknown catalog: …`). It used to be an enum, so an exhaustive `switch` over it now needs a `default` case. |
| `SpecStreamCompiler` | `push(_:) -> Update(spec, newPatches)`, `finish() -> Spec`, `dispose()` (free without flushing; idempotent). A compiler released without `finish`/`dispose` is disposed automatically. |

### Custom components

```swift
JSONRenderView(session: session)
    .jsonRenderComponent("Rating") { context in
        RatingView(stars: context.binding("value"), label: context.props.string("label") ?? "")
    }
    .jsonRenderComponent("Text") { context in      // override a standard component
        Text(context.props.string("content") ?? "").font(.body.monospaced())
    }
```

Container components render `context.children`. Inputs should wrap their control with an error caption
from `context.errors` and call `context.didFinishEditing()` when editing ends, so `validateOn: "blur"`
works.

### Custom catalogs

The bundled `json-render-bridge.js` knows the `swiftui` and `pdf` catalogs. An app with catalogs of its own
(any `defineCatalog` catalog with a `{ root, elements, state? }` spec) builds its own bridge bundle from
`@json-render/swift/bridge` and loads it instead. The entry file:

```ts
// bridge-entry.ts
import { installBridge } from "@json-render/swift/bridge";
import { databaseCatalog } from "./database-catalog";

installBridge({ catalogs: { database: databaseCatalog } });
```

`installBridge` adds the catalogs after the built-ins, installs `globalThis.JSONRenderBridge` and returns
it. A name that is already built in (`swiftui`, `pdf`) throws. Importing the module installs nothing, so
the entry decides. Bundle it with esbuild for a bare `JSContext`:

```js
// build-bridge.mjs
import { build } from "esbuild";

await build({
  entryPoints: ["bridge-entry.ts"],
  outfile: "dist/database-bridge.js",
  bundle: true,
  format: "iife",                       // a script, not a module
  platform: "neutral",                  // no Node or browser globals
  mainFields: ["module", "main"],
  target: "safari18",
  minify: true,
  define: { "process.env.NODE_ENV": '"production"' },
  // JavaScriptCore has no console unless the host installs one.
  banner: {
    js: 'if (typeof globalThis.console === "undefined") globalThis.console = { log() {}, info() {}, warn() {}, error() {}, debug() {} };',
  },
});
```

Code in the bundle must not use `fetch`, `URL`, `TextEncoder`, `structuredClone`, timers or `process`.
The bundle is about 540 KB; the `zodEnglishOnly` plugin in `packages/swift/scripts/build-bridge.mjs`
drops zod's non-English messages and brings it down to about 285 KB. Add the file to the app target and
name the catalog in Swift:

```swift
extension JSONRenderBridge.Catalog {
    static let database: Self = "database"
}

let url = Bundle.main.url(forResource: "database-bridge", withExtension: "js")!
let bridge = try JSONRenderBridge(script: String(contentsOf: url, encoding: .utf8), sourceURL: url)
let system = try await bridge.systemPrompt(catalog: .database)
let report = try await bridge.validateSpec(spec, catalog: .database)
```

`systemPrompt`, `catalogManifest`, `jsonSchema`, `validateSpec` and `autoFixSpec` all take the custom
catalog; validation follows the element fields (`on`, `watch`, `repeat`) its schema declares. Render
its component types with `.jsonRenderComponent` / `.jsonRenderRegistry`.

### Actions

| Action | Behavior |
|---|---|
| `setState` / `pushState` / `removeState` | Built in. `pushState` also supports `clearStatePath` and `"$id"` tokens, like RN. |
| `resetForm` | With no params, restores `initialState` and clears validation. With `statePath`, writes `value` (or the initial value) at that path and clears validation under it. |
| `submit` | Validates every visible field that has `checks`. If any fail, errors appear and dispatch stops. Otherwise the host `submit` handler runs with the resolved params. |
| `showAlert` / `openURL` | Built in, and hosts can override them by registering a handler with the same name. |
| anything else | Host handler if registered. Otherwise it is logged (`os.Logger`, subsystem `JSONRenderSwiftUI`) and ignored. |

`openURL` uses `session.urlOpener` if set, else the SwiftUI environment's `openURL` (once a
`JSONRenderView` has rendered), else the system (`UIApplication` / `NSWorkspace`).
`session.runningActions` lists an action until every concurrent run of it has finished.

Params are resolved against live state, so in a binding array later actions see earlier writes. A chain
stops when `submit` fails validation, a confirmation is cancelled, or a handler throws without `onError`.
`confirm`
shows a confirmation alert (`variant: "danger"` makes the confirm button destructive). `onSuccess` and
`onError` support `{ "set": {...} }` (including `"$error.message"`) and `{ "action", "params" }`.
`watch` bindings fire when a watched pointer changes (including through `resetForm`), for mounted
(visible) elements only. Each element runs one chain at a time: a newer change cancels the older chain,
and a chain stops after any suspension once its element is removed or hidden, or a new root is loaded.

### Validation UX

A field is an element with `checks` and a `$bindState` value prop (`value`, `isOn` or `selection`).
Validation state is keyed by the bound pointer.

- `validateOn` defaults to `"submit"`. `"blur"` runs when a text field loses focus; other controls count
  each committed change as a blur. `"change"` runs on every value change.
- Once a field has been validated, it re-validates on every state change. Errors clear as soon as the
  input is fixed, and cross-field checks such as `matches` stay current.
- Hidden fields are skipped. The first error shows as a red caption under the control.

## PDF documents (`JSONRenderPDF`)

A second product renders specs built from the `@json-render/react-pdf` standard catalog (Document,
Page, View, Row, Column, Heading, Text, Image, Link, Table, List, Divider, Spacer, PageNumber) to PDF
natively. It uses Core Text for measurement and drawing, a Core Graphics PDF context for output, and
PDFKit for the preview. It runs on iOS 26 and macOS 26.

```swift
import JSONRenderPDF

let renderer = PDFRenderer(options: .init(
    state: ["customer": "Ada"],          // shallowly overrides spec.state keys (react-pdf renderToBuffer)
    imageLoader: .default,               // http(s) + data: only; failures draw a placeholder
    maxPages: 500                        // longer documents are truncated (see renderResult)
))
let data: Data = try await renderer.render(spec)
let document: PDFDocument = try await renderer.document(for: spec)
let result = try await renderer.renderResult(spec)   // data, pageCount, warnings, isTruncated

JSONRenderPDFView(spec: spec)            // PDFKit preview; re-renders when `spec` changes
    .onPDFRender { result in lastPDF = try? result.get() }

// Prompting and validation use the PDF catalog through the bridge:
let system = try await bridge.systemPrompt(catalog: .pdf)
let report = try await bridge.validateSpec(spec, catalog: .pdf)
```

| API | Notes |
|---|---|
| `PDFRenderer(options:)` | `render(_:) -> Data` and `document(for:) -> PDFDocument`. The pipeline is resolve → load images → measure → paginate → draw. Pagination finishes before drawing, so `PageNumber` knows the total. `PDFRenderer.componentTypes` lists the supported types. |
| `PDFRenderer.Options` | `state`, `imageLoader`, `imageTimeout` (default 10 s), `imageLimits`, `maxPages` (default 500). |
| `PDFRenderResult` / `PDFRenderWarning` | From `renderResult(_:)`: what was dropped (nesting deeper than 32 levels, more than 20,000 elements), clipped, truncated at `maxPages`, or replaced by an image placeholder. |
| `PDFImageLoader` | `.default` (= `.http()`: streamed `http(s)` and `data:` URLs, 10 MB each), `.files(in: directory)` (opt-in local files inside one directory), `.placeholders` (no loading, deterministic), or `PDFImageLoader { source in Data }`. `loader.fallback(.default)` tries a custom loader first and falls back to another. The default never reads local files. A thrown error, undecodable bytes, a timeout or an exceeded budget draws a grey placeholder box; rendering never fails because of an image. Loaders should honour cancellation; the deadline does not wait for them. |
| `PDFImageLimits` | Bytes per image (10 MB) and per document (50 MB), decoded pixels per image (40 MP), concurrent loads (4), and the longest side images are downsampled to before drawing (2048 px). |
| `JSONRenderPDFView(spec:options:id:)` | SwiftUI preview. It keeps the last good document and the current page while a new render runs. It re-renders when the spec, `options.state`, timeout, limits or page cap change; pass `id` for changes it can't compare, such as a new loader. Debouncing streamed updates is up to the host. |
| `JSONRenderBridge.Catalog` | `.swiftui` (default), `.pdf` or a [custom catalog](#custom-catalogs), accepted by `systemPrompt`, `catalogManifest`, `jsonSchema`, `validateSpec` and `autoFixSpec`. |

Rendering checks for task cancellation between stages and pages and throws `CancellationError`.
Numeric props are clamped to finite ranges (negative lengths become 0, and page margins leave at least
a third of the page). Partial (streaming) specs render without throwing. Missing children, unknown types and cycles are
skipped, and an empty spec gives one blank A4 page. Document `title`, `author` and `subject` become PDF
metadata. `Link` produces URL annotations.

### Fillable forms

`FieldSet`, `TextInput`, `Checkbox`, `RadioGroup`, `Select` and `ListBox` produce real AcroForm fields
that Preview, PDFKit's `PDFView` and Acrobat can fill. Labels are drawn as static text above the widget
(placeholders as a grey hint next to the label), each field's label and widget move between pages
together, and widgets never split. Field names are the enclosing `FieldSet` names and the field name
joined with "."; a repeated full name gets `#2`, `#3`…

```swift
let result = try await PDFRenderer().renderResult(spec)
result.formFields      // [PDFFormFieldInfo]: name, type, value, pointer, options, flags…

// Later, with a PDF the user filled in (PDFView, Preview, Acrobat…):
let reader = try PDFFormReader(data: filledPDF)
let values = reader.values(for: result.formFields)         // validated: [name: JSONValue]
for update in PDFFormReader.stateUpdates(values, fields: result.formFields) {
    session.store.set(update.value, at: update.pointer)      // fields bound with $state/$bindState/$bindItem
}
```

| API | Notes |
|---|---|
| `PDFRenderResult.formFields` | `PDFFormFieldInfo` per field, in document order: fully qualified `name`, `type` (`PDFFormFieldType`), the written `value` (string, bool or `[String]`), the bound state `pointer`, `options` (`PDFFormOption` label/value), `isRequired`, `isReadOnly`, `allowsMultipleSelection`, `isEditable`, `maxLength`, `exportValue`. |
| `PDFFormReader(data:)` | Reads a filled PDF: text → string, checkbox → bool, radio/select → export value, multi-select list → `[String]`. `values(for:)` keeps only known fields whose stored value has the expected PDF type: text strings (cut to `maxLength`), a checkbox on with its own export state or off, radio/choice tokens that are options (a list with any unknown token is dropped whole). Invalid values are dropped, never turned into clearing updates. `values()` returns everything raw. `stateUpdates(_:fields:)` pairs values with their bound pointers. The PDF is untrusted: traversal shares one 200,000-operation budget (nodes, kid entries, annotations), depth 32, strings 100,000 characters. |

How the form is written: the page content (labels, field frames) is drawn by Core Graphics as usual, and
the form is then appended to that PDF as an **incremental update** by a small writer in this package. It
holds the catalog `/AcroForm` (`/Fields`, `/NeedAppearances true`, `/DR` with Helvetica and ZapfDingbats,
`/DA`), a field tree with FieldSets as non-terminal fields, one parent field per radio group with a widget
kid per option, field flags, `/MaxLen`, `/Q`, `/Opt` export/label pairs, `/MK`, and appearance streams
for every widget (check marks, radio dots, current text/choice values). Button appearance states are
named after export values, except that the reserved `Off` (and duplicates) get unique names such as
`Off_1`; the reader maps them back. `formFields` lists exactly the fields written (not those cut by
`maxPages`, nor a RadioGroup without options). PDFKit's own
`dataRepresentation()` writes widgets without the `/AcroForm` root and radio parents, which is why it is
not used for writing. Output passes `qpdf --check`. On iOS, Core Graphics can leave an unused object
marked in use at offset 0 when it embeds CJK fonts; the renderer frees such slots (only when nothing
references them) in its incremental update, also for documents without fields.

Viewer notes: PDFKit (and so Preview) draws list boxes itself without scrolling, so a list's font size
is reduced until every option fits its box. When PDFKit saves an edited form it rewrites the field tree in its own way. Button states may end up
as strings in `/V` on the widgets, radio flags may move to the kid widgets, and names may be flattened
to full dotted names; `PDFFormReader` reads all of these as well as the standard form. PDFKit before
iOS/macOS 27 drops multi-select list values when it saves, and its text extraction inserts spaces
between tightly kerned letters (the drawn text is unaffected). PDFKit draws choice widgets itself and
highlights only one selected row, so a multi-select list with several preselected values shows none
highlighted there; the PDF still carries every selection (`/V` array, `/I` indices and a highlighted
appearance stream used by other viewers), and `PDFFormReader` returns them all.

### Fidelity with react-pdf

The renderer reproduces react-pdf's own text model rather than Core Text's defaults:

- **Metrics.** Glyph advances and pair kerning come from the Adobe Helvetica AFM files pdfkit uses
  (`Resources/helvetica-metrics.json`). The line box is 1.1 × font size (or `lineHeight` × size), with
  the baseline at 0.9 × size, which is react-pdf's `StandardFont` ascent of 900 and descent of −200.
- **Line breaking.** This is a port of textkit's: paragraphs split at newlines, words split into en-US
  Liang syllables (`Resources/hyphenation-en-us.json`, the `@react-pdf/hyphenate` patterns), and
  Knuth & Plass decides the breaks with textkit's glue, penalty and tolerance values. On the four
  upstream examples, every line breaks and hyphenates exactly as in the reference renders, and line
  positions match to about 0.01 pt.
- **Component recipes.** Heading sizes and margins, table padding and colours, list markers, divider and
  spacer defaults, `Link` styling and emoji stripping all match `components/standard.tsx`.
- **`repeat`.** `repeat`, `$item`, `$index` and `$bindItem` resolve through the shared runtime and pass
  the parity fixtures (`fixtures/parity/repeat.json`, including react-pdf's `renderToBuffer` element walk).

Pagination:

- Text splits between lines.
- Rows (and each visual line of a wrapped Row) move to the next page whole when they fit on one; taller
  rows split every child at the same cut.
- Views, Columns and Lists move whole only when they are at most a third of the page tall. Taller ones
  flow, splitting between children; moving every View that fits left pages nearly blank.
- Tables split only between rows and repeat their header row on each continuation page. A row taller
  than a page is split across pages under the repeated header.
- Every page makes progress. Unsplittable oversized content is clipped (images are scaled) and
  reported as a `contentClipped` warning.
- A Column with a definite height (the page area, or a container stretched by its Row) gives extra
  space to `flex` children and applies `justifyContent`.
- `PageNumber` is a page footer: it is drawn on every page inside the bottom margin, wherever it sits
  in the element tree, and takes no flow space. `align` is relative to the content width. If the bottom
  margin is too small, the footer reserve grows so the number never overlaps content. Only the first
  `{pageNumber}` / `{totalPages}` is replaced, with real totals.

Known differences from react-pdf:

- **Overflow compression.** When content overflows a page, yoga flex-shrinks it slightly before
  react-pdf paginates (about 2% in the statement fixture). The native renderer keeps natural heights,
  so a page break can land one row earlier: statement page 1 ends at "Mar 27", upstream at "Mar 28".
- **Table headers.** Upstream neither repeats table headers nor keeps rows together.
- **Keep-together threshold.** Upstream splits Views freely; small Views (up to a third of a page) move
  whole here.
- **Narrow boxes.** Text in a box narrower than half a point is not drawn, and text is clipped to its
  box, where upstream lets glyphs spill into the neighbouring column.
- **Overflowing lines.** Knuth & Plass may pick a line up to its shrink limit. Native rendering narrows
  that line's spaces evenly; textkit's justification engine can also tighten letter spacing.
- **Fonts.** Core Text's Helvetica outlines are embedded as a subset, whereas react-pdf references the
  non-embedded standard-14 Helvetica. Characters outside WinAnsi fall back to Core Text fonts instead
  of rendering as missing glyphs.
- **Long words.** A word wider than its box is cut to fit, where react-pdf lets it overflow.
- **No orphan/widow control.** A paragraph may leave a single line at the bottom of a page.
- **Images.** Images load through the injectable loader, and their natural pixel size is used as points.

Regenerate the metric and pattern resources from a pnpm install with
`node scripts/gen-helvetica-metrics.cjs <pdfkit>` and
`node scripts/gen-hyphenation-patterns.cjs <hyphen>`.
Screenshots of each fixture's first page (and first continuation page) are in `docs/screenshots/pdf/`.
Regenerate them with
`JSONRENDER_PDF_SCREENSHOTS=1 xcrun swift test --filter PDFScreenshots` and compare them with
`fixtures/pdf/reference/*.png`.

## Semantics notes

- Absent values (JS `undefined`) are `Optional<JSONValue>.none`. JSON `null` is `.null`.
- `eq`/`neq`/`matches` use JS `===`. Strings compare by UTF-16 code units (so `"é"` ≠ `"e\u0301"`), and
  so does `JSONValue` equality and state change detection. Arrays and objects are equal only when both
  sides read the same state location (`{"$state": "/a", "eq": {"$state": "/a"}}`), matching core's
  reference equality; distinct containers never compare equal, even if they look alike. Object keys are
  stored in a Swift `Dictionary`, so keys differing only by Unicode normalization collide.
- Strings use UTF-16 lengths and ordering, as in JS. Template and label stringification follows JS
  `String(value)`.
- `url` approximates the WHATWG URL parser, including `file:` hosts, without IDNA.
- `pattern` translates the JavaScript regex language to ICU. `\d \w \s \b` (and negations) use JS's
  ASCII and JS-whitespace definitions. `.` excludes only JS line terminators, and `$` matches only at the
  end of input. Annex B literals (`\a`, `\p{…}`, lone `{`, `[]`, `[^]`) behave as in JS. Syntax JS
  rejects (`(?i)`, `(?>…)`, `a*+`) fails the check. Remaining differences: matching is by code point, not
  UTF-16 unit, so an astral character is one `.`; ICU only supports bounded look-behind; and
  back-references to missing groups fail the check.
- Zone-less date-times (`2026-03-08T09:15`) are local wall-clock times built through `Calendar`. A time
  in a spring-forward gap moves to the next valid time; an ambiguous fall-back time takes the first
  occurrence.
- Repeat scope: `Expressions.resolve(_:state:scope:)`, `Visibility.evaluate(_:state:scope:)`,
  `Expressions.bindings(in:scope:)` and `resolveActionParam(_:state:scope:)` take a `RepeatScope`
  (item, index, base path). Elements expose `repeat` as a `RepeatConfig`. The SwiftUI form renderer
  does not expand `repeat`; the PDF renderer does. Outside a scope, `$item`, `$index` and `$bindItem`
  resolve to absent, as in core. `$computed` and `slots` are not supported.

## Tests

```sh
# Every test target (forms + PDF):
xcodebuild -scheme JSONRender-Package \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test
# or, on the host Mac:
xcrun swift test
```

On the iOS 26.2 simulator runtime, JavaScriptCore intermittently crashes the test host
(`JSRopeString::resolveToBuffer` under `RegExp` construction in `evaluateScript`), in both test bundles.
A minimal host with no package code reproduces it, so it is a simulator runtime bug; it has not been
seen on iOS 27 or macOS. All bridges already share one serial queue and one `JSVirtualMachine`;
confining JavaScriptCore to the main thread was tried and crashes the same way (on the main thread), so
the bridge keeps its queue. Disabling the concurrent JIT makes the package suite pass reliably in
practice:
`TEST_RUNNER_JSC_useConcurrentJIT=false xcodebuild … test`.

The suites cover JS semantics, pointers and state, expressions, visibility, validation, actions and the
submit flow, spec updates and streaming merges, fixture spec decoding, the JSC bridge (system prompt,
manifest, user prompt, validate/autofix, error surfacing, a custom catalog from `fixtures/bridge`), and chunk-by-chunk JSONL streaming. There is
also a render smoke test for every fixture, every streaming prefix and malformed specs, plus all parity
cases in `fixtures/parity`. The PDF suites cover every fixture rendering inside page bounds, text
extraction through `PDFDocument.string`, page counts and page numbers, repeat rows, table header
repetition, image loading and placeholders, link annotations, react-pdf line breaks and hyphenation,
partial and streaming specs, the PDF catalog through the bridge, the preview view, and fillable forms (field parity with `fixtures/parity/pdf-form-fields.json`, AcroForm
dictionaries, `qpdf --check` on macOS when qpdf is installed, a PDFKit fill-and-save round trip through
`PDFFormReader`, field pagination and duplicate names). Fixtures are
read from the repo through `#filePath`.
