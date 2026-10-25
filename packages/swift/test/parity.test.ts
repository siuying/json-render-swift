import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { repoDir, readJSON } from "./helpers";

interface ExpressionCase {
  name: string;
  fn: string;
  expected: unknown;
  undefined?: true;
  undefinedPaths: string[];
}

function lookup(
  value: unknown,
  pointer: string,
): { found: boolean; value?: unknown } {
  let current = value;
  for (const raw of pointer.split("/").slice(1)) {
    const key = raw.replace(/~1/g, "/").replace(/~0/g, "~");
    if (current === null || typeof current !== "object" || !(key in current)) {
      return { found: false };
    }
    current = (current as Record<string, unknown>)[key];
  }
  return { found: true, value: current };
}

describe("parity fixtures", () => {
  const { description, cases } = readJSON<{
    description: string;
    cases: ExpressionCase[];
  }>(join(repoDir, "fixtures", "parity", "expressions.json"));

  it("documents undefinedPaths", () => {
    expect(description).toContain('"undefinedPaths"');
  });

  it("undefinedPaths agree with the JSON-normalised expected values", () => {
    expect(cases.length).toBeGreaterThan(0);
    for (const c of cases) {
      expect(Array.isArray(c.undefinedPaths), c.name).toBe(true);
      expect(c.undefinedPaths.includes(""), c.name).toBe(c.undefined === true);
      for (const path of c.undefinedPaths.filter((p) => p !== "")) {
        const parent = lookup(c.expected, path.slice(0, path.lastIndexOf("/")));
        expect(parent.found, `${c.name} ${path}`).toBe(true);
        const at = lookup(c.expected, path);
        // Arrays keep undefined slots as null; objects omit undefined keys.
        if (Array.isArray(parent.value)) expect(at.value, c.name).toBeNull();
        else expect(at.found, c.name).toBe(false);
      }
    }
    const byName = Object.fromEntries(cases.map((c) => [c.name, c]));
    expect(byName["array elements are resolved"]!.undefinedPaths).toEqual([
      "/2",
    ]);
    expect(
      byName["plain object values are resolved recursively"]!.undefinedPaths,
    ).toEqual(["/missing"]);
    expect(
      byName["missing bound value is omitted from resolved props"]!
        .undefinedPaths,
    ).toEqual(["/value"]);
  });
});

describe("repeat parity fixtures", () => {
  const { description, cases } = readJSON<{
    description: string;
    cases: { name: string; fn: string; expected: unknown }[];
  }>(join(repoDir, "fixtures", "parity", "repeat.json"));

  it("documents every fn and covers each", () => {
    const fns = [
      "resolvePropValue",
      "resolveBindings",
      "resolveActionParam",
      "evaluateVisibility",
      "resolveRepeatStatePath",
      "resolveRepeatItemStatePath",
      "renderTree",
    ];
    expect([...new Set(cases.map((c) => c.fn))].sort()).toEqual(
      [...fns].sort(),
    );
    for (const fn of fns) expect(description).toContain(`fn "${fn}"`);
    expect(new Set(cases.map((c) => c.name)).size).toBe(cases.length);
  });
});
