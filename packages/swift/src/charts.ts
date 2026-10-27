import { z } from "zod";

// =============================================================================
// Charts: BarChart, LineChart, AreaChart and PieChart, in both the SwiftUI and PDF
// catalogs. Both renderers process data the same way (JSONRenderSwiftUI/Model/ChartData.swift
// and PieChartData.swift).
// =============================================================================

const records = z.array(z.record(z.string(), z.unknown()));
// An array of records, or an object holding one in `data` (e.g. an API response).
const chartData = z.union([records, z.object({ data: records })]);

type Optional = <T extends z.ZodType>(schema: T) => z.ZodType;

/** Bar, line and area chart props; optional ones are wrapped by `optional` (each catalog's convention). */
function chartProps(optional: Optional) {
  return z.object({
    title: optional(z.string()),
    data: chartData,
    xKey: z.string(),
    yKey: z.string(),
    aggregate: optional(z.enum(["sum", "count", "avg"])),
    color: optional(z.string()),
    height: optional(z.number()),
  });
}

/** PieChart props: slices are named by nameKey and sized by valueKey. */
function pieChartProps(optional: Optional) {
  return z.object({
    title: optional(z.string()),
    data: chartData,
    nameKey: z.string(),
    valueKey: z.string(),
    aggregate: optional(z.enum(["sum", "count", "avg"])),
    donut: optional(z.boolean()),
    colors: optional(z.array(z.string())),
    legend: optional(z.boolean()),
    height: optional(z.number()),
  });
}

/** Prompt guidance on picking a chart, added to both catalogs' rules. */
export const chartRules = [
  "CHARTS: BarChart compares categories, LineChart shows a trend over time, AreaChart shows cumulative or volume trends (totals, traffic), and PieChart shows composition or share of a whole (a few slices). Bind chart data to state ({ \"$state\": \"/sales\" }) and let aggregate group raw rows instead of pre-computing totals.",
];

const dataHelp =
  'data is an array of objects (or an object with a "data" array), usually { "$state": "/sales" }; xKey is the category field, yKey the numeric value field (numbers or numeric strings). aggregate groups rows by xKey: "sum" or "avg" of yKey, or "count" of rows. ISO date xKey values are grouped by day and labelled like "Mar 05". color is a hex like "#2563eb"; height in points (default 300).';

const barDescription = `Bar chart with an optional title. ${dataHelp} labelKey optionally selects a display label separate from xKey; grouped records use the first label.`;
const lineDescription = `Line chart (a smooth line, no point markers) with an optional title. ${dataHelp}`;

const areaDescription = `Area chart: a smooth line with the area down to zero filled in, for cumulative or volume trends. ${dataHelp}`;
const pieDescription =
  'Pie chart (or donut: true) for composition / share of a whole, with an optional title and a legend of names and percentages (legend: false hides it). data is an array of objects (or an object with a "data" array), usually { "$state": "/expenses" }; nameKey is the slice name field, valueKey the numeric field. Slices keep data order; records whose valueKey is zero, negative or not a number are left out. aggregate groups rows by the exact nameKey value, sorted by name: "sum" or "avg" of the positive valueKey values, or "count" of all rows (any valueKey, e.g. an id). colors is a list of hex colors used in turn; height in points (default 300) for the pie, the legend goes below.';

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

const areaExample = {
  title: "Monthly signups",
  data: { $state: "/signups" },
  xKey: "month",
  yKey: "count",
};

const pieExample = {
  title: "Spending by category",
  data: { $state: "/expenses" },
  nameKey: "category",
  valueKey: "amount",
  aggregate: "sum",
  donut: true,
};

/** SwiftUI catalog charts: optional props are `.nullish()`. */
export const chartComponentDefinitions = {
  BarChart: {
    props: chartProps((schema) => schema.nullish()).extend({ labelKey: z.string().nullish() }),
    description: barDescription,
    example: barExample,
  },

  LineChart: {
    props: chartProps((schema) => schema.nullish()),
    description: lineDescription,
    example: lineExample,
  },

  AreaChart: {
    props: chartProps((schema) => schema.nullish()),
    description: areaDescription,
    example: areaExample,
  },

  PieChart: {
    props: pieChartProps((schema) => schema.nullish()),
    description: pieDescription,
    example: pieExample,
  },
};

/** PDF catalog charts: optional props are `.nullable()` (omitted = null), leaf elements. */
export const pdfChartComponentDefinitions = {
  BarChart: {
    props: chartProps((schema) => schema.nullable()).extend({ labelKey: z.string().nullable() }),
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

  AreaChart: {
    props: chartProps((schema) => schema.nullable()),
    slots: [],
    description: areaDescription,
    example: areaExample,
  },

  PieChart: {
    props: pieChartProps((schema) => schema.nullable()),
    slots: [],
    description: pieDescription,
    example: pieExample,
  },
};
