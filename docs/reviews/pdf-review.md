# PDF module review

Reviewed 2026-10-25 against `docs/PDF.md`, `docs/research-pdf.md`, the read-only upstream `packages/react-pdf/src/{render.tsx,components/standard.tsx,catalog.ts,schema.ts}`, and core expression/repeat/visibility helpers. Source files were not modified. `ios/` and `apps/docs` were excluded.

The supplied fixtures and repeat parity cases pass, and the five first-page screenshots look close to the upstream references. The main problems are in pagination outside those examples, resource limits, and preview invalidation. There are four P1 findings and thirteen P2 findings below. The last two are explicit contract deviations that match upstream behavior and therefore need a product decision if upstream parity is intended to supersede the contract.

## Verified findings

### 1. P1: nested documents exhaust the thread stack

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Model/SpecResolver.swift:43` and `Layout/LayoutEngine.swift:111`.

The tree walk and subsequent layout recurse without a depth limit. A valid flat spec containing 100 nested Columns and one Text crashes the debug renderer with SIGBUS. An optimized release build handles 100 but crashes at 1,000. Diagnostic reports show stack-guard failures in recursive `LayoutEngine.layout` / `layoutColumn` and, at greater depths, `SpecResolver.resolve`. The ancestor set prevents cycles but does not bound acyclic nesting. A generated spec can terminate the host process instead of rendering a partial document.

Reproduction: `/tmp/pdf-review-probe /tmp/pdf-review-cases/depth-100.json`; release equivalent with `/tmp/pdf-review-probe-release` and `depth-1000.json`. Crash frames are preserved in `/tmp/pdf-review-crash-summary.json`.

Suggested fix: impose a conservative depth and expanded-node budget before building recursive model values, or use iterative traversal throughout the pipeline. Exceeding the budget should produce a bounded partial result or a controlled error. Cover debug and optimized builds.

### 2. P1: an unsplittable empty container generates 10,000 blank pages

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Layout/Paginator.swift:22` and `:121`.

An empty View with `padding: 1000` and a background on an A4 page returns `(nil, originalBox)` from `splitColumn`. Every pagination iteration sees the same box, appends a blank page, and retries until the 10,000-page cap. The result has 10,000 pages, no drawn items, and no error. This also affects partial streaming containers whose children have not arrived yet. The cap bounds the loop but silently discards the content and still allocates/draws thousands of pages.

Reproduction: `/tmp/pdf-review-cases/oversized-view.json`, accepted by the PDF validator with no issues. The standalone probe took approximately 2.2 seconds in the initial run.

Suggested fix: enforce forward progress on every split. At page top, explicitly clip/scale or otherwise consume an oversized empty container. If a global page limit is reached, report truncation instead of returning a normal-looking success.

### 3. P1: wrapped Rows do not paginate by their visual lines

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Layout/Paginator.swift:140`.

`layoutRow` assigns different Y coordinates to wrapped lines, but `splitRow` processes every child as a member of one horizontal line. It even passes `atPageTop: true` to children whose Y position is already below the page. Children are forced into the head at those original positions, or continuation children are all reset to the same Y coordinate. A Row containing 100 padded cards renders as one page with 174 out-of-page drawing records. Upstream renders the same document as nine pages. Adding a trailing sibling produces two native pages but leaves the same 174 invalid records on page one.

Reproduction: `/tmp/pdf-review-cases/wrapped-row.json` and `wrapped-row-tail.json`; upstream output is `wrapped-row.json.upstream.pdf`.

Suggested fix: preserve wrapped-line grouping in the measured model and paginate those lines vertically. Only split parallel children together within one actual row line.

### 4. P1: the default loader reads local image files named by a generated spec

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Render/PDFImageLoader.swift:28`.

The contract's default policy is HTTP(S) and data URLs, but the default implementation also reads arbitrary `file:` URLs accessible to the host process. A spec can embed a local image into the exported PDF without the host opting into filesystem access. App sandboxing limits which files are reachable; it does not prevent reading the app's own accessible documents or an unsandboxed macOS process's files.

Verified with `local-file.json`, pointing at a local reference PNG. The default renderer reports a real `.image`, rather than a placeholder, and embeds it in the output.

Suggested fix: remove `file:` from the default loader. Hosts that need local images can supply a loader with an explicit directory or file allowlist.

