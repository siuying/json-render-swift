import { describe, expect, it } from "vitest";
import type { Catalog } from "@json-render/core";
import type { z } from "zod";
import { catalog, pdfCatalog, validateSpecForCatalog } from "../src/index";

/**
 * Prompt/validator consistency: every prop the prompt shows as optional (`key?:`, at any
 * depth — core's formatZodType marks nullable and optional keys) must validate both when
 * omitted and when null.
 */

interface Def {
  type?: string;
  shape?: Record<string, z.ZodType>;
  element?: z.ZodType;
  innerType?: z.ZodType;
  options?: z.ZodType[];
  entries?: Record<string, string>;
  values?: unknown[];
}

const def = (schema: z.ZodType): Def =>
  (schema as unknown as { _def: Def })._def;
/** core's formatZodType rule: a key is shown as `key?:` when wrapped in optional or nullable. */
const optionalInPrompt = (schema: z.ZodType) =>
  ["optional", "nullable"].includes(def(schema).type ?? "");

function unwrap(schema: z.ZodType): z.ZodType {
  let current = schema;
  for (;;) {
    const d = def(current);
    if (
      ["optional", "nullable", "default"].includes(d.type ?? "") &&
      d.innerType
    ) {
      current = d.innerType;
    } else {
      return current;
    }
  }
}

/** A value with every optional key omitted (mode "omit") or nulled where null is allowed (mode "null"). */
function sample(schema: z.ZodType, mode: "omit" | "null"): unknown {
  const d = def(unwrap(schema));
  switch (d.type) {
    case "object": {
      const out: Record<string, unknown> = {};
      for (const [key, prop] of Object.entries(d.shape ?? {})) {
        if (optionalInPrompt(prop)) {
          if (mode === "null" && prop.safeParse(null).success) out[key] = null;
          continue;
        }
        out[key] = sample(prop, mode);
      }
      return out;
    }
    case "array":
      return [sample(d.element!, mode)];
    case "union":
      return sample(d.options![0]!, mode);
    case "enum":
      return Object.values(d.entries ?? {})[0];
    case "literal":
      return d.values?.[0];
    case "record":
      return { x: "x" };
    case "string":
      return "x";
    case "number":
      return 1;
    case "boolean":
      return true;
    default:
      return "x";
  }
}

const cases: [string, Catalog, (el: object) => object][] = [
  [
    "swiftui",
    catalog as unknown as Catalog,
    (el) => ({
      root: "form",
      elements: {
        form: { type: "Form", props: {}, children: ["section"] },
        section: { type: "Section", props: {}, children: ["el"] },
        el,
      },
    }),
  ],
  [
    "pdf",
    pdfCatalog as unknown as Catalog,
    (el) => ({
      root: "doc",
      elements: {
        doc: { type: "Document", props: {}, children: ["page"] },
        page: { type: "Page", props: { size: "A4" }, children: ["el"] },
        el,
      },
    }),
  ],
];

describe.each(cases)(
  "%s catalog: optional props validate when omitted or null",
  (_, cat, wrap) => {
    const components = (
      cat.data as { components: Record<string, { props: z.ZodType }> }
    ).components;
    const actions =
      (cat.data as { actions?: Record<string, { params: z.ZodType }> })
        .actions ?? {};

    for (const [name, component] of Object.entries(components)) {
      for (const mode of ["omit", "null"] as const) {
        it(`${name} (${mode})`, () => {
          const props = sample(component.props, mode);
          const result = validateSpecForCatalog(
            cat,
            wrap({ type: name, props, children: [] }),
          );
          expect(result.issues, JSON.stringify(props)).toEqual([]);
        });
      }
    }

    for (const [name, action] of Object.entries(actions)) {
      for (const mode of ["omit", "null"] as const) {
        it(`action ${name} (${mode})`, () => {
          const params = sample(action.params, mode);
          const result = validateSpecForCatalog(
            cat,
            wrap({
              type: "Button",
              props: { label: "Go" },
              on: { press: { action: name, params } },
              children: [],
            }),
          );
          expect(result.issues, JSON.stringify(params)).toEqual([]);
        });
      }
    }
  },
);

describe("PDF Table regression (review #15)", () => {
  const table = (props: object) =>
    cases[1]![2]({ type: "Table", props, children: [] });

  it("accepts columns with only headers", () => {
    const spec = table({
      columns: [{ header: "Name" }, { header: "Qty" }],
      rows: [["a", "1"]],
    });
    const before = JSON.stringify(spec);
    expect(
      validateSpecForCatalog(pdfCatalog as unknown as Catalog, spec),
    ).toEqual({
      valid: true,
      issues: [],
    });
    expect(JSON.stringify(spec)).toBe(before); // validation does not mutate the input
  });

  it("still rejects wrong nested types and missing headers", () => {
    const result = validateSpecForCatalog(
      pdfCatalog as unknown as Catalog,
      table({
        columns: [{ width: 50 }, { header: "B", align: "middle" }],
        rows: [["a", "b"]],
      }),
    );
    expect(result.issues.map((i) => i.path)).toEqual([
      "/elements/el/props/columns/0/header",
      "/elements/el/props/columns/0/width",
      "/elements/el/props/columns/1/align",
    ]);
  });

  it("leaves expression objects alone", () => {
    expect(
      validateSpecForCatalog(
        pdfCatalog as unknown as Catalog,
        table({
          columns: [{ header: { $template: "Name (${/unit})" } }],
          rows: { $state: "/rows" },
        }),
      ),
    ).toEqual({ valid: true, issues: [] });
  });
});
