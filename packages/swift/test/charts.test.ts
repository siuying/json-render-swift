import { readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  catalog,
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

describe.each([
  ["swiftui", catalog, form],
  ["pdf", pdfCatalog, doc],
] as const)("%s catalog charts", (_, cat, wrap) => {
  for (const type of ["BarChart", "LineChart"]) {
    it(`${type} accepts inline data`, () => {
      const spec = wrap({
        type,
        props: { data: sales, xKey: "region", yKey: "amount" },
      });
      expect(validateSpecForCatalog(cat, spec).issues).toEqual([]);
    });

    it(`${type} accepts $state data, aggregate, color and height`, () => {
      const spec = wrap(
        {
          type,
          props: {
            title: "Sales",
            data: { $state: "/sales" },
            xKey: "region",
            yKey: "amount",
            aggregate: "avg",
            color: "#16a34a",
            height: 240,
          },
        },
        { sales },
      );
      expect(validateSpecForCatalog(cat, spec).issues).toEqual([]);
    });

    it(`${type} rejects an unknown aggregate and a missing xKey`, () => {
      const spec = wrap({
        type,
        props: { data: sales, yKey: "amount", aggregate: "median" },
      });
      const issues = validateSpecForCatalog(cat, spec).issues;
      expect(issues.some((i) => i.path?.includes("aggregate"))).toBe(true);
      expect(issues.some((i) => i.path?.includes("xKey"))).toBe(true);
    });
  }
});

describe("chart fixtures", () => {
  it("cover inline data, state with aggregate, a date series and empty data", () => {
    expect(chartFixtures).toEqual([
      "bar-inline.json",
      "bar-state-aggregate.json",
      "line-date-series.json",
      "line-empty.json",
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
