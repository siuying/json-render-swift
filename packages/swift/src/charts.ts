import { z } from "zod";

// =============================================================================
// Charts: BarChart and LineChart, in both the SwiftUI and PDF catalogs. Both
// renderers process data the same way (JSONRenderSwiftUI/Model/ChartData.swift).
// =============================================================================

/** Chart props; optional ones are wrapped by `optional` (each catalog's convention). */
function chartProps(optional: <T extends z.ZodType>(schema: T) => z.ZodType) {
  return z.object({
    title: optional(z.string()),
    data: z.array(z.record(z.string(), z.unknown())),
    xKey: z.string(),
    yKey: z.string(),
    aggregate: optional(z.enum(["sum", "count", "avg"])),
    color: optional(z.string()),
    height: optional(z.number()),
  });
}

const dataHelp =
  'data is an array of objects, usually { "$state": "/sales" }; xKey is the category field, yKey the numeric value field (numbers or numeric strings). aggregate groups rows by xKey: "sum" or "avg" of yKey, or "count" of rows. ISO date xKey values are grouped by day and labelled like "Mar 05". color is a hex like "#2563eb"; height in points (default 300).';

const barDescription = `Bar chart with an optional title. ${dataHelp}`;
const lineDescription = `Line chart (a smooth line, no point markers) with an optional title. ${dataHelp}`;

const barExample = {
  title: "Sales by region",
  data: { $state: "/sales" },
  xKey: "region",
  yKey: "amount",
  aggregate: "sum",
};

const lineExample = {
  title: "Orders per day",
  data: { $state: "/orders" },
  xKey: "date",
  yKey: "total",
  aggregate: "count",
};

/** SwiftUI catalog charts: optional props are `.nullish()`. */
export const chartComponentDefinitions = {
  BarChart: {
    props: chartProps((schema) => schema.nullish()),
    description: barDescription,
    example: barExample,
  },

  LineChart: {
    props: chartProps((schema) => schema.nullish()),
    description: lineDescription,
    example: lineExample,
  },
};

/** PDF catalog charts: optional props are `.nullable()` (omitted = null), leaf elements. */
export const pdfChartComponentDefinitions = {
  BarChart: {
    props: chartProps((schema) => schema.nullable()),
    slots: [],
    description: barDescription,
    example: barExample,
  },

  LineChart: {
    props: chartProps((schema) => schema.nullable()),
    slots: [],
    description: lineDescription,
    example: lineExample,
  },
};
