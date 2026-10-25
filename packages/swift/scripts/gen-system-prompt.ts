/**
 * Writes the generated system prompts to docs/system-prompt.sample.txt (forms) and
 * docs/system-prompt-pdf.sample.txt (PDF) so prompt changes are reviewable in diffs.
 * Tests fail when a sample is stale.
 *
 *   pnpm --filter @json-render/swift gen:prompt
 */
import { writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { catalog, pdfCatalog } from "../src/index";

const docs = join(dirname(fileURLToPath(import.meta.url)), "../../../docs");

for (const [file, prompt] of [
  ["system-prompt.sample.txt", catalog.prompt()],
  ["system-prompt-pdf.sample.txt", pdfCatalog.prompt()],
] as const) {
  await writeFile(join(docs, file), `${prompt}\n`);
  console.log(
    `docs/${file}: ${prompt.length} chars, ~${Math.round(prompt.length / 4)} tokens`,
  );
}
