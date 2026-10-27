import { readFileSync } from "node:fs";
import { defineConfig } from "tsup";

const pkg = JSON.parse(readFileSync("package.json", "utf8")) as {
  version: string;
};

export default defineConfig({
  entry: [
    "src/index.ts",
    "src/schema.ts",
    "src/catalog.ts",
    "src/pdf.ts",
    "src/bridge.ts",
  ],
  format: ["cjs", "esm"],
  dts: true,
  sourcemap: true,
  clean: true,
  external: ["@json-render/core", "@json-render/react-pdf", "zod"],
  // bridge.ts reports this from version(), as the JavaScriptCore bundle does.
  define: { __BRIDGE_VERSION__: JSON.stringify(pkg.version) },
});
