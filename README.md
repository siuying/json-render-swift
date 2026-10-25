# json-render for Swift

**Generate dynamic, personalized forms from prompts. Safe, predictable output.**

Describe a form, and a language model writes it as a [json-render](https://github.com/vercel-labs/json-render)
spec. Swift renders it natively, as a SwiftUI form or a PDF. The model can only use components from your
catalog, and every spec is validated before it renders.

- **SwiftUI forms**: real controls with two-way binding, validation, conditional fields and actions.
- **PDF documents**: paginated layout, tables, images and page numbers.
- **Fillable PDFs**: form fields people can fill in, and you can read back as JSON.
- **Streaming**: the form builds on screen as the model writes it.

[Documentation](https://siuying.github.io/json-render-swift/)

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

The docs site's build, commands and link conventions are described in [`apps/docs/README.md`](apps/docs/README.md).

## License

MIT — see [LICENSE](LICENSE). Third-party material keeps its own license; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