### 5. P2: pagination discards resized child heads when there is no tail

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Layout/Paginator.swift:122`, also `:150`.

`split` correctly scales a too-tall image at page top, but its parent returns the original box when `tail.isEmpty`, discarding the adjusted `head` children. An A4 page whose only child is an Image with width 400 and height 2,000 draws the original rectangle at `(40, 40, 400, 2000)`. Adding a following Text makes the same image scale correctly to about 152.4 by 761.9 points because the parent then has a tail. Output depends on the presence of an unrelated next sibling.

Reproduction: `giant-image.json` versus `giant-image-tail.json` in `/tmp/pdf-review-cases`. Both render successfully; the former draws outside the page.

Suggested fix: rebuild and return a head box from the transformed children even when no continuation remains, in both column and row splitting.

### 6. P2: a table row taller than a page is drawn beyond the page boundary

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Layout/Paginator.swift:174`.

When no body row fits at page top, `splitTable` unconditionally includes the header and first body row. A one-column table with a sufficiently long string in its first body cell returns two pages but 408 out-of-page drawing records. Much of that cell is clipped by the PDF page and lost. The header-repetition behavior works for ordinary rows, but there is no oversized-row fallback.

Reproduction: `/tmp/pdf-review-cases/giant-table-row.json`, with explicit nullable column options so validation succeeds.

Suggested fix: define a bounded fallback for rows that cannot fit on any page. For example, split such a row at cell line boundaries while repeating the header, or explicitly truncate/clip it with a diagnostic. Never paint the full row outside the physical page.

### 7. P2: vertical flex and justification props have no effect

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Layout/LayoutEngine.swift:96` and `Render/PDFRenderer.swift:84`.

Column layout receives only available width and stacks natural child heights. It never uses vertical `flex` weights or `justifyContent`. On a Page containing `Column { flex: 1, justifyContent: "space-between" }` with Text children "Top" and "Bottom", native output puts both at the top, 13.2 points apart. Upstream puts "Bottom" at the bottom of the available page area. These are advertised catalog props and part of the requested layout subset.

Reproduction: `/tmp/pdf-review-cases/column-flex.json`; native and upstream PDFs plus extracted text bounds are recorded in `/tmp/pdf-review-comparisons.log`.

Suggested fix: pass the available main-axis size through layout, allocate column flex space, and apply the selected justification to the remaining height before pagination.

### 8. P2: PageNumber totals can change wrapping after pagination is finished

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Model/DocumentBuilder.swift:16` and `Render/PDFDrawer.swift:202`.

The layout pass always measures the format with page 1 and total 1. The drawing pass substitutes the real total and computes new text lines inside the old rectangle without relayout. A PageNumber inside an otherwise ordinary Row gets its natural width from "1 / 1". In a 16-page document, it draws two lines per page, with the total on the second line. With `marginBottom: 0`, a 15-page variant draws that second line at Y 841.89 through 852.89, outside A4, on fourteen pages.

Reproduction: `/tmp/pdf-review-cases/page-number-two-digit.json` and `page-number-two-digit-zero-margin.json`; their `.report.json` files contain the substituted line rectangles.

Suggested fix: reserve a safe width/height for page numbers or repeat measurement and pagination with actual totals until geometry stabilizes. Drawing should use the measured lines and must not introduce additional unreserved lines.

### 9. P2: a zero-width table column paints over the next column

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Layout/TextEngine.swift:125` and `Render/PDFDrawer.swift:164`.

An actual zero-width text region is replaced with a one-point width, and drawing is not clipped to its cell. Glyphs wider than that region still draw. With columns of `0%` and `100%`, the first header's "W-" and the second header's "B" are both painted at `(46, 46)`. The page-level bounds checks pass despite the overlapping cells. This also affects cells squeezed below their padding or below one glyph's width.

Reproduction: `/tmp/pdf-review-cases/zero-table.json`; `zero-table.report.json` records both texts at the identical origin.

Suggested fix: avoid laying out/drawing text when the content width is zero, and enforce cell clipping or a documented minimum-width policy for very narrow columns. Test containment within cells as well as pages.

### 10. P2: finite input numbers can produce non-finite drawing coordinates

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Model/SpecResolver.swift:21`, `Model/DocumentBuilder.swift:329`, and `Layout/TextEngine.swift:130`.

Filtering individual numbers with `isFinite` does not make subsequent addition and multiplication safe. `fontSize: 1e308` passes validation and the resolver, then produces text records whose Y coordinates are NaN. `padding: 1e308` produces infinite dimensions. Width strings are parsed separately without a finite check. Negative geometry also remains unchecked: negative page margins place ordinary text outside the page. The renderer still returns success.

Reproduction: `huge-font.json`, `huge-padding.json`, and `negative-margin.json` under `/tmp/pdf-review-cases`. The final probe represents non-finite coordinates as strings so its own JSON reporting does not abort.

