import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { compileSpecStream, createSpecStreamCompiler } from "@json-render/core";
import type { Spec } from "@json-render/core";
import { catalog, validateSwiftUISpec } from "../src/index";
import { chunk, readJSON, readText, specsDir } from "./helpers";

const jsonl = readText(join(specsDir, "registration.jsonl"));
const expected = readJSON<Spec>(join(specsDir, "registration.json"));

describe("spec stream compiler", () => {
  it("registration.jsonl compiles to registration.json", () => {
    expect(compileSpecStream(jsonl)).toEqual(expected);
  });

  for (const size of [1, 7, 64, 333]) {
    it(`yields the same spec when chunks of ${size} chars split lines`, () => {
      const compiler = createSpecStreamCompiler<Spec>({
        root: "",
        elements: {},
      });
      let patchCount = 0;
      for (const piece of chunk(jsonl, size)) {
        const { result, newPatches } = compiler.push(piece);
        patchCount += newPatches.length;
        // Every intermediate spec is renderable: no exceptions, root resolves once set.
        expect(typeof result.elements).toBe("object");
      }
      const spec = compiler.getResult();
      expect(spec).toEqual(expected);
      expect(patchCount).toBe(jsonl.trim().split("\n").length);
    });
  }

  it("flushes a trailing line without a newline", () => {
    const compiler = createSpecStreamCompiler<Spec>({ root: "", elements: {} });
    const { newPatches } = compiler.push(jsonl.trimEnd());
    expect(newPatches.length).toBe(jsonl.trim().split("\n").length - 1);
    expect(compiler.getResult()).toEqual(expected);
  });

  it("partial specs mid-stream are structurally valid apart from pending children", () => {
    const compiler = createSpecStreamCompiler<Spec>({ root: "", elements: {} });
    const lines = jsonl.trim().split("\n");
    const half = compiler.push(`${lines.slice(0, 8).join("\n")}\n`).result;
    const issues = validateSwiftUISpec(catalog, half).issues;
    expect(issues.length).toBeGreaterThan(0);
    expect(issues.every((i) => i.code === "missing_child")).toBe(true);
  });
});
