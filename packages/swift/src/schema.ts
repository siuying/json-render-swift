import { buildEditInstructions, defineSchema } from "@json-render/core";
import type { PromptContext } from "@json-render/core";
import { formatProps } from "./prompt-format";
import type { z } from "zod";

/**
 * Forms-specific rules. Exposed as `schema.defaultRules` and rendered by the
 * prompt template before any `customRules`.
 */
export const swiftUIFormRules = [
  "The root element is always a Form whose children are Sections. Put every field in a Section with a short header, grouping related fields (e.g. Account, Profile, Preferences).",
  'Bind every input to /form/<camelCaseField> with $bindState (nested paths like /form/address/city are fine) and seed every bound path in /state with a typed initial value: "" for text, true/false for Toggle, a number for Stepper/Slider, an option value for Picker, an ISO date string for DatePicker.',
  'Add checks to every field the user must fill in, with specific, friendly messages. Use validateOn "blur" on TextField/SecureField; leave the default ("submit") elsewhere.',
  'Cross-field checks: a confirm-password field uses { "type": "matches", "args": { "other": { "$state": "/form/password" } } }; an end date uses greaterThan with the start date.',
  'Conditional fields use the element-level "visible" field (e.g. { "$state": "/form/accountType", "eq": "business" }). Still seed their state. Hidden fields are skipped by validation, so they can keep "required".',
  'End the form with a last Section (no header) holding the submit Button: style "borderedProminent", on.press { "action": "submit", "params": { "data": { "$state": "/form" } } }.',
  'Pick the most specific component: SecureField for passwords, TextField with multiline for long answers, Toggle for yes/no, Picker for one-of-many (style "segmented" for 2-4 short options), Stepper for small counts, Slider for ratings and ranges, DatePicker for dates and times.',
  'Set keyboard, contentType and autocapitalization on TextFields to match the data, e.g. email: keyboard "email", contentType "email", autocapitalization "never"; phone: keyboard "phone", contentType "phone".',
  "Put helper text in a Section footer or TextField placeholder instead of extra Text elements. Use LabeledContent or Text with $template for live summaries of entered values.",
  "Use only the components, props and actions listed above. Omit optional props you do not need rather than setting them to null.",
  'Element keys are unique, short and descriptive ("email", "account", "submit-section").',
];

// =============================================================================
// Prompt example (a complete small form, emitted as JSONL)
// =============================================================================

const exampleSpec = {
  root: "form",
  elements: {
    form: {
      type: "Form",
      props: { title: "Join the Beta" },
      children: ["about", "submit-section"],
    },
    about: {
      type: "Section",
      props: {
        header: "About You",
        footer: "We only email you about the beta.",
      },
      children: ["email", "role", "role-other"],
    },
    email: {
      type: "TextField",
      props: {
        label: "Email",
        placeholder: "you@example.com",
        value: { $bindState: "/form/email" },
        keyboard: "email",
        contentType: "email",
        autocapitalization: "never",
        checks: [
          { type: "required", message: "Email is required" },
          { type: "email", message: "Enter a valid email" },
        ],
        validateOn: "blur",
      },
      children: [],
    },
    role: {
      type: "Picker",
      props: {
        label: "I am a",
        selection: { $bindState: "/form/role" },
        options: [
          { label: "Developer", value: "developer" },
          { label: "Designer", value: "designer" },
          { label: "Other", value: "other" },
        ],
        style: "segmented",
      },
      children: [],
    },
    "role-other": {
      type: "TextField",
      props: {
        label: "Your role",
        value: { $bindState: "/form/roleOther" },
        checks: [{ type: "required", message: "Tell us what you do" }],
        validateOn: "blur",
      },
      visible: { $state: "/form/role", eq: "other" },
      children: [],
    },
    "submit-section": {
      type: "Section",
      props: {},
      children: ["submit"],
    },
    submit: {
      type: "Button",
      props: { label: "Request Access", style: "borderedProminent" },
      on: {
        press: { action: "submit", params: { data: { $state: "/form" } } },
      },
      children: [],
    },
  },
  state: { form: { email: "", role: "developer", roleOther: "" } },
};

