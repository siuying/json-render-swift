# json-render for Swift — prototype architecture & contract

This is the binding contract between the TypeScript package, the Swift SDK and the demo app.
Background research: `docs/research.md`. Upstream checkout (read-only reference): `/Volumes/External/Developer/json-render`.

Scope: **forms**. Prove that an LLM can generate a json-render spec targeting a SwiftUI catalog,
and that a native Swift SDK renders it with two-way data binding, actions, validation and visibility.
A second module, `JSONRenderPDF`, renders specs from the `@json-render/react-pdf` catalog to PDF; its
contract is `docs/PDF.md`. Documentation site: `apps/docs` (`pnpm docs:dev`, `pnpm docs:build`).

## Repository layout

```
json-render-ios/
  package.json, pnpm-workspace.yaml     # pnpm workspace root (Node >= 24, pnpm 11)
  packages/swift/                       # @json-render/swift (TypeScript)
    src/schema.ts                       # defineSchema(...) for the SwiftUI spec
    src/catalog.ts                      # component + action definitions (zod v4)
    src/index.ts                        # public exports (schema, catalog, prompt helpers, PDF catalog)
    src/pdf.ts                          # PDF schema + catalog (upstream @json-render/react-pdf definitions)
    src/validate.ts                     # catalog-generic spec validation / autofix
    src/bridge.ts                       # installBridge() -> globalThis.JSONRenderBridge (@json-render/swift/bridge)
    src/bridge-entry.ts                 # entry of the shipped bundle: installBridge() with the built-in catalogs
    scripts/build-bridge.mjs            # esbuild IIFE -> dist/json-render-bridge.js, copies into Swift Resources;
                                        #   also builds fixtures/bridge/test-catalog-bridge.js
    scripts/gen-parity-fixtures.ts      # runs @json-render/core over cases -> fixtures/parity/*.json
    scripts/gen-system-prompt.ts        # docs/system-prompt*.sample.txt
    test/                               # vitest
  fixtures/
    specs/*.json                        # hand-authored sample form specs (also bundled in the demo as offline examples)
    parity/*.json                       # generated: expected results from @json-render/core
    pdf/*.json, pdf/reference/          # PDF fixture specs + upstream react-pdf reference renders
    bridge/test-catalog-bridge.js       # generated: bridge with an extra "test" catalog (Swift tests)
  swift/JSONRender/                     # Swift package (SDK), iOS 26, Swift 6 language mode
    Package.swift
    Sources/JSONRenderSwiftUI/
      Resources/json-render-bridge.js   # copied by build-bridge.mjs (checked in)
    Sources/JSONRenderPDF/              # native PDF renderer (see docs/PDF.md)
    Tests/JSONRenderSwiftUITests/, Tests/JSONRenderPDFTests/
  ios/                                  # demo app; XcodeGen project.yml -> FormDemo.xcodeproj
  apps/docs/                            # documentation site (Astro + Starlight)
  docs/
```

Toolchain: Xcode 27 (`xcodebuild`, `xcrun swift`). NOTE: `swift` on PATH is a swiftly 6.3 toolchain — use
`xcrun swift` / `xcodebuild` so the Xcode SDK is used. iOS simulator runtimes: iOS 26.2 and 27.0.
XcodeGen is installed (`/opt/homebrew/bin/xcodegen`). esbuild is not global — add as devDependency.

## Division of responsibility: JS vs Swift

| Concern | Where | Why |
|---|---|---|
| Catalog / schema definition, system prompt, user prompt (edit mode) | TS → JS bundle in JSC | reuse `@json-render/core` `catalog.prompt()` / `buildUserPrompt()` verbatim |
| JSONL patch stream compilation | JS bundle (`createSpecStreamCompiler`) | reuse core; exact semantics |
| Spec structural validation / autofix, catalog (zod) validation | JS bundle | reuse core + zod |
| Rendering, state store, expression resolution, visibility, field validation, action dispatch | **native Swift** | hot path on every keystroke; must be synchronous & observable |

Native runtime semantics MUST match `@json-render/core`. This is enforced by parity fixtures generated
from core (`fixtures/parity/*.json`) and asserted in Swift tests.

## Spec format (unchanged from json-render core)

Flat element map. Stream format from the LLM: JSONL, one RFC 6902 patch per line.

