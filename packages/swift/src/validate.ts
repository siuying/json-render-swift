import {
  autoFixSpec,
  validateSpec,
  VisibilityConditionStrictSchema,
} from "@json-render/core";
import type { Catalog, Spec, UIElement } from "@json-render/core";
import type { z } from "zod";
import { hasPdfFormFields } from "./pdf-forms";
import { pdfFormFieldIssues } from "./pdf-forms-validate";

export interface SwiftUISpecIssue {
  severity: "error" | "warning";
  message: string;
  /** JSON Pointer into the spec, e.g. "/elements/email/props/checks/0" */
  path?: string;
  /**
   * core SpecIssue code, or "schema" | "props" | "expression" | "unsupported_expression" |
   * "unknown_prop" | "unknown_event" | "unknown_action" | "unknown_check" | "action_params" |
   * "invalid_repeat" | form fields: "duplicate_field_name" | "invalid_field_name" |
   * "repeated_field_name" | "duplicate_option" | "invalid_option_value"
   */
  code?: string;
}

export interface ValidateSpecOptions {
  /** Custom validation function names the host registers; suppresses `unknown_check`. */
  hostValidators?: string[];
  /** Custom action names the host registers; suppresses `unknown_action`. */
  hostActions?: string[];
}

export interface SwiftUISpecValidation {
  valid: boolean;
  issues: SwiftUISpecIssue[];
}

interface ComponentDef {
  props?: z.ZodType;
  events?: string[];
}

interface ActionDef {
  params?: z.ZodType;
}

type Segment = string | number;

/** Element fields some catalogs support; a catalog whose schema omits one ignores it. */
const OPTIONAL_ELEMENT_FIELDS = ["repeat", "slots", "on", "watch"] as const;

/** What a catalog's spec grammar supports, derived from its schema definition. */
interface Profile {
  /** Element fields parsed but ignored (not declared by the schema). */
  ignoredFields: string[];
  /** `repeat` is declared: $item / $index / $bindItem are in scope. */
  repeat: boolean;
  /** `on` is declared: events and `on` action bindings are validated. */
  on: boolean;
  /** `watch` is declared: `watch` action bindings are validated. */
  watch: boolean;
}

function profileFor(catalog: Catalog): Profile {
  const spec = catalog.schema.definition.spec as {
    inner?: Record<string, { inner?: { inner?: Record<string, unknown> } }>;
  };
  const declared = Object.keys(spec.inner?.elements?.inner?.inner ?? {});
  return {
    ignoredFields: OPTIONAL_ELEMENT_FIELDS.filter((f) => !declared.includes(f)),
    repeat: declared.includes("repeat"),
    on: declared.includes("on"),
    watch: declared.includes("watch"),
  };
}

/** Forms catalog behaviour (no repeat, slots ignored), for catalog-less helpers. */
const FORMS_PROFILE: Profile = {
  ignoredFields: ["repeat", "slots"],
  repeat: false,
  on: true,
  watch: true,
};

/** Props holding visibility conditions, not values: validated as-is, never as expressions. */
const CONDITION_PROPS = ["enabled"];

/** Repeat-scope expressions: supported only by catalogs that declare `repeat`. */
const REPEAT_EXPRESSION_KEYS = ["$item", "$index", "$bindItem"];