/** Patch order: root, then elements top-down with each bound field's state right after it. */
const examplePatches = [
  { op: "add", path: "/root", value: exampleSpec.root },
  ...Object.entries(exampleSpec.elements).flatMap(([key, element]) => {
    const patches: object[] = [
      { op: "add", path: `/elements/${key}`, value: element },
    ];
    for (const prop of Object.values(element.props)) {
      const bound = (prop as { $bindState?: string } | null)?.$bindState;
      if (bound?.startsWith("/form/")) {
        const field = bound.slice("/form/".length);
        patches.push({
          op: "add",
          path: `/state${bound}`,
          value:
            exampleSpec.state.form[
              field as keyof typeof exampleSpec.state.form
            ],
        });
      }
    }
    return patches;
  }),
];

/** The example form shown in the system prompt, as JSONL. Exported for tests. */
export const promptExampleJsonl = examplePatches
  .map((patch) => JSON.stringify(patch))
  .join("\n");

// =============================================================================
// Prompt template
// =============================================================================

interface ComponentDef {
  props?: z.ZodType;
  description?: string;
  slots?: string[];
  events?: string[];
}

interface ActionDef {
  description?: string;
}

interface CatalogData {
  components?: Record<string, ComponentDef>;
  actions?: Record<string, ActionDef>;
  checkTypes?: Record<string, string>;
}

function swiftUIFormPrompt(context: PromptContext): string {
  const { options, formatZodType } = context;
  const data = context.catalog as CatalogData;
  const components = data.components ?? {};
  const actions = data.actions ?? {};
  const inline = options.mode === "inline" || options.mode === "chat";
  const lines: string[] = [];

  lines.push(
    options.system ??
      "You are a form generator for a native iOS app. You design SwiftUI forms and describe them as a json-render spec.",
  );
  lines.push("");

  lines.push("OUTPUT FORMAT (JSONL, RFC 6902 JSON Patch):");
  if (inline) {
    lines.push(
      "Reply with 1-3 sentences, then output the patch lines inside a ```spec code fence. If no form is needed, reply with text only.",
    );
  } else {
    lines.push(
      "Output ONLY JSONL: one JSON Patch object per line. No prose, no markdown, no code fences.",
    );
  }
  lines.push(
    'The patches build a spec { "root": "<key>", "elements": { "<key>": <element> }, "state": { ... } }. Emit /root first, then elements top-down, adding each field\'s /state/form/<field> patch right after the element bound to it, so the form renders progressively while streaming.',
  );
  lines.push("");
  lines.push("Example:");
  if (inline) lines.push("```spec");
  lines.push(promptExampleJsonl);
  if (inline) lines.push("```");
  lines.push("");

  lines.push("ELEMENTS:");
  lines.push(
    'Each element is { "type", "props", "children": [child keys] } plus optional "visible" and "on". "visible" and "on" are siblings of "props", never inside it. Leaf elements use "children": []. Every key listed in children must be defined as an element.',
  );
  lines.push("");

  lines.push(`AVAILABLE COMPONENTS (${context.componentNames.length}):`);
  for (const [name, def] of Object.entries(components)) {
    const desc = def.description ? ` - ${def.description}` : "";
    const children = def.slots?.length ? " [accepts children]" : "";
    const events = def.events?.length
      ? ` [events: ${def.events.join(", ")}]`
      : "";
    lines.push(
      `- ${name}: ${formatProps(def.props, formatZodType, { checks: "Check[]", enabled: "Condition" })}${desc}${children}${events}`,
    );
  }
  lines.push("");

  lines.push("DYNAMIC VALUES (usable in any prop, action param or check arg):");
  lines.push(
    '- { "$bindState": "/form/email" } - two-way binding. Use on input props: value, isOn, selection.',
  );
  lines.push('- { "$state": "/form/email" } - read a state value.');
  lines.push(
    '- { "$template": "Thanks, ${/form/firstName}!" } - string with ${/path} placeholders.',
  );
  lines.push(
    '- { "$cond": <condition>, "$then": <value>, "$else": <value> } - choose a value using a visibility condition.',
  );
  lines.push(
    'Paths are JSON Pointers ("/form/address/city"), never dot notation.',
  );
  lines.push("");

  const checkTypes = data.checkTypes ?? {};
  lines.push("VALIDATION:");
  lines.push(
    'Inputs accept "checks": Check[] where Check is { "type": "<check type>", "args"?: { ... }, "message": "<shown under the field>" }, and components that list "validateOn" accept "change" | "blur" | "submit" (default "submit"); Stepper and Slider have no validateOn and validate on submit only. "enabled": <visibility condition> runs the checks only while it is true. Every check runs on submit; failing checks block the submit action.',
  );
  lines.push("Check types:");
  for (const [type, description] of Object.entries(checkTypes)) {
    lines.push(`- ${type}: ${description}`);
  }
  lines.push(
    'Example: "checks": [{ "type": "required", "message": "Zip code is required" }, { "type": "pattern", "args": { "pattern": "^[0-9]{5}$" }, "message": "Enter a 5-digit zip code" }]',
  );
  lines.push("");

  lines.push('VISIBILITY (the element-level "visible" field):');
  lines.push(
    '- { "$state": "/form/x" } - visible when the value is truthy; add "not": true to invert.',
  );
  lines.push(
    '- { "$state": "/form/x", "eq": "value" } - also "neq", and numeric "gt", "gte", "lt", "lte". One operator per condition; the compared value may be { "$state": "/path" }.',
  );
  lines.push(
    '- [cond, cond] or { "$and": [...] } - all true; { "$or": [...] } - any true; true / false - always shown / hidden.',
  );
  lines.push("");

  lines.push('ACTIONS (the element-level "on" field):');
  lines.push(
    'Map an event from the component\'s [events] to { "action": "<name>", "params": { ... } }, or to an array of such bindings run in order. Add "confirm": { "title": "...", "message": "..." } to ask before running.',
  );
  for (const [name, def] of Object.entries(actions)) {
    lines.push(`- ${name}${def.description ? `: ${def.description}` : ""}`);
  }
  lines.push("");

  lines.push("EDITING:");
  lines.push(
    'When the message includes CURRENT UI STATE, output only the patches that change it; never re-emit unchanged elements. To add a field, add its element, append its key with {"op":"add","path":"/elements/<section>/children/-","value":"<key>"}, and seed its state. Use "replace" to change a prop (path /elements/<key>/props/<prop>) and "remove" to delete an element (also remove it from its parent\'s children).',
  );
  lines.push("");
  if (options.editModes && options.editModes.length > 0) {
    lines.push(buildEditInstructions({ modes: options.editModes }, "json"));
  }

  lines.push("RULES:");
  const rules = [...swiftUIFormRules, ...(options.customRules ?? [])];
  rules.forEach((rule, i) => {
    lines.push(`${i + 1}. ${rule}`);
  });

  return lines.join("\n");
}

