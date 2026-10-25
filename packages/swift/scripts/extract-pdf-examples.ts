/**
 * Extracts the upstream react-pdf example specs into fixtures/pdf/<name>.json.
 *
 *   pnpm --filter @json-render/swift extract:pdf-examples
 *
 * Source: <json-render checkout>/examples/react-pdf/lib/examples.ts (read-only). The checkout
 * defaults to a sibling of this repository; override with JSON_RENDER_DIR.
 *
 * One normalisation: upstream omits `children` on leaf elements, although its own schema
 * requires it (catalog.validate rejects the examples as published). The upstream renderer
 * treats a missing `children` as empty, so we insert `"children": []` after `props`.
 */
import { writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const upstreamDir =
  process.env.JSON_RENDER_DIR ?? resolve(repoDir, "../json-render");
const source = join(upstreamDir, "examples/react-pdf/lib/examples.ts");
const outDir = join(repoDir, "fixtures/pdf");

const { examples } = (await import(pathToFileURL(source).href)) as {
  examples: { name: string; spec: { elements: Record<string, Element> } }[];
};

type Element = Record<string, unknown>;

function withLeafChildren(spec: { elements: Record<string, Element> }) {
  const elements: Record<string, Element> = {};
  for (const [key, element] of Object.entries(spec.elements)) {
    if ("children" in element) {
      elements[key] = element;
      continue;
    }
    const { type, props, ...rest } = element;
    elements[key] = { type, props, children: [], ...rest };
  }
  return { ...spec, elements };
}

const wanted = ["invoice", "report", "resume", "letter"];
for (const name of wanted) {
  const example = examples.find((e) => e.name === name);
  if (!example)
    throw new Error(`Upstream example "${name}" not found in ${source}`);
  await writeFile(
    join(outDir, `${name}.json`),
    `${JSON.stringify(withLeafChildren(example.spec), null, 2)}\n`,
  );
  console.log(`fixtures/pdf/${name}.json`);
}
