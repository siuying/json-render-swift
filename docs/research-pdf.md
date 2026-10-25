# React PDF research for a native Swift module

## Summary

`@json-render/react-pdf` defines a compact document catalog, then translates its flat json-render tree into `@react-pdf/renderer` elements. The schema/catalog are already importable without React at runtime through dedicated package subpaths. A native module can reuse the catalog contract and generation rules conceptually, but its Swift renderer still needs its own layout and pagination engine. The strongest first target is the existing invoice, report, resume, and letter fixture set.

The main compatibility decisions are concrete: dimensions are PDF points, styles are individual component props rather than a general style object, flow is flexbox-like, and page breaks mostly come from automatic page wrapping. Only `PageNumber` is fixed by the standard renderer. Tables are a hand-built visual component, not a table primitive.

## Sources inspected

- SwiftUI port context: `/Volumes/External/Developer/json-render-ios/docs/ARCHITECTURE.md`, `/Volumes/External/Developer/json-render-ios/swift/JSONRenderSwiftUI/README.md`, and `packages/swiftui/src/schema.ts` / `catalog.ts`.
- Upstream catalog and schema: `/Volumes/External/Developer/json-render/packages/react-pdf/src/catalog.ts`, `schema.ts`, `components/standard.tsx`, `render.tsx`, `renderer.tsx`, `server.ts`, `index.ts`, and `package.json`.
- Example app: `/Volumes/External/Developer/json-render/examples/react-pdf/lib/examples.ts`, `lib/catalog.ts`, `app/api/generate/route.ts`, `app/api/pdf/route.ts`, and `app/page.tsx`.
- Docs: `/Volumes/External/Developer/json-render/apps/web/content/docs/api/react-pdf.mdx`, `data-binding.mdx`, and `directives.mdx`.

## 1. Schema, catalog, and visual contract

### Spec shape and child rules

`src/schema.ts` uses the standard flat tree: `root` plus an `elements` map. Each element has a catalog-backed `type`, catalog-backed `props`, required `children: string[]`, optional `visible`, and optional `repeat`. There is no top-level `on` field in this schema. The catalog gives `Document`, `Page`, `View`, `Row`, and `Column` a `default` slot; every other standard component has `slots: []` and renders no element children. `Document` should be root and contain Pages; Pages contain the content tree. The prompt requires every element to include `children`, even leaves, where it is `[]`.

Schema excerpt (`packages/react-pdf/src/schema.ts`):

> `root: s.string(), elements: s.record(s.object({ type: s.ref("catalog.components"), props: s.propsOf("catalog.components"), children: s.array(s.string()), visible: { ...s.any(), ...s.optional() }, repeat: { ...s.any(), ...s.optional() } }))`

All props below are required in the Zod object unless marked nullable. Nullable means the key is expected but may be `null`; it is not generally declared optional. Renderer defaults are listed separately. Catalog descriptions/examples are in `src/catalog.ts`.

### Standard components

