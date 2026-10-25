import {
  buildEditInstructions,
  defineCatalog,
  defineSchema,
} from "@json-render/core";
import type {
  PromptContext,
  SchemaDefinition,
  SchemaType,
} from "@json-render/core";
import {
  schema as reactPdfSchema,
  standardComponentDefinitions,
} from "@json-render/react-pdf/server";
import type { z } from "zod";
import { pdfFormComponentDefinitions, pdfFormRules } from "./pdf-forms";
import { formatProps } from "./prompt-format";

/** Upstream `@json-render/react-pdf` prompt rules, verbatim. */
export const pdfDocumentRules: string[] = reactPdfSchema.defaultRules ?? [];

/**
 * Native-renderer guidance that upstream's text does not cover. The Swift renderer draws
 * PageNumber in the page footer on every page (react-pdf draws it at its flow position).
 */
export const pdfNativeRules = [
  "PAGE NUMBERS: Add one PageNumber per Page, anywhere among its children (e.g. last). It is drawn in the page footer (bottom margin) on every page, not where it sits in the flow; use align (left, center, right) to position it. Never add Spacers or empty Views to push it down, and keep marginBottom at least 20 so the footer fits.",
];

/** All PDF prompt rules: upstream's, native-renderer guidance, then fillable-form rules. */
const pdfRules = [...pdfDocumentRules, ...pdfNativeRules, ...pdfFormRules];

// =============================================================================
// Prompt example (a small statement driven by state + repeat)
// =============================================================================

const exampleSpec = {
  root: "doc",
  elements: {
    doc: {
      type: "Document",
      props: { title: "Statement - March 2025", author: "Northwind Bank" },
      children: ["page"],
    },
    page: {
      type: "Page",
      props: {
        size: "A4",
        marginTop: 40,
        marginBottom: 40,
        marginLeft: 40,
        marginRight: 40,
      },
      children: ["title", "summary", "divider", "lines", "page-number"],
    },
    title: {
      type: "Heading",
      props: { text: "Account Statement", level: "h1" },
      children: [],
    },
    summary: {
      type: "Text",
      props: {
        text: {
          $template: "${/customer/name} - closing balance ${/totals/closing}",
        },
        fontSize: 10,
        color: "#6b7280",
      },
      children: [],
    },
    divider: { type: "Divider", props: {}, children: [] },
    lines: {
      type: "Column",
      props: { gap: 4 },
      repeat: { statePath: "/transactions", key: "id" },
      children: ["line"],
    },
    line: {
      type: "Row",
      props: { justifyContent: "space-between" },
      children: ["line-description", "line-amount"],
    },
    "line-description": {
      type: "Text",
      props: { text: { $template: "${date}  ${description}" }, fontSize: 10 },
      children: [],
    },
    "line-amount": {
      type: "Text",
      props: { text: { $item: "amount" }, fontSize: 10, align: "right" },
      children: [],
    },
    "page-number": {
      type: "PageNumber",
      props: { format: "Page {pageNumber} of {totalPages}" },
      children: [],
    },
  },
  state: {
    customer: { name: "Jane Appleseed" },
    totals: { closing: "$2,140.50" },
    transactions: [
      {
        id: "t1",
        date: "Mar 02",
        description: "Coffee Roasters",
        amount: "-$12.40",
      },
      { id: "t2", date: "Mar 05", description: "Salary", amount: "+$3,200.00" },
    ],
  },
};

const exampleOrder: [string, string[]][] = [
  ["doc", []],
  ["page", []],
  ["title", []],
  ["summary", ["/state/customer", "/state/totals"]],
  ["divider", []],
  [
    "lines",
    ["/state/transactions", "/state/transactions/0", "/state/transactions/1"],
  ],
  ["line", []],
  ["line-description", []],
  ["line-amount", []],
  ["page-number", []],
];

function stateAt(path: string): unknown {
  return path
    .split("/")
    .slice(2)
    .reduce<unknown>(
      (value, key) => (value as Record<string, unknown>)[key],
      exampleSpec.state,
    );
}

/** The example document shown in the PDF system prompt, as JSONL. Exported for tests. */
export const pdfPromptExampleJsonl = [
  { op: "add", path: "/root", value: exampleSpec.root },
  ...exampleOrder.flatMap(([key, statePaths]) => [
    {
      op: "add",
      path: `/elements/${key}`,
      value: exampleSpec.elements[key as keyof typeof exampleSpec.elements],
    },
    ...statePaths.map((path) => ({
      op: "add",
      path,
      // Arrays are initialised empty, then streamed one item per patch.
      value: path === "/state/transactions" ? [] : stateAt(path),
    })),
  ]),
]
  .map((patch) => JSON.stringify(patch))
  .join("\n");

// =============================================================================
// Prompt template
// =============================================================================

interface ComponentDef {
  props?: z.ZodType;
  description?: string;
  slots?: string[];
}

