# json-render for Swift

json-render for Swift lets a language model generate native iOS forms and PDF documents. The model
writes a [json-render](https://github.com/vercel-labs/json-render) spec against a catalog, and a Swift
package renders it: `JSONRenderSwiftUI` draws forms with real SwiftUI controls, two-way state binding,
validation, visibility rules and actions, and `JSONRenderPDF` lays out and paginates documents built
from the PDF catalog. The catalogs, system prompts, spec validation and the JSONL stream compiler come
from a TypeScript package that is bundled into the Swift package and run with JavaScriptCore.

## Repository layout

| Path | Contents |
| --- | --- |
| `swift/JSONRender/` | Swift package with the `JSONRenderSwiftUI` and `JSONRenderPDF` libraries (iOS 26 / macOS 26). |
| `packages/swift/` | `@json-render/swift`: forms and PDF catalogs, validator, and the JavaScriptCore bridge bundle. |
| `ios/` | FormDemo, an iOS app that generates forms and documents with OpenAI or Claude (XcodeGen). |
| `apps/docs/` | Documentation site (Astro + Starlight). |
| `fixtures/` | Sample specs, recorded streams and parity fixtures shared by the tests and the demo. |
| `docs/` | Architecture and PDF contracts. |

## Commands

Requirements: Node 24+, pnpm 11, Xcode 27, XcodeGen for the demo app.

```sh
pnpm install
pnpm build              # TypeScript package, bridge bundle and docs site
pnpm test               # vitest
pnpm build:bridge       # rebuild json-render-bridge.js into the Swift package

# Swift package tests
cd swift/JSONRender && xcrun swift test
xcodebuild -scheme JSONRender-Package \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' test

# Demo app
cd ios && xcodegen generate && open FormDemo.xcodeproj

# Docs site
pnpm docs:dev           # or docs:build, docs:preview
```

See `swift/JSONRender/README.md` for the Swift API, `ios/README.md` for the demo app, and the docs
site for guides and the API reference.