```json
{
  "root": "form",
  "elements": {
    "form": { "type": "Form", "props": { "title": "Sign up" }, "children": ["account", "submit"] },
    "account": { "type": "Section", "props": { "header": "Account" }, "children": ["email"] },
    "email": {
      "type": "TextField",
      "props": {
        "label": "Email", "placeholder": "you@example.com", "keyboard": "email",
        "value": { "$bindState": "/form/email" },
        "checks": [ { "type": "required", "message": "Email is required" },
                    { "type": "email", "message": "Enter a valid email" } ],
        "validateOn": "blur"
      },
      "children": []
    },
    "submit": { "type": "Button", "props": { "label": "Create account", "style": "borderedProminent" },
                "on": { "press": { "action": "submit", "params": { "data": { "$state": "/form" } } } },
                "children": [] }
  },
  "state": { "form": { "email": "" } }
}
```

Element fields: `type`, `props`, `children` (keys), optional `visible`, `on`, `watch`, `repeat`. `repeat` is
parsed into `Element.repeat` and expanded by the PDF renderer; the forms renderer ignores it. `slots` is out of
scope (parsed and ignored gracefully). The TS schema MUST declare `state`, `on`, `visible`,
`watch` so zod validation does not strip them (the RN schema has this bug — see research §1).

## Expressions (props, action params, check args)

- `{ "$state": "/ptr" }` read (RFC 6901 JSON Pointer)
- `{ "$bindState": "/ptr" }` read + two-way write path (inputs)
- `{ "$cond": <VisibilityCondition>, "$then": x, "$else": y }`
- `{ "$template": "Hello ${/form/name}" }`
- `{ "$item": "field" }`, `{ "$index": true }`, `{ "$bindItem": "field" }` resolve inside a `repeat` scope
  (`RepeatScope`; parity-tested with `fixtures/parity/repeat.json`) and to absent outside one, as in core.
  The forms renderer never creates a scope, so in forms they are absent.
- Out of scope: `$computed` (resolves to absent, no crash).

## Visibility

Element-level `visible`: boolean | `{ "$state": ptr, eq|neq|gt|gte|lt|lte, not? }` | array (AND) |
`{ "$and": [...] }` | `{ "$or": [...] }`. Exactly core's `evaluateVisibility` semantics (incl. truthiness when
no operator). Hidden fields are excluded from validation.

## SwiftUI catalog (v1)

Component names are SwiftUI-flavored so the LLM maps them naturally. All props optional unless noted.
Zod props must be nullable-friendly like the RN catalog (LLMs emit `null`).

| Component | Props | Events | SwiftUI |
|---|---|---|---|
| `Form` | `title`, `subtitle` | — | `Form` (+ navigationTitle) — usually root |
| `Section` | `header`, `footer` | — | `Section` |
| `VStack` / `HStack` | `spacing`, `alignment` (leading/center/trailing; top/center/bottom) | — | stacks |
| `Text` | `content` (req), `style` (largeTitle,title,title2,headline,subheadline,body,callout,caption,footnote), `color` (primary,secondary,accent,red,orange,green,blue) | — | `Text` |
| `TextField` | `label` (req), `placeholder`, `value`, `keyboard` (default,email,number,decimal,phone,url), `contentType` (name,givenName,familyName,email,phone,username,newPassword,password,oneTimeCode,streetAddress,city,postalCode,countryName,organizationName,url), `autocapitalization` (never,words,sentences,characters), `multiline` (bool), `lineLimit`, `disabled`, `checks`, `validateOn` | `submit`, `change` | `TextField` (axis .vertical when multiline) |
| `SecureField` | `label` (req), `placeholder`, `value`, `contentType`, `disabled`, `checks`, `validateOn` | `submit`, `change` | `SecureField` |
| `Toggle` | `label` (req), `isOn`, `disabled`, `checks`, `validateOn` | `change` | `Toggle` |
| `Picker` | `label` (req), `selection`, `options` (req: `[{label, value}]`, value string\|number), `style` (menu,segmented,inline,wheel,navigationLink), `disabled`, `checks`, `validateOn` | `change` | `Picker` |
| `DatePicker` | `label` (req), `selection` (ISO-8601 string: `YYYY-MM-DD` for date, full ISO datetime otherwise), `components` (date,hourAndMinute,dateAndTime), `minimum`, `maximum` (ISO strings), `style` (automatic,compact,graphical,wheel), `disabled`, `checks`, `validateOn` | `change` | `DatePicker` |
| `Stepper` | `label` (req), `value` (number), `minimum`, `maximum`, `step`, `disabled`, `checks` | `change` | `Stepper` |
| `Slider` | `label` (req), `value` (number), `minimum` (req), `maximum` (req), `step`, `showValue`, `disabled`, `checks` | `change` | `Slider` |
| `LabeledContent` | `label` (req), `value` (string; often `$template`/`$state`) | — | `LabeledContent` |
| `Button` | `label` (req), `systemImage` (SF Symbol), `role` (cancel,destructive), `style` (automatic,borderedProminent,bordered,borderless,plain), `disabled` | `press` | `Button` |
| `Divider` | — | — | `Divider` |
| `PieChart` | `data` (req), `nameKey` (req), `valueKey` (req), `aggregate` (sum,count,avg), `donut` (bool), `colors` (hex[], cycled; default palette), `legend` (bool, default true), `height` (default 300), `title` | — | Swift Charts `SectorMark` over `PieChartData`, legend rows below |
| `BarChart` / `LineChart` / `AreaChart` | `data` (req: array of objects, usually `$state`), `xKey` (req), `yKey` (req), `aggregate` (sum,count,avg), `color` (hex), `height` (default 300), `title` | — | Swift Charts `BarMark` / `LineMark` / `AreaMark` + `LineMark` over `ChartData` |

