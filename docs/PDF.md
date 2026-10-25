# PDF module — contract

Adds native PDF generation for json-render specs, modelled on `@json-render/react-pdf`.
Research: `docs/research-pdf.md`. Upstream (read-only): `/Volumes/External/Developer/json-render/packages/react-pdf`,
`examples/react-pdf`.

## Catalog (reused, not redefined)

The PDF catalog is upstream's: `@json-render/react-pdf/server` (schema + `standardComponentDefinitions`,
React-free) with `actions: {}`. Components: Document, Page, View, Row, Column, Heading, Text, Image, Link,
Table, List, Divider, Spacer, PageNumber — props/defaults exactly as in research §1. If the published
`@json-render/react-pdf@0.21.3` subpath cannot be bundled for bare JSC, redefine it in
`packages/swift/src/pdf/` by copying upstream definitions verbatim (note the reason).

Spec additions vs the forms catalog: `repeat: { statePath, key? }` and `$item` / `$index` expressions
**are in scope for PDF** (table rows / lists driven by state). `state` must survive validation.

## JS bridge additions (additive; existing calls default to the forms catalog)

```
systemPrompt(options?: { catalog?: "swiftui" | "pdf", customRules?, mode? }): string
catalogManifest(options?: { catalog? }): { components, actions }
validateSpec(spec, options?: { catalog? }): { valid, issues }
autoFixSpec(spec, options?: { catalog? }): Spec
```
`buildUserPrompt` and the stream compiler are catalog-agnostic and unchanged.

## Fixtures

- `fixtures/pdf/{invoice,report,resume,letter}.json` — extracted from upstream `examples/react-pdf/lib/examples.ts`
  by a script (not hand-copied), plus `fixtures/pdf/statement.json` exercising `state`, `repeat`, `$item`,
  `$index`, `$template`, `visible`, multi-page flow and `PageNumber`.
- `fixtures/pdf/reference/*.pdf` + first-page PNGs rendered by upstream `@json-render/react-pdf` `renderToBuffer`
  (dev-only script) for visual comparison against the native renderer.
- Parity fixtures extended with repeat-scope cases (`$item`, `$index`, `$bindItem`, repeat visibility).

## Swift: `JSONRenderPDF` library (new target + product in `swift/JSONRender/Package.swift`)

- Depends on the existing runtime (JSONValue, Spec, Expressions, Visibility). Repeat-scope support
  (`$item`/`$index`) is added to the shared Expressions/Visibility additively, parity-tested.
- No UIKit-only drawing APIs in the layout core: Core Text (`CTFramesetter`) for measurement + drawing,
  Core Graphics PDF context for output, PDFKit (`PDFDocument`, `PDFView`) for preview/inspection.
  Must work on iOS 26 and macOS 26 (tests run on both).
- Pipeline: resolve (state, expressions, visibility, repeat) → measure/layout (top-left coordinates, points)
  → paginate → draw. Two passes so `PageNumber` knows total pages.
- Layout subset (research §7): page sizes/orientation/margins/background; Column/View vertical flow; Row
  horizontal with `flex` weights, `gap`, `alignItems`, `justifyContent` (start/center/end/space-between/
  space-around), `wrap`; padding/margin/border/borderRadius/backgroundColor; text wrapping with weight/style/
  color/align/lineHeight (Helvetica family); Table with percent widths, header colours, striped rows, borders,
  header repeated on continuation pages; List; Divider; Spacer; Link (PDF link annotation); Image (contain/
  cover/fill/none) loaded via an injectable async image loader (default: URLSession for http(s), data: URLs;
  failure → neutral placeholder box, never throws).
- Pagination (as implemented; decisions recorded 2026-10-25):
  - Paragraphs split at line boundaries.
  - Rows, table rows and the visual lines of a wrapped Row move to the next page whole when they fit on
    one page; taller rows split every child at the same cut.
  - Views, Columns and Lists move whole only when they are at most **one third of the page content
    height** and fit on one page; taller ones flow, splitting between children. (Moving every View that
    fits left pages nearly blank — e.g. the statement's per-account Column — so the contract's
    "move whole if it fits" rule is applied with this threshold.)
  - Tables split only between rows and repeat the header on continuation pages; a row taller than a page
    is split across pages under the repeated header.
  - Every page makes progress: content that cannot be split is clipped (or images scaled) at the top of a
    page, reported as a `contentClipped` warning. Documents stop at `Options.maxPages` (default 500) with
    a `pageLimitReached` warning (`PDFRenderer.renderResult(_:)`).
- `PageNumber` (user decision 2026-10-25, supersedes the earlier upstream-parity call): a page **footer**.
  It is drawn on every physical page of its `Page`, inside the bottom margin, wherever it appears in the
  element tree, and takes no flow space. `align` (left/center/right, default center) is relative to the
  content area between the left and right margins; the text is vertically centred in the bottom margin.
  When the margin is too small for the text, the footer reserve grows to the text height plus a 4 pt inset
  on each side (content area shrinks), so the number never overlaps content. `{pageNumber}` /
  `{totalPages}` (first occurrence each) are substituted with real totals; layout is repeated when the
  total's digit count grows, so the reserved box fits the real text. The reserve is capped at a quarter
  of the page height: a taller footer (huge `fontSize`, long `format`) is shrunk to fit, clipped to its
  box, and reported as a `contentClipped` warning — content and form fields are never pushed out.
- Limits: nesting deeper than 32 elements or more than 20,000 resolved elements is dropped with a
  warning; numeric props are clamped to finite, non-negative (where applicable) ranges; page margins
  leave at least a third of the page for content.
- Images: the default loader fetches only `http(s)` (streamed, ≤ 10 MB) and `data:` URLs (≤ 10 MB); it
  never reads local files — hosts opt in with `PDFImageLoader.files(in:)`. `PDFImageLimits` bounds bytes
  per image and per document, decoded pixels, concurrent loads and the drawing resolution (images are
  downsampled). Loads that exceed the deadline are abandoned without waiting for the loader.
- Rendering honours task cancellation between stages and pages; `JSONRenderPDFView` re-renders when the
  spec, `options.state`, timeout, limits or page cap change (or an explicit `id`).
- Public API (shape, refine as needed):
  ```swift
  let renderer = PDFRenderer(options: .init(state: [:], imageLoader: .default))
  let data: Data = try await renderer.render(spec)          // PDF bytes
  let doc: PDFDocument = try await renderer.document(for: spec)
  JSONRenderPDFView(spec: spec)                              // SwiftUI PDFKit preview, re-renders on spec change
  ```
  Partial (streaming) specs render without throwing (debounced re-render is the host's job).
- Tests: every fixture renders; text extraction via `PDFDocument.string` contains expected strings; page
  counts; page number text; repeat rows; image placeholder; link annotations; geometry sanity (nothing drawn
  outside the page). Visual check: render first pages to PNG and compare by eye with the upstream references.

## Demo app

A "Document" mode beside "Form": prompt → PDF via the PDF system prompt, live preview (debounced re-render
while streaming), JSON/JSONL tabs, offline PDF examples, Share/Export. Plus "Export as PDF" on the
form-submission sheet (a summary spec built from submitted data).
