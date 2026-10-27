import { readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  catalog,
  chartRules,
  pdfCatalog,
  validateSpecForCatalog,
  validateSwiftUISpec,
} from "../src/index";
import { readJSON, repoDir } from "./helpers";

const chartsDir = join(repoDir, "fixtures", "charts");
const chartFixtures = readdirSync(chartsDir)
  .filter((file) => file.endsWith(".json"))
  .sort();

const form = (chart: object, state?: object) => ({
  root: "form",
  elements: {
    form: { type: "Form", props: {}, children: ["section"] },
    section: { type: "Section", props: {}, children: ["chart"] },
    chart: { ...chart, children: [] },
  },
  ...(state ? { state } : {}),
});

const doc = (chart: object, state?: object) => ({
  root: "doc",
  elements: {
    doc: { type: "Document", props: {}, children: ["page"] },
    page: { type: "Page", props: { size: "A4" }, children: ["chart"] },
    chart: { ...chart, children: [] },
  },
  ...(state ? { state } : {}),
});

const sales = [
  { region: "West", amount: 10 },
  { region: "East", amount: "20" },
];

/** Each chart type with its category and value prop names. */
const chartTypes = [
  ["BarChart", "xKey", "yKey"],
  ["LineChart", "xKey", "yKey"],
  ["AreaChart", "xKey", "yKey"],
  ["PieChart", "nameKey", "valueKey"],
] as const;

