# json-render documentation pattern research

Research target: /Volumes/External/Developer/json-render/apps/web (Next.js, Fumadocs MDX, @vercel/geistdocs). The source describes a broader TypeScript SDK; use its information architecture and presentation as a pattern, translating examples and package names for the Swift SDK.

## 1. Information architecture

Primary source: content/docs/meta.json. Items are in displayed sidebar order; ---Label--- entries are group headings. The final api entry nests content/docs/api/meta.json.

    Documentation
    ├─ Getting Started
    │  ├─ Introduction (index.mdx)
    │  ├─ Installation (installation.mdx)
    │  ├─ Quick Start (quick-start.mdx)
    │  ├─ Skills (skills.mdx)
    │  ├─ Migration Guide (migration.mdx)
    │  └─ Changelog (changelog.mdx)
    ├─ Core
    │  ├─ Specs (specs.mdx)
    │  ├─ Schemas (schemas.mdx)
    │  ├─ Catalog (catalog.mdx)
    │  ├─ Data Binding (data-binding.mdx)
    │  ├─ Computed Values (computed-values.mdx)
    │  ├─ Visibility (visibility.mdx)
    │  ├─ Watchers (watchers.mdx)
    │  ├─ Validation (validation.mdx)
    │  └─ Directives (directives.mdx)
    ├─ Rendering
    │  ├─ Renderers (renderers.mdx)
    │  ├─ Registry (registry.mdx)
    │  ├─ Streaming (streaming.mdx)
    │  └─ Generation Modes (generation-modes.mdx)
    ├─ Examples → Browse All Examples (/examples; separate app route)
    ├─ Guides
    │  ├─ Custom Schema & Renderer (custom-schema.mdx)
    │  ├─ Code Export (code-export.mdx)
    │  └─ Devtools (devtools.mdx)
    ├─ Experimental
    │  └─ Jev (Experimental) (jev.mdx)
    └─ Integrations
       ├─ AI SDK Integration (ai-sdk.mdx)
       ├─ A2UI Integration (a2ui.mdx)
       ├─ Adaptive Cards Integration (adaptive-cards.mdx)
       ├─ AG-UI Integration (ag-ui.mdx)
       ├─ OpenAPI Integration (openapi.mdx)
       └─ API Reference (api/)
          ├─ @json-render/core
          ├─ @json-render/react
          ├─ @json-render/next
          ├─ @json-render/tanstack-start
          ├─ @json-render/react-pdf
          ├─ @json-render/react-email
          ├─ @json-render/shadcn
          ├─ @json-render/shadcn-svelte
          ├─ @json-render/react-native
          ├─ @json-render/image
          ├─ @json-render/remotion
          ├─ @json-render/ink
          ├─ @json-render/vue
          ├─ @json-render/svelte
          ├─ @json-render/solid
          ├─ @json-render/react-three-fiber
          ├─ @json-render/directives
          ├─ @json-render/codegen
          ├─ @json-render/devtools
          ├─ @json-render/devtools-react
          ├─ @json-render/devtools-vue
          ├─ @json-render/devtools-svelte
          ├─ @json-render/devtools-solid
          ├─ @json-render/mcp
          ├─ @json-render/redux
          ├─ @json-render/zustand
          ├─ @json-render/jotai
          ├─ @json-render/xstate
          └─ @json-render/yaml

The API files are manually ordered in api/meta.json. Renderer overviews live in one conceptual renderers.mdx comparison page, while detailed APIs are at api/<package>.mdx; each page title uses the full scoped package. The React Native API page is a useful detailed renderer pattern: grouped standard components, provider setup, registry, hooks, catalog exports.

**Getting started pages:** installation.mdx is an install matrix, with one section per renderer/integration, package commands, and peer dependencies or requirements. quick-start.mdx is a task walkthrough with numbered headings, file-path comments in snippets, and a final “Next steps” list. For Swift, the direct equivalent is SPM installation and a small end-to-end app example covering catalog/spec/render/action handling.