| Component / slot | Props accepted by catalog | Renderer defaults and behavior |
|---|---|---|
| `Document` / `default` | `title`, `author`, `subject`: string or null | Maps to PDF document metadata. Null becomes undefined. Root-level wrapper; children are Pages. |
| `Page` / `default` | `size`: `A4`, `A3`, `A5`, `LETTER`, `LEGAL`, `TABLOID` or null; `orientation`: `portrait`, `landscape` or null; `marginTop`, `marginBottom`, `marginLeft`, `marginRight`: number or null; `backgroundColor`: string or null | Defaults size to A4, orientation to portrait, each margin to 40, background unset. Font is Helvetica, 12 pt. Margins are applied as page padding. |
| `View` / `default` | `padding`, `paddingTop`, `paddingBottom`, `paddingLeft`, `paddingRight`, `margin`, `borderWidth`, `borderRadius`, `flex`: number or null; `backgroundColor`, `borderColor`: string or null; `alignItems`: `flex-start`, `center`, `flex-end`, `stretch` or null; `justifyContent`: `flex-start`, `center`, `flex-end`, `space-between`, `space-around` or null | Unset values defer to PDF layout defaults. Generic flex container. |
| `Row` / `default` | `gap`, `padding`, `flex`: number or null; `alignItems` and `justifyContent` as for View; `wrap`: boolean or null | Horizontal flex container. `wrap: true` maps to `flexWrap: "wrap"`; false/null leaves wrapping unset. |
| `Column` / `default` | `gap`, `padding`, `flex`: number or null; `alignItems` and `justifyContent` as for View | Vertical flex container. |
| `Heading` / none | `text`: string; `level`: `h1`, `h2`, `h3`, `h4` or null; `color`: string or null; `align`: `left`, `center`, `right` or null | Defaults level to h2, alignment to left. h1/h2/h3/h4 use 24/20/16/14 pt bold Helvetica and bottom margins 8/6/4/4. |
| `Text` / none | `text`: string; `fontSize`: number or null; `color`: string or null; `align`: `left`, `center`, `right` or null; `fontWeight`: `normal`, `bold` or null; `fontStyle`: `normal`, `italic` or null; `lineHeight`: number or null | Defaults 12 pt, left, Helvetica, unset line height/color. Bold/italic select Helvetica-Bold, Helvetica-Oblique, or Helvetica-BoldOblique. |
| `Image` / none | `src`: string; `width`, `height`: number or null; `objectFit`: `contain`, `cover`, `fill`, `none` or null | Dimensions unset; object fit defaults to contain. Source may be URL or base64 per README; prompt asks for fully qualified URL. |
| `Link` / none | `text`, `href`: string; `fontSize`: number or null; `color`: string or null | Defaults 12 pt and `#2563eb`, underlined. `href` maps to PDF link destination. |
| `Table` / none | `columns`: array of `{ header: string, width: string|null, align: left\|center\|right|null }`; `rows`: string[][]; `headerBackgroundColor`, `headerTextColor`, `borderColor`: string or null; `fontSize`: number or null; `striped`: boolean or null | Default column width is equal percent, header bg `#f3f4f6`, header text `#111827`, border `#e5e7eb`, 10 pt, cell padding 6. `striped` colors odd rows `#f9fafb`. Each column width is assigned as supplied, commonly percentages. |
| `List` / none | `items`: string[]; `ordered`: boolean or null; `fontSize`: number or null; `color`: string or null; `spacing`: number or null | Defaults 12 pt, spacing 4; ordered marker is `1.`, `2.`, etc., otherwise bullet. Marker width 20/12; item text flexes. |
| `Divider` / none | `color`: string or null; `thickness`, `marginTop`, `marginBottom`: number or null | Defaults `#e5e7eb`, 1 pt, 8 pt top and bottom. Implemented as a bottom border. |
| `Spacer` / none | `height`: number or null | Defaults to 20 pt. |
| `PageNumber` / none | `format`: string or null; `fontSize`: number or null; `color`: string or null; `align`: `left`, `center`, `right` or null | Defaults `{pageNumber} / {totalPages}`, 10 pt, `#6b7280`, center. Substitutes page number/total at render time and marks the PDF text `fixed`. |

There are no defined actions in the standard PDF catalog (`examples/react-pdf/lib/catalog.ts` passes `actions: {}`). `renderToBuffer` uses a no-op `emit`; there are no standard component event names. The interactive React renderer can resolve `element.on` and has action contexts, but the PDF schema does not declare `on` and document generation itself does not dispatch actions. Avoid treating the interactive hooks as a PDF output feature.

### Style units, page sizing, fonts, colors