/** Never supported: no catalog registers $computed functions. */
const UNSUPPORTED_EXPRESSION_KEYS = ["$computed"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

function escapeToken(token: Segment): string {
  return String(token).replace(/~/g, "~0").replace(/\//g, "~1");
}

function pointer(segments: readonly Segment[]): string {
  return segments.map((s) => `/${escapeToken(s)}`).join("");
}

// =============================================================================
// Dynamic expressions
// =============================================================================

/**
 * How core's resolvePropValue treats a value:
 * - "state": `{ $state | $bindState: string }` (and, in repeat scope, `{ $item | $bindItem: string }`,
 *   `{ $index: true }`) — runtime value of unknown type
 * - "template": `{ $template: string }` — always a string
 * - "cond": `{ $cond: <condition>, $then, $else }` — one of the two branches
 * - "unsupported": $computed, or repeat-scope expressions in a catalog without repeat
 * - "malformed": uses an expression key but core would not resolve it as that expression
 * - null: not an expression (a literal, or a plain object/array whose members are resolved)
 */
type ExpressionKind =
  "state" | "template" | "cond" | "unsupported" | "malformed" | null;

function expressionKind(value: unknown, repeat: boolean): ExpressionKind {
  if (!isRecord(value)) return null;
  if ("$state" in value || "$bindState" in value) {
    const path = "$state" in value ? value.$state : value.$bindState;
    return typeof path === "string" ? "state" : "malformed";
  }
  if (REPEAT_EXPRESSION_KEYS.some((key) => key in value)) {
    if (!repeat) return "unsupported";
    if ("$item" in value) {
      return typeof value.$item === "string" ? "state" : "malformed";
    }
    if ("$index" in value) return value.$index === true ? "state" : "malformed";
    return typeof value.$bindItem === "string" ? "state" : "malformed";
  }
  if ("$template" in value) {
    return typeof value.$template === "string" ? "template" : "malformed";
  }
  if ("$cond" in value) {
    return "$then" in value &&
      "$else" in value &&
      VisibilityConditionStrictSchema.safeParse(value.$cond).success
      ? "cond"
      : "malformed";
  }
  if (UNSUPPORTED_EXPRESSION_KEYS.some((key) => key in value)) {
    return "unsupported";
  }
  return null;
}

interface Substitution {
  /** The value with expressions replaced by type-checkable stand-ins. */
  value: unknown;
  /** Locations whose runtime type is unknown ($state / $bindState / unsupported / malformed). */
  opaque: Segment[][];
  /** Where a $cond was replaced by a branch: issue paths under it get the branch key inserted. */
  conds: Segment[][];
  issues: SwiftUISpecIssue[];
}

/**
 * Replace expressions so Zod can type-check the result: $template becomes a string,
 * $cond becomes its `branch`, and $state / $bindState are marked opaque. The container
 * itself (props or params object) is never treated as an expression.
 */
function substitute(
  container: Record<string, unknown>,
  branch: "$then" | "$else",
  basePath: Segment[],
  repeat: boolean,
): Substitution {
  const result: Substitution = {
    value: undefined,
    opaque: [],
    conds: [],
    issues: [],
  };

  const walk = (
    value: unknown,
    path: Segment[],
    specPath: Segment[],
  ): unknown => {
    switch (expressionKind(value, repeat)) {
      case "state":
        result.opaque.push(path);
        return value;
      case "template":
        return "";
      case "cond": {
        result.conds.push(path);
        const key = branch;
        return walk((value as Record<string, unknown>)[key], path, [
          ...specPath,
          key,
        ]);
      }
      case "unsupported":
        result.opaque.push(path);
        result.issues.push({
          severity: "warning",
          message: `${pointer([...basePath, ...specPath])}: ${Object.keys(value as object).join(", ")} is not supported here and resolves to undefined.`,
          path: pointer([...basePath, ...specPath]),
          code: "unsupported_expression",
        });
        return value;
      case "malformed":
        result.opaque.push(path);
        result.issues.push({
          severity: "error",
          message: `${pointer([...basePath, ...specPath])}: malformed expression ${JSON.stringify(value)}. Use { "$state": "/path" }, { "$bindState": "/path" }, { "$template": "text \${/path}" } or { "$cond": <condition>, "$then": <value>, "$else": <value> }.`,
          path: pointer([...basePath, ...specPath]),
          code: "expression",
        });
        return value;
      default:
        if (Array.isArray(value)) {
          return value.map((item, i) =>
            walk(item, [...path, i], [...specPath, i]),
          );
        }
        if (isRecord(value)) {
          return Object.fromEntries(
            Object.entries(value).map(([k, v]) => [
              k,
              walk(v, [...path, k], [...specPath, k]),
            ]),
          );
        }
        return value;
    }
  };

  result.value = Object.fromEntries(
    Object.entries(container).map(([k, v]) => [
      k,
      CONDITION_PROPS.includes(k) ? v : walk(v, [k], [k]),
    ]),
  );
  return result;
}

function startsWith(path: readonly PropertyKey[], prefix: readonly Segment[]) {
  return prefix.every((segment, i) => String(path[i]) === String(segment));
}

/** Map a Zod issue path on the substituted value back to the spec (inserting $then/$else). */
function specPath(
  path: readonly PropertyKey[],
  conds: Segment[][],
  branch: string,
): Segment[] {
  const out: Segment[] = [];
  const matched = conds.filter((c) => startsWith(path, c));
  path.forEach((segment, i) => {
    out.push(typeof segment === "number" ? segment : String(segment));
    // Every cond nested at this depth contributes its branch key.
    for (const c of matched) if (c.length === i + 1) out.push(branch);
  });
  // Issues reported exactly at a cond location (e.g. missing branch value) still point into it.
  return out;
}

/**
 * Validate a props/params object against its Zod schema, accepting dynamic expressions in
 * member values. $template must fit a string, both $cond branches must fit, and $state /
 * $bindState are accepted as-is (their type is only known at runtime).
 */
function validateDynamic(
  schema: z.ZodType,
  container: Record<string, unknown>,
  basePath: Segment[],
  code: string,
  repeat: boolean,
): SwiftUISpecIssue[] {
  const issues: SwiftUISpecIssue[] = [];
  const seen = new Set<string>();
  for (const branch of ["$then", "$else"] as const) {
    const sub = substitute(container, branch, basePath, repeat);
    const value = sub.value as Record<string, unknown>;
    fillOmittedNullables(schema, value);
    const parsed = schema.safeParse(value);
    const found = [
      ...sub.issues,
      ...(parsed.success
        ? []
        : parsed.error.issues
            .filter(
              (issue) => !sub.opaque.some((o) => startsWith(issue.path, o)),
            )
            .map((issue) => {
              const path = pointer([
                ...basePath,
                ...specPath(issue.path, sub.conds, branch),
              ]);
              return {
                severity: "error" as const,
                message: `${path}: ${issue.message}`,
                path,
                code,
              };
            })),
    ];
    for (const issue of found) {
      const id = `${issue.path}\u0000${issue.message}`;
      if (!seen.has(id)) {
        seen.add(id);
        issues.push(issue);
      }
    }
  }
  return issues;
}

interface ZodDef {
  type?: string;
  shape?: Record<string, z.ZodType>;
  element?: z.ZodType;
  innerType?: z.ZodType;
}

function zodDef(schema: z.ZodType | undefined): ZodDef {
  return ((schema as { _def?: ZodDef } | undefined)?._def ?? {}) as ZodDef;
}

/**
 * Prompts present nullable props as optional (`key?: type`, at any depth, e.g. Table
 * `columns[].width`), so an omitted nullable key means null. Fill those in place on the
 * substituted value, recursing through objects, arrays and optional/nullable/default
 * wrappers. Expression objects are left untouched (substitute returns them as-is).
 */
function fillOmittedNullables(
  schema: z.ZodType | undefined,
  value: unknown,
): void {
  let def = zodDef(schema);
  while (
    (def.type === "optional" ||
      def.type === "nullable" ||
      def.type === "default") &&
    def.innerType
  ) {
    def = zodDef(def.innerType);
  }
  if (def.type === "array" && Array.isArray(value)) {
    for (const item of value) fillOmittedNullables(def.element, item);
    return;
  }
  if (def.type !== "object" || !def.shape || !isRecord(value)) return;
  if (expressionKind(value, true) !== null) return;
  for (const [key, prop] of Object.entries(def.shape)) {
    if (!(key in value)) {
      if (zodDef(prop).type === "nullable") value[key] = null;
    } else {
      fillOmittedNullables(prop, value[key]);
    }
  }
}

function shapeKeys(props: z.ZodType | undefined): string[] | undefined {
  const shape = (props as { shape?: Record<string, unknown> } | undefined)
    ?.shape;
  return shape ? Object.keys(shape) : undefined;
}

// =============================================================================
// Core structural view
// =============================================================================

/** `{ statePath: string | { $item: string }, key?: string }` — the shape core's repeat helpers assume. */
function isValidRepeat(repeat: unknown): boolean {
  if (!isRecord(repeat)) return false;
  const { statePath, key } = repeat;
  const pathOk =
    typeof statePath === "string" ||
    (isRecord(statePath) && typeof statePath.$item === "string");
  return pathOk && (key === undefined || typeof key === "string");
}

/**
 * core's validateSpec / autoFixSpec assume a well-typed spec and enforce repeat/slots
 * semantics. Give them a view with ignored fields removed and malformed fields neutralised;
 * the catalog's Zod grammar (and the repeat check) reports the malformed fields themselves.
 */
function structuralView(spec: Record<string, unknown>, profile: Profile): Spec {
  const elements: Record<string, UIElement> = {};
  for (const [key, element] of Object.entries(spec.elements as object)) {
    if (!isRecord(element)) {
      elements[key] = { type: "", props: {}, children: [] };
      continue;
    }
    const view: Record<string, unknown> = { ...element };
    for (const field of profile.ignoredFields) delete view[field];
    if ("repeat" in view && !isValidRepeat(view.repeat)) delete view.repeat;
    view.props = isRecord(element.props) ? element.props : {};
    view.children = Array.isArray(element.children)
      ? element.children.filter((c) => typeof c === "string")
      : [];
    elements[key] = view as unknown as UIElement;
  }
  return {
    root: typeof spec.root === "string" ? spec.root : "",
    elements,
    ...(isRecord(spec.state) ? { state: spec.state } : {}),
  };
}

// =============================================================================
// Validation
// =============================================================================

/**
 * Validate a spec against a catalog. Never throws. Element fields the catalog's schema does
 * not declare (forms: `repeat`, `slots`; PDF: `slots`, `on`, `watch`) are ignored, and
 * repeat-scope expressions are accepted only when the schema declares `repeat`.
 * 1. `catalog.validate` (spec grammar and component types)
 * 2. core `validateSpec` on a structural view (root, dangling children, misplaced fields,
 *    visible shape, repeat paths)
 * 3. per-component props and per-binding (`on` and `watch`, each when declared) action params
 *    against the catalog's Zod schemas, accepting well-formed dynamic expressions in member values
 * 4. for `pdfCatalog` only (`hasPdfFormFields`), the PDF form-field name and option checks
 */
export function validateSpecForCatalog(
  catalog: Catalog,
  spec: unknown,
  options: ValidateSpecOptions = {},
): SwiftUISpecValidation {
  if (!isRecord(spec) || !isRecord(spec.elements)) {
    return {
      valid: false,
      issues: [
        {
          severity: "error",
          message: 'Spec must be an object with "root" and "elements".',
          code: "schema",
        },
      ],
    };
  }

  const profile = profileFor(catalog);
  const issues: SwiftUISpecIssue[] = [];

  const parsed = catalog.validate(spec);
  if (!parsed.success && parsed.error) {
    for (const issue of parsed.error.issues) {
      const path = pointer(issue.path as Segment[]);
      issues.push({
        severity: "error",
        message: `${path || "/"}: ${issue.message}`,
        path,
        code: "schema",
      });
    }
  }

  if (profile.repeat) {
    for (const [key, element] of Object.entries(spec.elements)) {
      if (
        isRecord(element) &&
        "repeat" in element &&
        !isValidRepeat(element.repeat)
      ) {
        const path = pointer(["elements", key, "repeat"]);
        issues.push({
          severity: "error",
          message: `${path}: repeat must be { "statePath": "/array/path" | { "$item": "field" }, "key"?: "field" }.`,
          path,
          code: "invalid_repeat",
        });
      }
    }
  }

  for (const issue of validateSpec(structuralView(spec, profile)).issues) {
    issues.push({
      severity: issue.severity,
      message: issue.message,
      path:
        issue.elementKey !== undefined
          ? pointer(["elements", issue.elementKey])
          : undefined,
      code: issue.code,
    });
  }

  const data = catalog.data as {
    components?: Record<string, ComponentDef>;
    actions?: Record<string, ActionDef>;
  };
  const components = data.components ?? {};
  const actions = data.actions ?? {};

  const validateBindings = (
    key: string,
    field: "on" | "watch",
    trigger: string,
    binding: unknown,
  ) => {
    const bindings = Array.isArray(binding) ? binding : [binding];
    bindings.forEach((b, i) => {
      const base: Segment[] = Array.isArray(binding)
        ? ["elements", key, field, trigger, i]
        : ["elements", key, field, trigger];
      if (!isRecord(b) || typeof b.action !== "string") {
        issues.push({
          severity: "error",
          message: `${pointer(base)}: action binding must be { "action": "<name>", "params"?: {...} }.`,
          path: pointer(base),
          code: "action_params",
        });
        return;
      }
      const action = actions[b.action];
      if (!action) {
        if (options.hostActions?.includes(b.action)) return;
        issues.push({
          severity: "warning",
          message: `Element "${key}" uses action "${b.action}", which is not in the catalog; the host app must register it.`,
          path: pointer([...base, "action"]),
          code: "unknown_action",
        });
        return;
      }
      if (b.params !== undefined && !isRecord(b.params)) {
        issues.push({
          severity: "error",
          message: `${pointer([...base, "params"])}: params must be an object.`,
          path: pointer([...base, "params"]),
          code: "action_params",
        });
        return;
      }
      if (action.params) {
        issues.push(
          ...validateDynamic(
            action.params,
            b.params ?? {},
            [...base, "params"],
            "action_params",
            profile.repeat,
          ),
        );
      }
    });
  };

  /**
   * Built-in check types are type-checked by the catalog's schema. Any other string `type` is
   * a host-registered validator (core runs it from customFunctions): warn unless the host
   * declared it, and validate it only as `{ type, args?, message }`.
   */
  const checkTypes = (catalog.data as { checkTypes?: Record<string, string> })
    .checkTypes;
  const withHostChecks = (
    props: Record<string, unknown>,
    key: string,
  ): Record<string, unknown> => {
    if (!checkTypes || !Array.isArray(props.checks)) return props;
    const checks = props.checks.map((check, i) => {
      if (
        !isRecord(check) ||
        typeof check.type !== "string" ||
        Object.hasOwn(checkTypes, check.type)
      ) {
        return check;
      }
      const path = ["elements", key, "props", "checks", i];
      if (!options.hostValidators?.includes(check.type)) {
        issues.push({
          severity: "warning",
          message: `Element "${key}" uses check type "${check.type}", which is not built in; the host app must register a validator with that name or the check passes.`,
          path: pointer([...path, "type"]),
          code: "unknown_check",
        });
      }
      if (check.args !== undefined && !isRecord(check.args)) {
        issues.push({
          severity: "error",
          message: `${pointer([...path, "args"])}: check args must be an object.`,
          path: pointer([...path, "args"]),
          code: "props",
        });
      }
      // Stand in a built-in with no args so `message` is still type-checked in place.
      const { args: _args, ...rest } = check;
      return { ...rest, type: "required" };
    });
    return { ...props, checks };
  };

  for (const [key, element] of Object.entries(spec.elements)) {
    if (!isRecord(element) || typeof element.type !== "string") continue;
    const def = components[element.type];
    if (!def) continue;

    // Non-object props are reported by the grammar check.
    if (def.props && (element.props === undefined || isRecord(element.props))) {
      const props = element.props ?? {};
      issues.push(
        ...validateDynamic(
          def.props,
          withHostChecks(props, key),
          ["elements", key, "props"],
          "props",
          profile.repeat,
        ),
      );
      const known = shapeKeys(def.props);
      if (known) {
        for (const prop of Object.keys(props)) {
          if (!known.includes(prop)) {
            issues.push({
              severity: "warning",
              message: `Element "${key}" (${element.type}) has unknown prop "${prop}"; it will be ignored.`,
              path: pointer(["elements", key, "props", prop]),
              code: "unknown_prop",
            });
          }
        }
      }
    }
    if (profile.on && isRecord(element.on)) {
      for (const [event, binding] of Object.entries(element.on)) {
        if (!def.events?.includes(event)) {
          issues.push({
            severity: "warning",
            message: `Element "${key}" (${element.type}) binds event "${event}", which it never emits. Supported: ${def.events?.join(", ") || "none"}.`,
            path: pointer(["elements", key, "on", event]),
            code: "unknown_event",
          });
        }
        validateBindings(key, "on", event, binding);
      }
    }

    if (profile.watch && isRecord(element.watch)) {
      for (const [statePath, binding] of Object.entries(element.watch)) {
        validateBindings(key, "watch", statePath, binding);
      }
    }
  }

  if (hasPdfFormFields(catalog)) {
    issues.push(...pdfFormFieldIssues(spec));
  }

  return {
    valid: !issues.some((issue) => issue.severity === "error"),
    issues,
  };
}

/** Validate against the SwiftUI forms catalog (or any catalog: same as validateSpecForCatalog). */
export const validateSwiftUISpec = validateSpecForCatalog;

// =============================================================================
// Auto-fix
// =============================================================================

function autoFixWithProfile(spec: unknown, profile: Profile): unknown {
  if (!isRecord(spec) || !isRecord(spec.elements)) return spec;

  const view: Record<string, UIElement> = {};
  const held: Record<string, Record<string, unknown>> = {};
  for (const [key, element] of Object.entries(spec.elements)) {
    if (!isRecord(element)) {
      view[key] = { type: "", props: {}, children: [] };
      continue;
    }
    const rest: Record<string, unknown> = { ...element };
    const keep: Record<string, unknown> = {};
    for (const field of profile.ignoredFields) {
      if (field in rest) {
        keep[field] = rest[field];
        delete rest[field];
      }
    }
    if (rest.props !== undefined && !isRecord(rest.props)) {
      keep.props = rest.props;
      delete rest.props;
    }
    if (rest.children !== undefined && !isStringArray(rest.children)) {
      keep.children = rest.children;
      delete rest.children;
    }
    view[key] = rest as unknown as UIElement;
    held[key] = keep;
  }

  const fixed = autoFixSpec({
    root: typeof spec.root === "string" ? spec.root : "",
    elements: view,
  }).spec;

  const elements: Record<string, unknown> = {};
  for (const [key, element] of Object.entries(spec.elements)) {
    elements[key] = isRecord(element)
      ? { ...fixed.elements[key], ...held[key] }
      : element;
  }
  return { ...spec, elements };
}

/**
 * core `autoFixSpec` (move visible/on/repeat/watch out of props, prune dangling children)
 * applied safely: element fields the catalog ignores and malformed fields are hidden from
 * core and restored unchanged afterwards. Non-spec input is returned as-is. Never throws.
 */
export function autoFixSpecForCatalog(
  catalog: Catalog,
  spec: unknown,
): unknown {
  return autoFixWithProfile(spec, profileFor(catalog));
}

/** Auto-fix for the SwiftUI forms catalog (`repeat` and `slots` are ignored). */
export function autoFixSwiftUISpec(spec: unknown): unknown {
  return autoFixWithProfile(spec, FORMS_PROFILE);
}
