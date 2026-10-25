/**
 * Writes fixtures/pdf/{statement,application-form}.jsonl: each spec as the JSONL patch
 * stream an LLM would emit (root, elements top-down, each top-level state key right after the
 * first element that reads it, arrays streamed one item per patch).
 *
 *   pnpm --filter @json-render/swift gen:pdf-stream
 */
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

interface Spec {
  root: string;
  elements: Record<string, { children?: string[] }>;
  state?: Record<string, unknown>;
}

const dir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../../fixtures/pdf",
);

async function writeStream(name: string) {
  const spec = JSON.parse(
    await readFile(join(dir, `${name}.json`), "utf8"),
  ) as Spec;
  const patches: object[] = [{ op: "add", path: "/root", value: spec.root }];
  const pendingState = new Set(Object.keys(spec.state ?? {}));

  const emitState = (key: string) => {
    const value = spec.state![key];
    if (Array.isArray(value)) {
      patches.push({ op: "add", path: `/state/${key}`, value: [] });
      value.forEach((item, i) =>
        patches.push({ op: "add", path: `/state/${key}/${i}`, value: item }),
      );
    } else {
      patches.push({ op: "add", path: `/state/${key}`, value });
    }
    pendingState.delete(key);
  };

  const seen = new Set<string>();
  const walk = (key: string) => {
    if (seen.has(key) || !spec.elements[key]) return;
    seen.add(key);
    const element = spec.elements[key];
    patches.push({ op: "add", path: `/elements/${key}`, value: element });
    const json = JSON.stringify(element);
    for (const stateKey of [...pendingState]) {
      if (new RegExp(`/${stateKey}(?=[/"}])`).test(json)) emitState(stateKey);
    }
    element.children?.forEach(walk);
  };
  walk(spec.root);
  for (const key of Object.keys(spec.elements)) {
    if (!seen.has(key)) {
      patches.push({
        op: "add",
        path: `/elements/${key}`,
        value: spec.elements[key],
      });
    }
  }
  [...pendingState].forEach(emitState);

  await writeFile(
    join(dir, `${name}.jsonl`),
    `${patches.map((p) => JSON.stringify(p)).join("\n")}\n`,
  );
  console.log(`fixtures/pdf/${name}.jsonl: ${patches.length} patches`);
}

for (const name of ["statement", "application-form"]) {
  await writeStream(name);
}