**Landing:** content/docs/index.mdx is a prose introduction, not a card directory. It has a one-sentence definition, explains the problem and approach, then a three-step “How json-render Works” progression (catalog → generated spec → native render) with code, a “Key Concepts” link glossary, and “Next” links to Installation and Quick Start. The separate root marketing page is app/(main)/page.tsx.

## 2. Page anatomy and content pattern

- Frontmatter is sparse YAML with title only. No docs-page descriptions, icons, or sidebar metadata appear in MDX. Ordering and labels are in JSON metadata.
- Headings are descriptive and task-oriented. Tutorials use numbered H2 steps; concepts explain mechanism and syntax, usually one heading per feature/operator and a quick-reference/table section; package references group by Components, Providers, Hooks, Types/Exports. Many guide and concept pages end with “Next” and 2–5 related links. Quick start uses “Next steps”.
- Voice is concise, confident, developer-facing, and imperative (“Create…”, “Use…”, “Pass…”). Intro sentences state scope/outcome; paragraphs explain constraints or behavior. Assumes familiarity with the language/platform.
- Code is central: fenced blocks carry language tags (typescript, tsx, json, bash) and often a filename comment such as // app/api/generate/route.ts. Fence titles are not generally used. Examples can be substantial, complete snippets. Tables describe props/types, comparisons and quick references, often raw HTML rather than pipe Markdown.
- Installation uses custom PackageInstall, which creates npm/pnpm/yarn/bun tabs. It appears beneath per-renderer headings; peer dependencies or requirements follow.
- No shared Steps, Tabs/TabItem, Callout, Cards, or TypeTable components were found. Numbered headings provide steps; code samples are generally single fences; warnings/experimental notes use amber bordered divs or Markdown blockquotes; tables are authored directly. The runtime is Geistdocs/Fumadocs MDX.
- Globally wired custom MDX components in mdx-components.tsx are GenerationModesDiagram and PackageInstall. Pages also use page-specific interactive embeds (e.g. JsonRenderDevtools, OpenAPIForm) through docs component wiring. No Playground component appears in docs source; the interactive playground is a separate /playground route.
- Tables are raw HTML or Markdown, not TypeTable. Code uses Shiki highlighting, copy button and expansion for long blocks; there is not consistent filename chrome (filename is commonly a comment).

**Starlight translation:** Steps/Step can replace numbered tutorial sections for compact guided flows; retain headings where durable deep links matter. Tabs/TabItem can show SPM or platform alternatives. Aside is a structured equivalent to amber notes/blockquotes. CardGrid/LinkCard can turn concept/index groupings into cards, though current pages mostly use bullets. Starlight has no direct built-in TypeTable; use Markdown tables or a custom Astro component for Swift declarations. Interactive examples can use Astro components or hydrated islands in MDX; a web-compatible live Swift demo would be a new feature, unlike current docs.

### Abridged representative pages

**Quick start — content/docs/quick-start.mdx (about 214 lines):** title frontmatter; outcome promise (“in 5 minutes”); four numbered sections—define catalog, define components/registry, create API route, render UI—with file comments and complete TypeScript/TSX examples; optional shadcn alternative; ending links into catalog, data binding, actions, visibility and component API. Tutorial-first, with an end-to-end working path.

**Renderer API — content/docs/api/react-native.mdx (about 300 lines):** title is @json-render/react-native, followed by one-sentence purpose. Standard Components is split into Layout, Content, Input, Feedback and Composite, with component/props/description tables. Providers include signature blocks and prop tables; later sections cover registry definition, hooks and catalog exports. Detail is reference-like, not tutorial-like; shared concepts link to guides.

**Concept — content/docs/data-binding.mdx (about 310 lines):** starts with State Model, then JSON pointer and expression syntax, with subheads for $state, $item and $index. Repeat and two-way binding each get their own sections; bindings are split by target prop; examples interleave with explanation; Quick Reference table and advanced external-store section follow; ends with Next links. Syntax is introduced incrementally with examples.