Suggested fix: constrain numeric geometry to sensible finite ranges at the renderer boundary, independently of optional TS validation. Check derived dimensions before pagination and before calling Core Graphics, and reject or replace invalid width strings.

### 11. P2: image timeout cannot return until a cancellation-ignoring loader finishes

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Render/PDFImageLoader.swift:92`.

The task-group race cancels its losing child, but exiting a structured task group waits for that child to finish. A loader backed by a non-cancellable callback or synchronous I/O therefore defeats `imageTimeout`. A loader that resumes after 1.5 seconds made `loadAll` take approximately 1.6 seconds with a 20 ms timeout. A loader that never resumes can keep the render suspended indefinitely. The built-in synchronous file path is also not cancellable through this mechanism.

Reproduction: `/tmp/pdf-review-probe timeout`; the callback deliberately ignores task cancellation and eventually finishes, so the probe itself does not hang.

Suggested fix: require and document cooperative cancellation for injected loaders, or implement a separately managed worker whose deadline does not wait for an uncooperative operation. Ensure the default supported transports have bounded cancellation behavior.

### 12. P2: cancelling a stale render does not stop its rendering work

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Render/PDFRenderer.swift:67` and `Preview/JSONRenderPDFView.swift:50`.

The preview checks cancellation only after the complete PDF is produced. The renderer itself has no cancellation checks during resolution, layout, pagination, or drawing. A task cancelled immediately after creation still successfully returns the 10,000-page reproduction's PDF. During streaming, obsolete renders continue consuming CPU and memory even though their results are eventually suppressed by the preview.

Reproduction: `/tmp/pdf-review-cancel.swift`; `/tmp/pdf-review-cancel.log` records a cancelled render returning 10,000 pages successfully.

Suggested fix: check cancellation before expensive stages and periodically within long traversal, pagination, and drawing loops, and propagate `CancellationError`. Keep the final preview check to prevent stale publication.

### 13. P2: changing preview state options leaves the displayed PDF stale

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Preview/JSONRenderPDFView.swift:36`.

The render task's identity includes only `spec`. Changing `options.state` while keeping the same spec updates the SwiftUI view but does not restart its task. An NSHostingView probe renders a `$state: "/name"` Text with "FIRST", replaces the root view with equivalent configuration using "SECOND", and still reports only "FIRST" after waiting. `onPDFRender` is not called again. Hosts using external state overrides display outdated document data.

Reproduction: `/tmp/pdf-review-preview.swift` and `/tmp/pdf-review-preview.log`.

Suggested fix: include render-affecting state and timeout options in the task identity. Provide an explicit render/cache key or another invalidation mechanism for image loaders, since closures cannot be compared for equality.

### 14. P2: image loading has no byte, pixel, or concurrency budget

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Render/PDFImageLoader.swift:23`, `:42`, `:67`, and `:77`.

The default transport buffers the entire response before checking its status or whether it is an image. Data URLs are copied and decoded without a size limit. Every distinct source starts concurrently, decoded image dimensions are unrestricted, and the drawer retains decoded images for the document. A local HTTP probe returned 33,554,432 arbitrary bytes and the default loader accepted the entire response. A document can multiply this allocation across many sources or use compressed images with very large decoded pixel counts. The time limit does not cap memory use.

Suggested fix: stream with a per-image and per-document byte limit, reject oversized data payloads before decoding, validate pixel counts before full image decode, bound concurrent loads, and downsample images to a rendering-appropriate size. Keep placeholder behavior when a budget is exceeded.

### 15. P2: Table validation rejects the optional column props taught by the prompt

Location: `packages/swiftui/src/validate.ts:281`; advertised shape in `docs/system-prompt-pdf.sample.txt:38`.

The prompt explicitly teaches `columns: Array<{ header: string, width?: string, align?: ... }>`, but omitted nullable values are filled only at the top level of component props. A Table with `columns: [{ header: "Name" }]` and `rows: [["value"]]` fails validation for missing `width` and `align`. Adding `width: null, align: null` makes the same document valid. Both upstream and native rendering have defaults for these column options. Ordinary model output following the prompt can therefore be rejected.

Reproduction: `/tmp/pdf-review-ts.mts`; output in `/tmp/pdf-review-ts-probe.log`.

Suggested fix: consistently normalize omitted nullable values within nested object and array schemas, preserving expression objects. Alternatively, make those nested props required in the prompt, but that would contradict the current omission/default policy. Add a test for a Table using only column headers.

## Contract deviations

These reproduce upstream behavior. They are findings against the requested native contract, not claims of upstream incompatibility.