// =============================================================================
// Schema
// =============================================================================

/**
 * The schema for @json-render/swift
 *
 * Defines:
 * - Spec: a flat map of elements (type, props, children, visible, on, watch) plus initial state
 * - Catalog: components with props schemas, slots, events and examples; actions with params;
 *   and the validation check types described to the LLM
 */
export const schema = defineSchema(
  (s) => ({
    // What the AI-generated SPEC looks like
    spec: s.object({
      /** Root element key */
      root: s.string(),
      /** Flat map of elements by key */
      elements: s.record(
        s.object({
          /** Component type from catalog */
          type: s.ref("catalog.components"),
          /** Component props */
          props: s.propsOf("catalog.components"),
          /** Child element keys (flat reference) */
          children: s.array(s.string()),
          /** Visibility condition */
          visible: { ...s.any(), ...s.optional() },
          /** Event name -> action binding(s) */
          on: { ...s.record(s.any()), ...s.optional() },
          /** State path -> action binding(s) */
          watch: { ...s.record(s.any()), ...s.optional() },
        }),
      ),
      /** Initial state model */
      state: { ...s.record(s.any()), ...s.optional() },
    }),

    // What the CATALOG must provide
    catalog: s.object({
      /** Component definitions */
      components: s.map({
        /** Zod schema for component props */
        props: s.zod(),
        /** Use ['default'] for containers that accept children */
        slots: s.array(s.string()),
        /** Event names usable in the element's `on` field */
        events: s.array(s.string()),
        /** Description for AI generation hints */
        description: s.string(),
        /** Example prop values */
        example: s.any(),
      }),
      /** Action definitions */
      actions: s.map({
        /** Zod schema for action params */
        params: s.zod(),
        /** Description for AI generation hints */
        description: s.string(),
      }),
      /** Validation check type -> description for the prompt */
      checkTypes: s.record(s.string()),
    }),
  }),
  {
    promptTemplate: swiftUIFormPrompt,
    defaultRules: swiftUIFormRules,
  },
);

/**
 * Type for the SwiftUI schema
 */
export type SwiftUISchema = typeof schema;

/**
 * Infer the spec type from a catalog
 */
export type SwiftUISpec<TCatalog> = typeof schema extends {
  createCatalog: (catalog: TCatalog) => { _specType: infer S };
}
  ? S
  : never;