Value binding props (`value`, `isOn`, `selection`) take `{ "$bindState": ptr }`.
`checks: [{ type, args?, message }]` and `validateOn: "change" | "blur" | "submit"` (default `"submit"`)
follow core's `ValidationConfig`. Built-in check types are exactly core's `builtInValidationFunctions`
(required, email, minLength, maxLength, pattern, min, max, numeric, url, matches, ... — mirror core's list).
`args` values may be expressions (e.g. `matches: { "other": { "$state": "/form/password" } }`).

## Actions

Bindings: `on: { <event>: { action, params?, confirm? } | [ ... ] }`; params are expression-resolved.

| Action | Params | Behavior |
|---|---|---|
| `setState` | `statePath`, `value` | runtime built-in |
| `pushState` | `statePath`, `value` | runtime built-in (append to array) |
| `removeState` | `statePath`, `index` | runtime built-in |
| `resetForm` | `statePath`?, `value`? | restore initial `spec.state` (or set value at path); clears validation |
| `submit` | `data` (any; usually `{"$state":"/form"}`) | validate all visible fields with checks; if any fail → mark touched, show errors, stop. Else invoke host handler `submit` with resolved params |
| `showAlert` | `title`, `message` | runtime built-in (SwiftUI alert) |
| `openURL` | `url` | runtime built-in |

Hosts may register additional custom action handlers by name (Swift closure). `confirm: {title, message}`
shows a confirmation dialog before dispatching. Unknown actions → logged, no crash.

## JS bridge API (`globalThis.JSONRenderBridge`)

Object arguments may be plain JS values or JSON strings (`compilerPush`'s chunk is raw stream text). Return
values are plain JSON-serialisable values. The Swift SDK calls everything through `invoke`, which takes a
JSON array of arguments and returns a JSON string `{"result": …}` or `{"error": {"message", "stack"}}`.
`catalog` selects `"swiftui"` (forms, the default), `"pdf"`, or a catalog the bundle added with `installBridge`;
an unknown name throws `Unknown catalog: <name> (expected swiftui | pdf | …)`, listing the available names.

```
version(): string
systemPrompt(options?: { catalog?, customRules?: string[], mode?: "standalone" | "inline" }): string
buildUserPrompt(input: { prompt: string, currentSpec?: Spec|null, state?: object|null, maxPromptLength?: number }): string
catalogManifest(options?: { catalog? }): { components: string[], actions: string[] }
jsonSchema(options?: { catalog?, strict?: boolean }): object
validateSpec(spec, options?: { catalog? }): { valid: boolean, issues: {severity, message, path?, code?}[] }
autoFixSpec(spec, options?: { catalog? }): Spec
createCompiler(initial?: Spec): number                    // returns handle
compilerPush(handle, chunk: string): { spec: Spec, newPatches: Patch[] }
compilerFinish(handle): Spec                               // flushes trailing line, frees handle
compilerDispose(handle): void                              // frees an abandoned compiler without flushing; no-op for unknown handles
invoke(method: string, argsJSON?: string): string          // {"result"} or {"error"} envelope; "Unknown bridge method" for bad names
```

The API object is built by `installBridge(options?: { catalogs?: Record<string, Catalog> })`, exported from
`@json-render/swift/bridge` (`src/bridge.ts`) with the types `Catalog`, `CatalogName`, `CatalogOptions` and
`InstallBridgeOptions`. It merges `catalogs` after the built-ins, installs `globalThis.JSONRenderBridge` and
returns the API. A custom name equal to a built-in (`swiftui`, `pdf`) or a value that is not a catalog throws.
Importing the module installs nothing; the shipped bundle's entry `src/bridge-entry.ts` calls `installBridge()`.
An app with its own catalogs bundles its own entry the same way and loads it with
`JSONRenderBridge(script:sourceURL:)`; on the Swift side `JSONRenderBridge.Catalog` is an open
`RawRepresentable` struct, so the app declares `static let database: Self = "database"`. It keeps the former
enum's API (`allCases` = the built-ins, a failable `init?(rawValue:)` that never fails); only exhaustive
`switch`es need a `default`. The PDF form-field checks in `validateSpec` run for the built-in `pdf` catalog
only (a `Symbol.for` marker on `pdfCatalog`), never because a catalog has a `FieldSet` component.

`buildUserPrompt` and the stream compiler are catalog-agnostic. `validateSpec` runs core `validateSpec`, the
catalog grammar and per-component prop / action param schemas; issue `code`s are listed in
`packages/swift/src/validate.ts`.

Bundle: esbuild IIFE of `src/bridge-entry.ts`, `platform: neutral`, target `safari18`, `define: { "process.env.NODE_ENV": "\"production\"" }`,
bundles zod. Must load in a bare `JSContext` (no `fetch`, `structuredClone`, `TextEncoder`, `setTimeout`).
TS package's vitest suite must include a test that evaluates the built IIFE in a bare `node:vm` context
with no globals to prove this. `pnpm test` first runs `pnpm check:bridge`, which rebuilds the bundle and
`fixtures/bridge/test-catalog-bridge.js` into a temporary directory and fails if the checked-in copies differ.

## Swift SDK (`JSONRenderSwiftUI`) — required capabilities

- `Spec` / `Element` / `JSONValue` Codable models (`JSONValue` = null|bool|number|string|array|object).
- `JSONRenderBridge` — wraps `JSContext`, loads bundled JS from `Bundle.module`, exposes typed async-safe API
  (system prompt, user prompt, stream compiler, validateSpec). Confine JSC to one actor/queue.
- `StateStore` — `@Observable`, JSON Pointer get/set, fine-grained enough that typing in one field does not
  rebuild unrelated heavy work. Seeded from `spec.state`; reseeded when the root key changes (like RN AppRenderer),
  preserving user-entered values across streaming patches.
- Native expression resolver, visibility evaluator, validation engine (core parity, parity-fixture tested).
- `ActionDispatcher` — built-ins + host-registered handlers; `submit` flow per table above.
- `JSONRenderView(session:)` SwiftUI view + component registry; host may override/add components by type name.
  Partially streamed specs must render without crashing (missing children keys are skipped).
- Errors displayed inline under fields (red caption) once touched/validated.
- Unit tests (Swift Testing) incl. parity fixtures; `xcodebuild test` on an iOS 26 simulator must pass.

## Demo app (`ios/FormDemo`)

Inspired by `examples/react-native` (prompt bar, streaming, UI/JSON/JSONL tabs) and `examples/no-ai`
(registration form validation UX). Calls the OpenAI Responses API directly with streaming (SSE),
system prompt from the bridge, user prompt via `buildUserPrompt` (follow-up prompts refine the current form).
API key entered in Settings (stored in Keychain) or from `OPENAI_API_KEY` scheme env var; model configurable.
Offline example specs from `fixtures/specs` available without a key. Submitted data shown in a sheet.
