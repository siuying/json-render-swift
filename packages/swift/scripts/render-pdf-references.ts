/**
 * Dev-only: renders every fixtures/pdf/*.json with upstream @json-render/react-pdf
 * `renderToBuffer` into fixtures/pdf/reference/<name>.pdf, plus a first-page PNG. These are
 * the visual references for the native Swift renderer.
 *
 * PNGs come from macOS QuickLook (`qlmanage -t`, CoreGraphics with the system Helvetica
 * family, like the native renderer). Fallback: poppler's `pdftoppm`, which substitutes the
 * non-embedded standard-14 fonts (bold/italic look lighter than they are).
 *
 *   pnpm --filter @json-render/swift render:pdf-references
 */
import { execFileSync } from "node:child_process";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Spec } from "@json-render/core";
import { renderToBuffer } from "@json-render/react-pdf/render";
import { formReferenceComponents } from "./pdf-form-reference-components";

const dir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../../fixtures/pdf",
);
const outDir = join(dir, "reference");
await mkdir(outDir, { recursive: true });

function has(command: string, args: string[]): boolean {
  try {
    execFileSync(command, args, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

const pngTool = has("qlmanage", ["-h"])
  ? "qlmanage"
  : has("pdftoppm", ["-v"])
    ? "pdftoppm"
    : undefined;
if (!pngTool)
  console.warn("neither qlmanage nor pdftoppm found: skipping PNG previews");

async function firstPagePng(pdfPath: string, pngPath: string): Promise<void> {
  if (pngTool === "qlmanage") {
    const tmp = await mkdtemp(join(tmpdir(), "pdf-ref-"));
    execFileSync("qlmanage", ["-t", "-s", "1200", "-o", tmp, pdfPath], {
      stdio: "ignore",
    });
    const [thumb] = await readdir(tmp);
    if (!thumb)
      throw new Error(`qlmanage produced no thumbnail for ${pdfPath}`);
    await copyFile(join(tmp, thumb), pngPath); // tmp may be on another volume
    await rm(tmp, { recursive: true, force: true });
  } else {
    execFileSync("pdftoppm", [
      "-png",
      "-r",
      "120",
      "-f",
      "1",
      "-l",
      "1",
      "-singlefile",
      pdfPath,
      pngPath.replace(/\.png$/, ""),
    ]);
  }
}

const hasQpdf = has("qpdf", ["--version"]);

for (const file of (await readdir(dir))
  .filter((f) => f.endsWith(".json"))
  .sort()) {
  const name = file.replace(/\.json$/, "");
  const spec = JSON.parse(await readFile(join(dir, file), "utf8")) as Spec;
  // Upstream react-pdf has no chart components: nothing to compare against.
  if (
    Object.values(spec.elements).some((e) =>
      ["BarChart", "LineChart"].includes(e.type),
    )
  ) {
    console.log(`${file}: skipped (charts)`);
    continue;
  }
  // Form components (application-form) are mapped onto react-pdf's own form widgets.
  const pdf = await renderToBuffer(spec, { registry: formReferenceComponents });
  const pdfPath = join(outDir, `${name}.pdf`);
  await writeFile(pdfPath, pdf);
  const pages = (
    Buffer.from(pdf)
      .toString("latin1")
      .match(/\/Type\s*\/Page[^s]/g) ?? []
  ).length;
  let note = "";
  if (pngTool) {
    await firstPagePng(pdfPath, join(outDir, `${name}-page1.png`));
    note = `, ${name}-page1.png (${pngTool})`;
  }
  if (hasQpdf) {
    // qpdf exits 0 (ok) or 3 (warnings only); 2 means errors.
    try {
      execFileSync("qpdf", ["--check", pdfPath], { stdio: "ignore" });
      note += ", qpdf --check ok";
    } catch (error) {
      const status = (error as { status?: number }).status;
      if (status !== 3) throw new Error(`qpdf --check failed for ${pdfPath}`);
      note += ", qpdf --check warnings";
    }
  }
  console.log(
    `reference/${name}.pdf: ${pages} page(s), ${pdf.byteLength} bytes${note}`,
  );
}