### 16. P2: small Views split even when they fit whole on the next page

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Model/DocumentBuilder.swift:179`.

Every View is assigned `.flow`, so it splits between children without using the keep-together path. With a 740-point Spacer followed by a View containing two short Text children, "Card heading" remains on page one and "Card body" moves to page two. The whole View would easily fit on page two. `docs/PDF.md` explicitly requires Rows/Views to move whole when they fit on one page.

Reproduction: `/tmp/pdf-review-cases/view-keep.json` and `/tmp/pdf-review-comparisons.log`.

Suggested fix: use keep-together behavior for Views that fit within a page, falling back to child splitting only for taller Views. If free splitting is preferred for upstream parity, amend the contract explicitly.

### 17. P2: PageNumber participates in flow instead of occupying the bottom margin

Location: `swift/JSONRenderSwiftUI/Sources/JSONRenderPDF/Model/DocumentBuilder.swift:386` and `Render/PDFDrawer.swift:79`.

The contract requires a fixed PageNumber in the bottom margin area. The implementation returns a normal flow node and reuses its landing rectangle on later pages. In `number-overlap-center.json`, page two draws the number at Y 40, above "Next page". On the preceding page, its repeated rectangle overlaps the bottom body's text rectangle. The existing tests deliberately assert the flow behavior, so passing tests do not satisfy this part of the contract.

Suggested fix: make PageNumber a fixed footer with reserved geometry outside the body flow, or explicitly revise the contract to adopt upstream's flow-positioned fixed text. Independently fix the total-dependent measurement issue in finding 8.

## Validation and reproducibility

- `cd swift/JSONRenderSwiftUI && xcrun swift test`: passed, 76 shared/runtime tests plus 21 PDF tests. Log: `/tmp/pdf-review-swift-test.log`.
- `xcodebuild -scheme JSONRenderSwiftUI-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test`: passed, the same 76 plus 21 tests. Log: `/tmp/pdf-review-ios-test.log`.
- Root `pnpm -r test`: passed, six files and 103 TypeScript tests. Log: `/tmp/pdf-review-ts-test.log`.
- Optimized `xcrun swift build -c release --product JSONRenderPDF`: passed. Public rendering API also compiled from a Swift 6 MainActor caller. The release nesting probe then reproduced SIGBUS at depth 1,000.
- `/tmp/pdf-review-fuzz.py` ran 176 isolated subprocess probes: every one of the 62 `statement.jsonl` line prefixes, 100 reproducible fixture mutations with seed 64810, and 14 targeted cases. Final results: four renderer crashes, zero subprocess timeouts at eight seconds, and fifteen cases with drawing outside the physical page or non-finite coordinates. The 10,000-page no-progress case terminates at the hard cap rather than hanging. Artifacts: `/tmp/pdf-review-cases/results.json`, per-case specs and reports, `/tmp/pdf-review-fuzz.log`, and `/tmp/pdf-review-probe.swift`.
- An initial probe revision itself aborted when JSON serialization encountered NaN/infinity in diagnostic rectangles. That reporting bug was corrected and the entire corpus rerun. Those aborts are excluded from the four renderer crashes above.
- The image timeout, immediate cancellation, mounted preview state update, local-file image, and 32 MiB local HTTP response were separately exercised. The HTTP probe used loopback only.
- The four upstream fixtures were re-extracted into `/tmp/pdf-review-extraction` and compared byte for byte with the checked-in JSON. All match. The statement stream finishes at the expected spec. Prompt snapshot and repeat parity tests pass.
- Visual inspection covered all five native/reference first-page pairs. Fixture text, ordinary multipage totals, repeating table headers, and normal link annotation coordinate conversion pass the existing tests. No additional repeat scoping, state-merge, missing-child, standard-default, metadata-injection, or Sendable defect was verified.

Standalone debug probe build, after the requested Swift tests:

```sh
xcrun swiftc -parse-as-library -swift-version 6 \
  -I swift/JSONRenderSwiftUI/.build/debug \
  -L swift/JSONRenderSwiftUI/.build/debug \
  -lJSONRenderPDF -lJSONRenderSwiftUI \
  /tmp/pdf-review-probe.swift -o /tmp/pdf-review-probe
```

The probe needs the two package resource bundles alongside the executable. The review used symlinks in `/tmp` to `JSONRenderSwiftUI_JSONRenderPDF.bundle` and `JSONRenderSwiftUI_JSONRenderSwiftUI.bundle` in `.build/debug`. Geometry reports use the renderer's internal drawing records, so they detect attempted painting beyond the page even when PDF clipping hides it from extracted text.