describe.each([
  ["swiftui", catalog, form],
  ["pdf", pdfCatalog, doc],
] as const)("%s catalog charts", (_, cat, wrap) => {
  for (const [type, nameKey, valueKey] of chartTypes) {
    const keys = { [nameKey]: "region", [valueKey]: "amount" };

    it(`${type} validates an accessibility summary`, () => {
      const props = { data: sales, ...keys, accessibilitySummary: "Sales doubled." };
      expect(validateSpecForCatalog(cat, wrap({ type, props })).valid).toBe(true);
      expect(validateSpecForCatalog(cat, wrap({ type, props: { ...props, accessibilitySummary: 42 } })).valid).toBe(false);
    });

    it(`${type} accepts a press event with datum parameters`, () => {
      expect(validateSpecForCatalog(cat, wrap({ type, props: { data: sales, ...keys }, on: { press: { action: "setState", params: { statePath: "/selected", value: { $datum: "" } } } } })).valid).toBe(true);
    });

    it(`${type} accepts inline data`, () => {
      const spec = wrap({ type, props: { data: sales, ...keys } });
      expect(validateSpecForCatalog(cat, spec).issues).toEqual([]);
    });

    it(`${type} accepts inline data wrapped in an object's data array`, () => {
      const spec = wrap({ type, props: { data: { data: sales }, ...keys } });
      expect(validateSpecForCatalog(cat, spec).issues).toEqual([]);
    });

    it(`${type} rejects data that is neither records nor { data: records }`, () => {
      for (const data of [{ rows: sales }, "sales", [1, 2]]) {
        const spec = wrap({ type, props: { data, ...keys } });
        const issues = validateSpecForCatalog(cat, spec).issues;
        expect(issues.some((i) => i.path?.endsWith("/props/data")), JSON.stringify(data)).toBe(true);
      }
    });

    it(`${type} accepts $state data, aggregate and height`, () => {
      const spec = wrap(
        {
          type,
          props: {
            title: "Sales",
            data: { $state: "/sales" },
            ...keys,
            aggregate: "avg",
            height: 240,
          },
        },
        { sales },
      );
      expect(validateSpecForCatalog(cat, spec).issues).toEqual([]);
    });

    it(`${type} rejects an unknown aggregate and a missing ${nameKey}`, () => {
      const spec = wrap({
        type,
        props: { data: sales, [valueKey]: "amount", aggregate: "median" },
      });
      const issues = validateSpecForCatalog(cat, spec).issues;
      expect(issues.some((i) => i.path?.includes("aggregate"))).toBe(true);
      expect(issues.some((i) => i.path?.includes(nameKey))).toBe(true);
    });
  }

  for (const type of ["BarChart", "LineChart", "AreaChart"]) {
    it(`${type} accepts a color`, () => {
      const spec = wrap({
        type,
        props: { data: sales, xKey: "region", yKey: "amount", color: "#16a34a" },
      });
      expect(validateSpecForCatalog(cat, spec).issues).toEqual([]);
    });
  }

  for (const [type, nameKey, valueKey] of [chartTypes[0], chartTypes[3]]) {
    it(`${type} validates category caps`, () => {
      const props = { data: sales, [nameKey]: "region", [valueKey]: "amount", maxCategories: 2, otherLabel: "Rest" };
      expect(validateSpecForCatalog(cat, wrap({ type, props })).valid).toBe(true);
      for (const maxCategories of [0, -1, 1.5, "2"]) {
        expect(validateSpecForCatalog(cat, wrap({ type, props: { ...props, maxCategories } })).valid).toBe(false);
      }
    });
  }

  it("BarChart accepts live orientation and data bindings", () => {
    expect(validateSpecForCatalog(cat, wrap({ type: "BarChart", props: { data: { $state: "/rows" }, horizontal: { $state: "/horizontal" }, xKey: "x", yKey: "y" } }, { rows: [], horizontal: false })).valid).toBe(true);
  });

  it("BarChart validates horizontal", () => {
    const props = { data: sales, xKey: "region", yKey: "amount" };
    expect(validateSpecForCatalog(cat, wrap({ type: "BarChart", props: { ...props, horizontal: true } })).issues).toEqual([]);
    expect(validateSpecForCatalog(cat, wrap({ type: "BarChart", props: { ...props, horizontal: "yes" } })).valid).toBe(false);
  });

  it("BarChart validates a separate labelKey", () => {
    const valid = wrap({ type: "BarChart", props: { data: sales, xKey: "region", yKey: "amount", labelKey: "label" } });
    expect(validateSpecForCatalog(cat, valid).issues).toEqual([]);
    const invalid = wrap({ type: "BarChart", props: { data: sales, xKey: "region", yKey: "amount", labelKey: 42 } });
    expect(validateSpecForCatalog(cat, invalid).issues.some((i) => i.path?.endsWith("/props/labelKey"))).toBe(true);
  });

  it("PieChart accepts donut, colors and legend", () => {
    const spec = wrap({
      type: "PieChart",
      props: {
        data: sales,
        nameKey: "region",
        valueKey: "amount",
        donut: true,
        colors: ["#2563eb", "#16a34a"],
        legend: false,
      },
    });
    expect(validateSpecForCatalog(cat, spec).issues).toEqual([]);
  });

  it("PieChart rejects a non-boolean donut and colors that are not a list", () => {
    const spec = wrap({
      type: "PieChart",
      props: { data: sales, nameKey: "region", valueKey: "amount", donut: "yes", colors: "#2563eb" },
    });
    const paths = validateSpecForCatalog(cat, spec).issues.map((i) => i.path ?? "");
    expect(paths.some((p) => p.endsWith("/props/donut"))).toBe(true);
    expect(paths.some((p) => p.endsWith("/props/colors"))).toBe(true);
  });

  it("describes PieChart's count as counting every row", () => {
    const prompt = cat.prompt();
    expect(prompt).toContain('"count" of all rows (any valueKey, e.g. an id)');
    expect(prompt).toContain('"avg" of the positive valueKey values');
  });

  it("puts the chart rules in the prompt", () => {
    const prompt = cat.prompt();
    for (const rule of chartRules) expect(prompt).toContain(rule);
  });
});

describe("chart fixtures", () => {
  it("cover inline data, state with aggregate, date series, a donut and empty data", () => {
    expect(chartFixtures).toEqual([
      "area-date-series.json",
      "bar-accessible.json",
      "bar-capped.json",
      "bar-horizontal-long-labels.json",
      "bar-horizontal.json",
      "bar-inline.json",
      "bar-label-key.json",
      "bar-live.json",
      "bar-press.json",
      "bar-state-aggregate.json",
      "line-date-series.json",
      "line-empty.json",
      "pie-empty.json",
      "pie-inline.json",
      "pie-state-aggregate-donut.json",
    ]);
  });

  for (const file of chartFixtures) {
    it(`${file} validates with no issues`, () => {
      expect(
        validateSwiftUISpec(catalog, readJSON(join(chartsDir, file))),
      ).toEqual({ valid: true, issues: [] });
    });
  }
});