**Core API — content/docs/api/core.mdx (roughly 680 lines):** a long reference page organized by exported function/concept (defineCatalog, schema system, SpecStream, utilities, prompt builders). Each export generally has an H2 heading, concise description and typed example; subordinate configuration/return types and method lists use H3 and tables. Useful as a reference precedent, though a Swift API may merit multiple pages as symbols grow.

## 3. Custom MDX and Starlight equivalents

| Existing pattern | Purpose | Starlight approach |
|---|---|---|
| PackageInstall + CodeTabs | npm/pnpm/yarn/bun install commands | Tabs/TabItem; for Swift show SPM since package managers are not equivalent alternatives |
| Numbered H2 tutorial headings | Step-by-step walkthrough | Keep headings for deep links; optionally Steps/Step for short flows |
| Amber bordered div / blockquote | Experimental, warning or qualification | Aside with caution or note type |
| Bullets of related topics | Key concepts / next links | Keep bullets, or use CardGrid + LinkCard on an index |
| Raw HTML / Markdown tables | Props, component lists, syntax matrices | Markdown tables; custom TypeTable only if Swift signature rendering warrants it |
| GenerationModesDiagram and demo components | Diagram and interactive embeds | Astro component for static diagrams; hydrated island for interactions |
| Code MDX mapping | Shiki, copy, expand | Starlight/Shiki blocks; use language tag and optional title="path/to/file.swift" |

## 4. Visual style

Sources: app/globals.css, app/layout.tsx, components/header.tsx, lib/geistdocs/config.tsx.

- Minimal Vercel/Geist monochrome: white light canvas and near-black text; dark mode has black canvas and near-white text. Borders, cards, muted surfaces and copy are grayscale. Radius is 0.5rem; links understated and high contrast; spacing generous with thin neutral borders.
- Core light tokens: --background oklch(1 0 0), --foreground oklch(0.1 0 0), --card oklch(0.98 0 0), --muted oklch(0.92 0 0), --muted-foreground oklch(0.45 0 0), --border oklch(0.85 0 0). Dark .dark-theme: background oklch(0 0 0), foreground oklch(0.98 0 0), card oklch(0.08 0 0), muted oklch(0.15 0 0), muted text oklch(0.6 0 0), border oklch(0.25 0 0). Accent stays neutral except status/caution and syntax colors.
- Geist Sans body, Geist Mono code, Geist Pixel Square only for the json-render wordmark. Shiki themes have cyan/teal strings, pink keywords, violet functions on neutral/transparent code panels.
- Header brand is a small Vercel triangle, slash separator and json-render wordmark; docs config also has plain text logo. Nav: Docs, Playground, Examples, search, GitHub and theme toggle. For Swift, retain monochrome restraint and substitute SDK branding; no elaborate illustration system is needed.

## 5. Examples pattern

Examples are not individual MDX sidebar pages. Separate /examples route is driven by lib/examples.ts and app/(main)/examples/page.tsx: page heading and short description, selectable tag pills, then responsive cards. Each card has title, one-sentence description, framework/use-case badges, and optional Live Demo and Source (GitHub) links. Tags cover framework, tooling and use case; examples include React Native/Expo alongside web, terminal, image, email and video. No per-example walkthrough or embedded preview on this index. A Swift version could catalog examples with iOS/SwiftUI/UIKit badges, screenshots or demos when available, and source links.

## npm compatibility check

Checked with npm view on 2026-10-25 (Europe/London): astro latest is 7.4.2 and @astrojs/starlight latest is 0.42.7. Starlight 0.42.7 declares peer dependencies astro: ^7.2.10 and @astrojs/markdown-remark: ^7.3.0, so Astro 7.4.2 satisfies the declared Astro range. Commands: npm view astro version; npm view @astrojs/starlight version; npm view @astrojs/starlight peerDependencies --json.