function pdfDocumentPrompt(context: PromptContext): string {
  const { options, formatZodType } = context;
  const components =
    (context.catalog as { components?: Record<string, ComponentDef> })
      .components ?? {};
  const inline = options.mode === "inline" || options.mode === "chat";
  const lines: string[] = [];

  lines.push(
    options.system ??
      "You are a document generator. You design printable PDF documents (invoices, reports, resumes, letters, statements) and describe them as a json-render spec.",
  );
  lines.push("");

  lines.push("OUTPUT FORMAT (JSONL, RFC 6902 JSON Patch):");
  lines.push(
    inline
      ? "Reply with 1-3 sentences, then output the patch lines inside a ```spec code fence. If no document is needed, reply with text only."
      : "Output ONLY JSONL: one JSON Patch object per line. No prose, no markdown, no code fences.",
  );
  lines.push(
    'The patches build a spec { "root": "<key>", "elements": { "<key>": <element> }, "state": { ... } }. Emit /root first, then elements top-down, adding /state patches right after the elements that read them (arrays: add [] first, then one patch per item), so the document renders progressively while streaming.',
  );
  lines.push("");
  lines.push("Example:");
  if (inline) lines.push("```spec");
  lines.push(pdfPromptExampleJsonl);
  if (inline) lines.push("```");
  lines.push("");

  lines.push("ELEMENTS:");
  lines.push(
    'Each element is { "type", "props", "children": [child keys] } plus optional "visible" and "repeat", which are siblings of "props", never inside it. Only components marked [accepts children] may have children. Optional props may be omitted or null.',
  );
  lines.push("");

  lines.push(`AVAILABLE COMPONENTS (${context.componentNames.length}):`);
  for (const [name, def] of Object.entries(components)) {
    const desc = def.description ? ` - ${def.description}` : "";
    const children = def.slots?.length ? " [accepts children]" : "";
    lines.push(
      `- ${name}: ${formatProps(def.props, formatZodType)}${desc}${children}`,
    );
  }
  lines.push("");

  lines.push("DATA (state, expressions, repeat):");
  lines.push(
    '- Put document data in /state and read it with { "$state": "/invoice/number" }, or build strings with { "$template": "Invoice ${/invoice/number}" }. Text props must resolve to strings: store amounts and dates pre-formatted ("$1,200.00", "Mar 5, 2025").',
  );
  lines.push(
    '- "repeat": { "statePath": "/items", "key": "id" } on a View/Row/Column renders its children once per array item. Inside, { "$item": "field" } reads the current item, { "$index": true } is its 0-based index, and ${field} in a $template reads the item first. Nested repeat: { "statePath": { "$item": "lines" } }.',
  );
  lines.push(
    '- Table rows cannot use repeat: give rows as string[][] or { "$state": "/table/rows" } holding string arrays. Use a repeated Row for styled per-item lines.',
  );
  lines.push(
    '- { "$cond": <condition>, "$then": <value>, "$else": <value> } picks a value; conditions use the visibility syntax below.',
  );
  lines.push(
    'Paths are JSON Pointers ("/invoice/items/0/name"), never dot notation.',
  );
  lines.push("");

  lines.push('VISIBILITY (the element-level "visible" field):');
  lines.push(
    '- { "$state": "/notes" } truthy; add "not": true to invert. { "$state": "/status", "eq": "paid" } - also "neq", and numeric "gt", "gte", "lt", "lte" (one operator per condition). Inside a repeat, use { "$item": "field", ... } or { "$index": true, ... } instead of $state.',
  );
  lines.push(
    '- [cond, cond] or { "$and": [...] } - all true; { "$or": [...] } - any true; true / false.',
  );
  lines.push("");

  lines.push("EDITING:");
  lines.push(
    'When the message includes CURRENT UI STATE, output only the patches that change it; never re-emit unchanged elements. Append a child with {"op":"add","path":"/elements/<parent>/children/-","value":"<key>"}; use "replace" for props (/elements/<key>/props/<prop>) and state values, "remove" to delete (also remove the key from its parent\'s children).',
  );
  lines.push("");
  if (options.editModes && options.editModes.length > 0) {
    lines.push(buildEditInstructions({ modes: options.editModes }, "json"));
  }

  lines.push("RULES:");
  [...pdfRules, ...(options.customRules ?? [])].forEach((rule, i) => {
    lines.push(`${i + 1}. ${rule}`);
  });

  return lines.join("\n");
}

// =============================================================================
// Schema + catalog
// =============================================================================

/**
 * Upstream's spec grammar plus an optional top-level `state`, so validation does not strip
 * the data `repeat` / `$state` / `$item` read. (Upstream's renderer consumes `spec.state`,
 * but its schema never declares it.)
 */
function withState<TDef extends SchemaDefinition>(definition: TDef): TDef {
  const spec = definition.spec as SchemaType<
    "object",
    Record<string, SchemaType>
  >;
  return {
    ...definition,
    spec: {
      ...spec,
      inner: {
        ...spec.inner,
        state: { kind: "record", inner: { kind: "any" }, optional: true },
      },
    },
  };
}

/**
 * The PDF schema: upstream `@json-render/react-pdf` (spec + catalog grammar, defaultRules)
 * with `state` declared and a document-focused prompt template. Upstream's generic core
 * prompt teaches interactive UI (events, setState tabs, $bindState inputs, pushState) that
 * a static PDF cannot use.
 */
export const pdfSchema = defineSchema(
  () => withState(reactPdfSchema.definition),
  {
    defaultRules: pdfRules,
    promptTemplate: pdfDocumentPrompt,
  },
);

export type PdfSchema = typeof pdfSchema;

/**
 * The PDF catalog: upstream's 14 standard components (unchanged) plus fillable form fields
 * (docs/PDF-FORMS.md); no actions (static documents).
 */
export const pdfCatalog = defineCatalog(pdfSchema, {
  components: {
    ...standardComponentDefinitions,
    ...pdfFormComponentDefinitions,
  },
  actions: {},
});

export type PdfCatalog = typeof pdfCatalog;

export { standardComponentDefinitions as pdfComponentDefinitions };
