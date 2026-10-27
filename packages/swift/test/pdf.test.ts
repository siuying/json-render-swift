import { readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { compileSpecStream, createSpecStreamCompiler } from "@json-render/core";
import type { Spec } from "@json-render/core";
import {
  schema as reactPdfSchema,
  standardComponentDefinitions,
} from "@json-render/react-pdf/server";
import {
  autoFixSpecForCatalog,
  catalog,
  pdfCatalog,
  pdfDocumentRules,
  pdfPromptExampleJsonl,
  pdfFormRules,
  pdfNativeRules,
  pdfSchema,
  validateSpecForCatalog,
} from "../src/index";
import { chunk, readJSON, readText, repoDir } from "./helpers";

const pdfDir = join(repoDir, "fixtures", "pdf");
const pdfFixtures = readdirSync(pdfDir)
  .filter((file) => file.endsWith(".json"))
  .sort();
const statement = readJSON<Spec>(join(pdfDir, "statement.json"));
const statementJsonl = readText(join(pdfDir, "statement.jsonl"));

const validate = (spec: unknown) => validateSpecForCatalog(pdfCatalog, spec);
const codes = (spec: unknown) =>
  validate(spec).issues.map((i) => [i.severity, i.code, i.path]);

const doc = (elements: Record<string, unknown>, state?: object) => ({
  root: "doc",
  elements: {
    doc: { type: "Document", props: {}, children: ["page"] },
    page: {
      type: "Page",
      props: { size: "A4" },
      children: Object.keys(elements),
    },
    ...elements,
  },
  ...(state ? { state } : {}),
});

describe("pdf catalog", () => {
  it("is upstream's react-pdf catalog (unchanged) plus form fields and charts, with no actions", () => {
    expect(pdfCatalog.componentNames).toEqual([
      ...Object.keys(standardComponentDefinitions),
      "FieldSet",
      "TextInput",
      "Checkbox",
      "RadioGroup",
      "Select",
      "ListBox",
      "BarChart",
      "LineChart",
      "AreaChart",
      "PieChart",
    ]);
    const components = pdfCatalog.data.components as Record<string, unknown>;
    for (const [name, def] of Object.entries(standardComponentDefinitions)) {
      expect(components[name], name).toBe(def);
    }
    expect(pdfCatalog.actionNames).toEqual([]);
    expect(pdfDocumentRules).toEqual(reactPdfSchema.defaultRules);
    expect(pdfSchema.defaultRules).toEqual([
      ...pdfDocumentRules,
      ...pdfNativeRules,
      ...pdfFormRules,
    ]);
  });

  it("keeps state and repeat through catalog.validate", () => {
    const result = pdfCatalog.validate(statement);
    expect(result.success).toBe(true);
    expect(result.data).toEqual(statement);
    expect((result.data as Spec).state).toEqual(statement.state);
    expect((result.data as Spec).elements.accounts!.repeat).toEqual({
      statePath: "/accounts",
      key: "id",
    });
  });

  it("upstream's schema alone would strip state (the reason pdfSchema adds it)", () => {
    const upstream = reactPdfSchema.createCatalog({
      components: standardComponentDefinitions,
    });
    const result = upstream.validate(statement);
    expect(result.success).toBe(true);
    expect((result.data as Spec).state).toBeUndefined();
  });
});

describe("pdf fixtures", () => {
  it("includes the upstream examples, the statement, the application form and the sales report", () => {
    expect(pdfFixtures).toEqual([
      "application-form.json",
      "invoice.json",
      "letter.json",
      "report.json",
      "resume.json",
      "sales-report.json",
      "statement.json",
    ]);
  });

  for (const file of pdfFixtures) {
    it(`${file} validates with no issues`, () => {
      expect(validate(readJSON(join(pdfDir, file)))).toEqual({
        valid: true,
        issues: [],
      });
    });
  }

  it("statement exercises state, repeat, $item, $index, $template, visible and PageNumber", () => {
    const json = JSON.stringify(statement);
    for (const feature of [
      '"repeat"',
      '"$item"',
      '"$index"',
      '"$template"',
      '"visible"',
      '"PageNumber"',
      '"$state"',
    ]) {
      expect(json).toContain(feature);
    }
    // Nested repeat over an item-relative path.
    expect(statement.elements.txns!.repeat).toEqual({
      statePath: { $item: "transactions" },
      key: "id",
    });
  });

  it("statement.jsonl compiles to statement.json, including when chunks split lines", () => {
    expect(compileSpecStream(statementJsonl)).toEqual(statement);
    const compiler = createSpecStreamCompiler<Spec>({ root: "", elements: {} });
    for (const piece of chunk(statementJsonl, 41)) compiler.push(piece);
    expect(compiler.getResult()).toEqual(statement);
  });

  it("forms catalog rejects PDF specs", () => {
    expect(validateSpecForCatalog(catalog, statement).valid).toBe(false);
  });
});

describe("pdf validation", () => {
  it("treats omitted nullable props as null", () => {
    expect(
      validate(doc({ d: { type: "Divider", props: {}, children: [] } })),
    ).toEqual({ valid: true, issues: [] });
  });

  it("still requires non-nullable props", () => {
    expect(
      codes(doc({ h: { type: "Heading", props: {}, children: [] } })),
    ).toEqual([["error", "props", "/elements/h/props/text"]]);
  });

  it("accepts repeat-scope expressions (the forms catalog only warns)", () => {
    const spec = doc(
      {
        list: {
          type: "Column",
          props: {},
          repeat: { statePath: "/items" },
          children: ["t"],
        },
        t: {
          type: "Text",
          props: {
            text: { $item: "name" },
            fontSize: { $index: true },
            color: {
              $cond: { $index: true, eq: 0 },
              $then: "#000000",
              $else: "#666666",
            },
          },
          visible: { $item: "show" },
          children: [],
        },
      },
      { items: [{ name: "a", show: true }] },
    );
    expect(validate(spec)).toEqual({ valid: true, issues: [] });
  });

  it("rejects malformed repeat-scope expressions", () => {
    expect(
      codes(
        doc(
          {
            list: {
              type: "Column",
              props: {},
              repeat: { statePath: "/items" },
              children: ["t"],
            },
            t: {
              type: "Text",
              props: { text: { $item: 3 }, fontSize: { $index: 1 } },
              children: [],
            },
          },
          { items: [] },
        ),
      ),
    ).toEqual([
      ["error", "expression", "/elements/t/props/text"],
      ["error", "expression", "/elements/t/props/fontSize"],
    ]);
  });

  it("reports malformed repeat without throwing", () => {
    for (const repeat of [
      null,
      5,
      { statePath: 5 },
      { statePath: "/x", key: 1 },
    ]) {
      const spec = doc({
        list: { type: "Column", props: {}, repeat, children: [] },
      });
      expect(() => validate(spec)).not.toThrow();
      expect(codes(spec)).toContainEqual([
        "error",
        "invalid_repeat",
        "/elements/list/repeat",
      ]);
    }
  });

  it("applies core repeat checks", () => {
    expect(
      codes(
        doc(
          {
            list: {
              type: "Column",
              props: {},
              repeat: { statePath: "/items" },
              children: [],
            },
          },
          { items: "nope" },
        ),
      ),
    ).toEqual([
      ["error", "repeat_without_children", "/elements/list"],
      ["error", "repeat_state_mismatch", "/elements/list"],
    ]);
  });

  it("ignores fields the PDF schema does not declare (slots, on, watch)", () => {
    expect(
      validate(
        doc({
          t: {
            type: "Text",
            props: { text: "Hi" },
            children: [],
            slots: { default: ["missing"] },
            on: { press: { action: "nope" } },
            watch: 5,
          },
        }),
      ),
    ).toEqual({ valid: true, issues: [] });
  });

  it("autoFix keeps repeat in scope and moves it out of props", () => {
    const spec = doc(
      {
        list: {
          type: "Column",
          props: { repeat: { statePath: "/items" } },
          children: ["t", "ghost"],
          slots: { default: null },
        },
        t: { type: "Text", props: { text: { $item: "" } }, children: [] },
      },
      { items: ["a"] },
    );
    const fixed = autoFixSpecForCatalog(pdfCatalog, spec) as Spec;
    expect(fixed.elements.list).toEqual({
      type: "Column",
      props: {},
      children: ["t"],
      repeat: { statePath: "/items" },
      slots: { default: null },
    });
    expect(fixed.state).toEqual({ items: ["a"] });
    expect(validate(fixed)).toEqual({ valid: true, issues: [] });
  });
});

describe("pdf system prompt", () => {
  const prompt = pdfCatalog.prompt();

  it("lists every component and upstream rule", () => {
    for (const name of pdfCatalog.componentNames) {
      expect(prompt).toContain(`- ${name}: `);
    }
    for (const rule of pdfDocumentRules) {
      expect(prompt).toContain(rule);
    }
    expect(prompt).toContain('"repeat"');
    expect(prompt).toContain('{ "$item": "field" }');
  });

  it("explains that PageNumber renders in the footer (native renderer)", () => {
    expect(prompt).toContain(
      "It is drawn in the page footer (bottom margin) on every page",
    );
    expect(prompt).toContain("use align (left, center, right) to position it");
    expect(prompt).toContain(
      "Never add Spacers or empty Views to push it down",
    );
    // Our example keeps PageNumber as the Page's last child, with no Spacer before it.
    const page = JSON.parse(
      pdfPromptExampleJsonl
        .split("\n")
        .find((l) => l.includes('"/elements/page"'))!,
    ).value as { children: string[] };
    expect(page.children.at(-1)).toBe("page-number");
    expect(pdfPromptExampleJsonl).not.toContain('"Spacer"');
  });

  it("does not teach interactive features a static PDF cannot use", () => {
    for (const word of [
      "$bindState",
      "setState",
      "pushState",
      "on.press",
      "EVENTS",
    ]) {
      expect(prompt).not.toContain(word);
    }
  });

  it("has a valid example", () => {
    expect(validate(compileSpecStream(pdfPromptExampleJsonl))).toEqual({
      valid: true,
      issues: [],
    });
  });

  it("supports customRules and inline mode", () => {
    const custom = pdfCatalog.prompt({ customRules: ["Use EUR."] });
    expect(custom).toContain(`${pdfSchema.defaultRules!.length + 1}. Use EUR.`);
    expect(pdfCatalog.prompt({ mode: "inline" })).toContain("```spec");
  });

  it("matches docs/system-prompt-pdf.sample.txt (run `pnpm gen:prompt` after changing the prompt)", () => {
    expect(
      readText(join(repoDir, "docs", "system-prompt-pdf.sample.txt")),
    ).toBe(`${prompt}\n`);
  });
});
