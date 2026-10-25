// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightLinksValidator from "starlight-links-validator";
import mermaid from "astro-mermaid";

export default defineConfig({
  // GitHub Pages: https://siuying.github.io/json-render-swift/
  site: "https://siuying.github.io",
  base: "/json-render-swift",
  integrations: [
    // Must come before Starlight so ```mermaid blocks aren't turned into code blocks.
    // Rendered client-side; autoTheme follows Starlight's data-theme (neutral / dark).
    mermaid({
      theme: "neutral",
      autoTheme: true,
      enableLog: false,
      mermaidConfig: {
        fontFamily: '"Geist Variable", ui-sans-serif, system-ui, sans-serif',
        flowchart: { curve: "basis", htmlLabels: true },
        sequence: { mirrorActors: false, showSequenceNumbers: false },
      },
    }),
    starlight({
      title: "json-render for Swift",
      description:
        "Render LLM-generated json-render specs natively in Swift: SwiftUI forms with two-way binding, validation and actions, and paginated PDF documents.",
      logo: {
        light: "./src/assets/logo-light.svg",
        dark: "./src/assets/logo-dark.svg",
      },
      favicon: "/favicon.svg",
      social: [
        {
          icon: "github",
          label: "json-render for Swift on GitHub",
          href: "https://github.com/siuying/json-render-swift",
        },
      ],
      customCss: [
        "@fontsource-variable/geist",
        "@fontsource-variable/geist-mono",
        "./src/styles/theme.css",
      ],
      expressiveCode: {
        themes: ["github-dark-default", "github-light-default"],
        styleOverrides: {
          borderRadius: "0.5rem",
          borderColor: "var(--sl-color-hairline)",
          codeFontFamily: "var(--sl-font-mono)",
          uiFontFamily: "var(--sl-font)",
          frames: {
            shadowColor: "transparent",
            editorActiveTabIndicatorTopColor: "var(--sl-color-gray-3)",
            editorActiveTabIndicatorBottomColor: "transparent",
          },
        },
      },
      components: {
        // Default footer plus the license line.
        Footer: "./src/components/Footer.astro",
      },
      lastUpdated: false,
      pagination: true,
      tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
      plugins: [starlightLinksValidator({ errorOnLocalLinks: true })],
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { label: "Introduction", slug: "index" },
            "installation",
            "quick-start",
          ],
        },
        {
          label: "Core",
          items: [
            "specs",
            "catalog",
            "data-binding",
            "visibility",
            "actions",
            "watchers",
            "validation",
          ],
        },
        {
          label: "Rendering",
          items: ["rendering", "streaming", "generation"],
        },
        {
          label: "PDF",
          items: [
            { label: "Overview", slug: "pdf" },
            "pdf/quick-start",
            "pdf/catalog",
            "pdf/layout",
            "pdf/forms",
            "pdf/fillable-quick-start",
            {
              label: "Examples",
              items: [
                { label: "All PDF Examples", slug: "pdf/examples" },
                "pdf/examples/invoice",
                "pdf/examples/report",
                "pdf/examples/resume",
                "pdf/examples/letter",
                "pdf/examples/statement",
                "pdf/examples/application-form",
              ],
            },
          ],
        },
        {
          label: "Examples",
          items: [
            { label: "All Examples", slug: "examples" },
            "examples/registration",
            "examples/event-rsvp",
            "examples/feedback-survey",
            "examples/shipping-address",
          ],
        },
        {
          label: "Guides",
          items: [
            "guides/custom-components",
            "guides/custom-actions-and-validators",
            "guides/openai",
            "guides/extending-the-catalog",
            "guides/testing",
          ],
        },
        {
          label: "Demo App",
          items: [
            { label: "How the Demo Works", slug: "demo" },
            "demo/prompt-lifecycle",
            "demo/running",
          ],
        },
        {
          label: "API Reference",
          items: [
            {
              label: "Swift",
              items: [
                "api/swift/form-session",
                "api/swift/json-render-view",
                "api/swift/component-registry",
                "api/swift/state-store",
                "api/swift/action-dispatcher",
                "api/swift/json-render-bridge",
                "api/swift/spec-stream-compiler",
                "api/swift/models",
                "api/swift/runtime",
                "api/swift/repeat-scope",
              ],
            },
            {
              label: "Swift: JSONRenderPDF",
              items: [
                "api/swift/pdf-renderer",
                "api/swift/pdf-image-loader",
                "api/swift/json-render-pdf-view",
                "api/swift/pdf-render-result",
                "api/swift/pdf-forms",
              ],
            },
            {
              label: "TypeScript",
              items: ["api/typescript/swift", "api/typescript/bridge"],
            },
          ],
        },
      ],
    }),
  ],
});