This is not a `style: { ... }` schema. Style is expressed as flat component props; custom components can use React PDF style objects. Numeric geometry and font sizes are passed directly as React PDF point values. `lineHeight` is passed through unchanged; examples use values like 1.4 and 1.6. `Table.columns[].width` is a string and examples use percent widths such as `"45%"`; equal percentage widths are synthesized when absent. Colors are strings, examples use hex. No font registration or arbitrary font family prop exists in the standard catalog. Standard text uses the built-in Helvetica family and its bold/oblique variants. The page defaults and prompt guidance are explicit in `components/standard.tsx` and `schema.ts`.

## 2. Mapping and layout behavior to reproduce

`renderToBuffer` recursively resolves the flat tree and constructs React elements. Standard component mappings are:

- `Document` / `Page` -> `@react-pdf/renderer` `Document` / `Page`.
- `View`, `Row`, `Column` -> PDF `View` with flex styles (`column` is React PDF's default direction; `Row` sets `flexDirection: "row"`).
- `Heading`, `Text`, `List`, `PageNumber` -> PDF `Text` and `View` nodes with fixed style recipes.
- `Image` -> PDF `Image`; `Link` -> PDF `Link`.
- `Table` -> nested Views and Text, manually drawing header backgrounds and row bottom borders.
- `Divider` -> View with bottom border; `Spacer` -> fixed-height View.

Layout semantics exposed in catalog: direction row/column; flex grow via `flex`; main-axis `justifyContent`; cross-axis `alignItems`; numeric `gap`; padding; View margin; row wrapping. It does not expose widths/heights on generic containers, `flexBasis`, per-side margins, positioning, transforms, or a full React Native style object. Text is naturally measured and wraps inside available width. Page dimensions/orientation and margins are controlled by `Page` props; page padding equals margins, so content area shrinks by those values.

Pagination is mostly delegated to React PDF's page flow. The spec has no page-break component/property and no explicit page-break directive in the standard component map. A `Page` can hold flow content that spills onto subsequent physical pages under the PDF engine's wrapping rules. `PageNumber` is the sole standard node marked fixed and receives `{pageNumber, totalPages}` from React PDF; it repeats over generated pages. There is no standard fixed header/footer component or repeated table header. A repeated header/footer requires a custom renderer or explicit repeated content.

Important renderer detail: `renderToBuffer` passes `{...spec.state, ...options.state}` as state, so an explicit options state shallowly overrides spec top-level state keys. It resolves `$state`/other core expressions and element visibility before creating output. Missing child IDs and unknown components are silently skipped in this server path. The React renderer logs missing IDs/unknown renderers and uses contexts for live state, actions, validation, and repeat, but these are not necessary for static PDF output.

## 3. State, expressions, repeat, and visibility

The PDF implementation supports data-driven output. `renderToBuffer` calls core `resolveElementProps`, `evaluateVisibility`, and repeat path helpers. It starts from `spec.state` plus optional `RenderOptions.state`.

- `$state` and `$cond`-based property/visibility resolution work through core expression functions. The general React PDF data-binding docs point to core expressions; the component values themselves must resolve to types accepted by the relevant component prop (for example, text to string).
- `visible` is element-level and evaluated before child rendering; false elements disappear.
- `repeat` is a top-level element property `{ statePath, key? }`, not a prop. The renderer reads an array at the path and renders that element's children for each item. A nested repeat can use an item-relative path. `key` selects an item object's field for identity, with index fallback.
- Within repeated scopes, core supports `$item` and `$index`, and resolution receives current item/index/base path. The test `src/repeat-container.test.tsx` exercises nested repeat containers.
- `$bindState` is unnecessary for static PDF values. Actions, mutations, and interactive validation are not part of the generated static PDF path.

The react-pdf schema does not define `state` in its explicit `spec` object excerpt, even though renderer `Spec` from core and runtime consume `spec.state`. This appears to rely on the core spec model/loose object handling and is worth checking against the exact validation path before building a shared schema contract. The SwiftUI port's schema/catalog is intentionally a different form-only contract: its catalog uses SwiftUI controls and actions, so it cannot serve as the PDF catalog unchanged.

## 4. Prompt generation and example app flow

`examples/react-pdf/lib/catalog.ts` defines `pdfCatalog = defineCatalog(schema, { components: standardComponentDefinitions, actions: {} })`. The API route computes `const SYSTEM_PROMPT = pdfCatalog.prompt()` once. The PDF schema supplies `defaultRules`, so those rules join the catalog prompt. They require Document root/Page children, explicit size, Row/Column layout, string rows matching table columns, no raw text nodes, fully qualified image URLs, PageNumber, no emoji, and conservative page density. There is no PDF-specific `customRules` call in the example. Core supports `catalog.prompt({ customRules })` and the docs' directive prompt API, but the example uses plain `.prompt()`.

Generation uses `POST /api/generate`: it validates a prompt, applies minute and daily IP rate limits, creates a user message with core `buildUserPrompt({ prompt, currentSpec: startingSpec })`, then streams `streamText` through `@ai-sdk/gateway`. Default model is `anthropic/claude-haiku-4.5`, overrideable with `AI_GATEWAY_MODEL`; temperature is 0.7. The browser reads the text stream, feeds it into `createSpecStreamCompiler`, and updates the displayed spec when patches arrive. When modifying an example, that example spec is passed as `startingSpec`.

`POST /api/pdf` validates only the basic presence of `root` and `elements`, then uses `renderToBuffer`. GET serves a named example (default invoice). Response is `application/pdf`, inline for preview and attachment when `download=1`. The UI has example selection, prompt editor, JSON pane, PDF iframe preview, and download. During generation it posts renderable partial specs every two seconds to refresh the preview; after completion it renders the final spec. Example PDFs can be viewed/downloaded via GET; generated specs use POST.

## 5. Can catalog/schema be imported without React?

Yes, for definitions and prompt construction. `package.json` exports:

- `@json-render/react-pdf/server` -> `dist/server.*`, documented as schema/catalog definitions only.
- `@json-render/react-pdf/catalog` -> `dist/catalog.*`.
- Main entry -> `dist/index.*`, which imports renderer, contexts, components, and PDF render APIs, so do not use that for a no-React/JSC bundle.

`src/catalog.ts` imports only `zod`; `src/schema.ts` imports `defineSchema` from `@json-render/core`; `src/server.ts` re-exports those and has only type imports from `catalog-types.ts` (which are erased). `tsup.config.ts` externalizes `react`, `@react-pdf/renderer`, `@json-render/core`, and `zod`. Therefore `/server` plus `/catalog` has no React or `@react-pdf/renderer` runtime dependency. `defineCatalog` and `.prompt()` come from core and can be used with those definitions to generate the same schema-based prompt.

For the current SwiftUI JavaScriptCore bridge, direct reuse is plausible only if the bundled core/zod graph meets the bare JSC constraints in `docs/ARCHITECTURE.md`; React is not the blocker. The two catalogs are separate by design: add PDF schema/catalog definitions in the TypeScript package or a PDF sibling package, rather than import the SwiftUI form catalog. The native renderer remains Swift.

## 6. Example specs available as fixtures

All examples are in `/Volumes/External/Developer/json-render/examples/react-pdf/lib/examples.ts`:

| `name` | Label | Description |
|---|---|---|
| `invoice` | Invoice | Company header, billing details, line items, totals. |
| `report` | Quarterly Report | Summary data, tables, and key findings. |
| `resume` | Resume | Resume layout with experience, education, and skills. |
| `letter` | Business Letter | Formal letterhead, body paragraphs, and signature. |

These fixtures primarily exercise static text and fixed table row arrays. They are useful first visual parity fixtures, with resume/report stressing dense text and multipage flow. The schema supports repeat/state, but these four examples are not useful coverage for that behavior unless edited or supplemented.

## 7. Native Swift recommendation and pitfalls

Implement a measured block layout engine, not a general-purpose browser flexbox clone. A credible first subset for these examples:

1. Pages: A4/A3/A5/Letter/Legal/Tabloid in portrait/landscape, per-edge margins, background, top-down content flow, automatic page creation, and page-number placeholders resolved after total page count is known.
2. Blocks: vertical stack, horizontal row, gap, uniform/per-edge padding, uniform margin, flex-grow weights, cross-axis alignment, main-axis start/center/end/space-between, and row wrap for the resume skills section.
3. Text: headings, paragraphs, inline newlines, line wrapping at measured word boundaries, alignment, font weight/style, color, line height, and keep-together for short heading/label blocks where possible.
4. Content: divider, spacer, image fit, links/metadata, list rows, and table columns with percent widths, row backgrounds/borders, and repeated header on continuation pages if native behavior can support it.
5. Expressions: resolve state, conditional props, visibility, and repeat before layout. Keep the PDF contract static: no input bindings or action execution.

Use Core Text (`CTFramesetter`/`CTLine`) for line measurement and drawing, or a carefully scoped attributed-string layout abstraction. Avoid measuring with SwiftUI text views: PDF drawing needs deterministic sizes independent of view hosting and screen scale. Keep a single coordinate convention internally (top-left is easiest for layout), and convert to Core Graphics' PDF coordinate system only at draw time.

Pitfalls that will affect fixture fidelity:

- Text measurement and draw metrics must agree. Helvetica-compatible widths, Unicode fallback, explicit newline handling, and line-height behavior can shift every block below a paragraph. The upstream renderer strips emoji before drawing; prompt also forbids them because Helvetica lacks glyphs.
- Pagination needs a layout pass before drawing if PageNumber includes total pages. Split long paragraphs at line boundaries; avoid splitting short rows/cards; decide whether table rows may split; repeat table headers if desired, documenting this as native behavior if upstream does not.
- React PDF's fixed `PageNumber` repeats, but its ordinary content participates in flow. Model fixed overlays separately from flow. For repeated header/footer use explicit fixed regions rather than inserting arbitrary views into normal content.
- Images may require network access and decoding. The example prompt uses Picsum URLs, but native output should have a defined policy for remote loading, failures, caching, supported formats, and aspect-fit/fill. Consider pre-resolving images to local bytes for deterministic rendering.
- `Table` accepts percentage strings, not normalized numeric weights. Parse percentages and define behavior for malformed widths and row/column count mismatch. Upstream renderer falls back to empty cell text if a row is short.
- React PDF defaults and Core Text defaults differ. Explicitly reproduce heading sizes/margins, text baselines, 6 pt table-cell padding, page padding, and colors; do not assume matching defaults.

## Useful excerpts

From `packages/react-pdf/src/components/standard.tsx`, the page default is applied directly in the mapping:

> `size={(p.size as any) ?? "A4"}`
>
> `paddingTop: p.marginTop ?? 40 ... fontFamily: "Helvetica", fontSize: 12`

From the PDF prompt rules in `packages/react-pdf/src/schema.ts`:

> `The root element MUST be a Document component. Its children MUST be Page components.`
>
> `Use Row for horizontal layouts and Column for vertical layouts. Both support gap, align, and justify props.`

From `packages/react-pdf/src/components/standard.tsx`, page number behavior:

> `render={({ pageNumber, totalPages }) => ... }` and `fixed`

From `packages/react-pdf/src/render.tsx`, state precedence:

> `const mergedState = { ...spec.state, ...state };`

## SwiftUI port notes

The existing port is explicitly scoped to forms and has a different catalog (`Form`, `Section`, controls, actions). Its `docs/ARCHITECTURE.md` says `repeat`/`slots` are out of scope for its v1 and says the JavaScriptCore bridge owns catalog prompt/schema work while Swift owns native runtime behavior. A PDF module should therefore have its own schema/catalog and renderer registry. Reuse core prompt/compiler infrastructure where the JSC constraints permit it; do not stretch the form catalog to describe document layout.
