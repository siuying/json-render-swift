import { z } from "zod";

// =============================================================================
// Charts: BarChart, LineChart, AreaChart and PieChart, in both the SwiftUI and PDF
// catalogs. Both renderers process data the same way (JSONRenderSwiftUI/Model/ChartData.swift
// and PieChartData.swift).
// =============================================================================

const records = z.array(z.record(z.string(), z.unknown()));
// An array of records, or an object holding one in `data` (e.g. an API response).
const chartData = z.union([records, z.object({ data: records })]);

const valueFormat = z.discriminatedUnion("style", [
  z.object({ style: z.literal("number"), locale: z.string().optional() }),
  z.object({ style: z.literal("percent"), locale: z.string().optional() }),
  z.object({ style: z.literal("currency"), currency: z.string().regex(/^[A-Z]{3}$/), locale: z.string().optional() }),
]).describe("Display format for mark annotations and VoiceOver; numeric values remain unchanged. Currency requires a three-letter code, e.g. HKD.");

type Optional = <T extends z.ZodType>(schema: T) => z.ZodType;

/** Bar, line and area chart props; optional ones are wrapped by `optional` (each catalog's convention). */
function chartProps(optional: Optional) {
  return z.object({
    title: optional(z.string()),
    accessibilitySummary: optional(z.string().describe("A custom chart summary for VoiceOver and audio graphs; defaults to the category count and value range.")),
    data: chartData,
    otherKey: optional(z.string().describe("Field whose truthy value marks an explicit Other group. Keeps its position unless capped; overflow merges into one Other slot. Adds isOther to $datum.")),
    xKey: z.string(),
    yKey: z.string(),
    missing: optional(z.enum(["skip", "show"]).describe("Skip unknown numeric values by default; show keeps n/a markers with a null datum value.")),
    valueFormat: optional(valueFormat),
    aggregate: optional(z.enum(["sum", "count", "avg"])),
    color: optional(z.string()),
    height: optional(z.number()),
  });
}

/** PieChart props: slices are named by nameKey and sized by valueKey. */
function pieChartProps(optional: Optional) {
  return z.object({
    title: optional(z.string()),
    accessibilitySummary: optional(z.string().describe("A custom chart summary for VoiceOver and audio graphs; defaults to the category count and value range.")),
    data: chartData,
    otherKey: optional(z.string().describe("Field whose truthy value marks an explicit Other group. Keeps its position unless capped; overflow merges into one Other slot. Adds isOther to $datum.")),
    nameKey: z.string(),
    valueKey: z.string(),
    valueFormat: optional(valueFormat),
    otherColor: optional(z.string().describe("Hex color for the Other group; otherwise use the normal palette.")),
    aggregate: optional(z.enum(["sum", "count", "avg"])),
    maxCategories: optional(z.number().int().positive().describe("Maximum displayed categories, including the final Other slot.")),
    otherLabel: optional(z.string().describe("Display name for the folded group; defaults to Other.")),
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
  'data is an array of objects (or an object with a "data" array), usually { "$state": "/sales" }; xKey is the category field, yKey the numeric value field (numbers or numeric strings). aggregate groups rows by xKey: "sum" or "avg" of yKey, or "count" of rows. ISO date xKey values are grouped by day and labelled like "Mar 05". color is a hex like "#2563eb"; height in points (default 300). missing defaults to "skip"; "show" keeps non-numeric values as n/a marks with a null datum value. valueFormat formats annotations and VoiceOver, e.g. {style: "currency", currency: "HKD"}; numeric axes and datum values stay numeric.';

const otherHelp = "otherKey names a truthy source field marking Other. Without a cap, positions and labels are preserved. When capped, explicit Other entries merge with overflow into the final Other slot. With otherKey, $datum includes isOther.";

const summaryHelp = "accessibilitySummary describes the chart for VoiceOver and audio graphs; the default states the category count and numeric range.";
const capHelp = 'maxCategories includes the Other slot: keep the top maxCategories - 1 values, breaking ties by existing order; display survivors in existing order and fold the rest. With avg, Other averages the folded source rows; otherwise it sums their displayed values. otherLabel names the folded group, default "Other".';

const barDescription = `Bar chart with an optional title. ${dataHelp} labelKey optionally selects a display label separate from xKey; grouped records use the first label. horizontal: true puts categories on the vertical axis, with wrapping labels on the left. Without an explicit height, horizontal bars grow by 34 pt per category plus axes, with a 200 pt minimum. otherColor optionally colors the Other group. ${capHelp} ${otherHelp} ${summaryHelp}`;
const lineDescription = `Line chart (a smooth line, with point markers for isolated numeric samples) with an optional title. ${dataHelp} ${otherHelp} ${summaryHelp}`;

const areaDescription = `Area chart: a smooth line with the area down to zero filled in, for cumulative or volume trends. ${dataHelp} ${otherHelp} ${summaryHelp}`;
const pieDescription =
  'Pie chart (or donut: true) for composition / share of a whole, with an optional title and a legend of names and percentages (legend: false hides it). data is an array of objects (or an object with a "data" array), usually { "$state": "/expenses" }; nameKey is the slice name field, valueKey the numeric field. Slices keep data order; records whose valueKey is zero, negative or not a number are left out. aggregate groups rows by the exact nameKey value, sorted by name: "sum" or "avg" of the positive valueKey values, or "count" of all rows (any valueKey, e.g. an id). colors is a list of hex colors used in turn; height in points (default 300) for the pie, the legend goes below. valueFormat formats displayed values and VoiceOver; otherColor colors the Other group.' + ` ${capHelp} ${otherHelp} ${summaryHelp}`;

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
    props: chartProps((schema) => schema.nullish()).extend({ labelKey: z.string().nullish(), otherColor: z.string().nullish(), horizontal: z.boolean().describe("Put categories on the vertical axis and numeric bars on the horizontal axis; false by default.").nullish(), maxCategories: z.number().int().positive().describe("Maximum displayed categories, including the final Other slot.").nullish(), otherLabel: z.string().describe("Display name for the folded group; defaults to Other.").nullish() }),
    events: ["press"],
    description: barDescription,
    example: barExample,
  },

  LineChart: {
    props: chartProps((schema) => schema.nullish()),
    events: ["press"],
    description: lineDescription,
    example: lineExample,
  },

  AreaChart: {
    props: chartProps((schema) => schema.nullish()),
    events: ["press"],
    description: areaDescription,
    example: areaExample,
  },

  PieChart: {
    props: pieChartProps((schema) => schema.nullish()),
    events: ["press"],
    description: pieDescription,
    example: pieExample,
  },
};

/** PDF catalog charts: optional props are `.nullable()` (omitted = null), leaf elements. */
export const pdfChartComponentDefinitions = {
  BarChart: {
    props: chartProps((schema) => schema.nullable()).extend({ labelKey: z.string().nullable(), otherColor: z.string().nullable(), horizontal: z.boolean().describe("Put categories on the vertical axis and numeric bars on the horizontal axis; false by default.").nullable(), maxCategories: z.number().int().positive().describe("Maximum displayed categories, including the final Other slot.").nullable(), otherLabel: z.string().describe("Display name for the folded group; defaults to Other.").nullable() }),
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
