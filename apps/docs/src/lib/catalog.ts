/**
 * Reads the SwiftUI catalog straight from packages/swift/src at build time, so the
 * component, action and check tables can never drift from the catalog the LLM sees.
 */
import {
  actionDefinitions,
  builtInCheckTypes,
  checkTypeDescriptions,
  componentDefinitions,
} from "../../../../packages/swift/src/catalog";
import { pdfComponentDefinitions } from "../../../../packages/swift/src/pdf";
import { pdfFormComponentDefinitions } from "../../../../packages/swift/src/pdf-forms";

type ZodLike = { _zod: { def: Record<string, unknown> & { type: string } } };

export interface PropRow {
  name: string;
  type: string;
  required: boolean;
  /** Accepts `null` (upstream react-pdf props are nullable rather than optional). */
  nullable: boolean;
  values?: string[];
}

function unwrap(schema: ZodLike): ZodLike {
  let current = schema;
  while (["optional", "nullable"].includes(current._zod.def.type)) {
    current = current._zod.def.innerType as ZodLike;
  }
  return current;
}

/** A compact TypeScript-like rendering of a Zod schema. */
export function formatType(schema: ZodLike): string {
  const s = unwrap(schema);
  const def = s._zod.def;
  switch (def.type) {
    case "enum":
      return Object.values(def.entries as Record<string, string>)
        .map((v) => JSON.stringify(v))
        .join(" | ");
    case "literal":
      return (def.values as unknown[]).map((v) => JSON.stringify(v)).join(" | ");
    case "union":
      return (def.options as ZodLike[]).map(formatType).join(" | ");
    case "array": {
      const inner = formatType(def.element as ZodLike);
      return inner.includes("|") ? `(${inner})[]` : `${inner}[]`;
    }
    case "object": {
      const shape = (s as unknown as { shape: Record<string, ZodLike> }).shape;
      const fields = Object.entries(shape).map(
        ([k, v]) => `${k}${isOptional(v) ? "?" : ""}: ${formatType(v)}`,
      );
      return fields.length ? `{ ${fields.join("; ")} }` : "{}";
    }
    case "unknown":
    case "any":
      return "any";
    default:
      return def.type;
  }
}

/** Whether the schema (through optional/nullable wrappers) accepts null. */
export function isNullable(schema: ZodLike): boolean {
  return (schema as unknown as { safeParse(v: unknown): { success: boolean } }).safeParse(null)
    .success;
}

export function isOptional(schema: ZodLike): boolean {
  return (schema as unknown as { safeParse(v: unknown): { success: boolean } }).safeParse(
    undefined,
  ).success;
}

function rows(schema: unknown): PropRow[] {
  const shape = (schema as { shape?: Record<string, ZodLike> } | undefined)?.shape ?? {};
  return Object.entries(shape).map(([name, value]) => {
    const inner = unwrap(value);
    const values =
      inner._zod.def.type === "enum"
        ? Object.values(inner._zod.def.entries as Record<string, string>)
        : undefined;
    let type = formatType(value);
    if (name === "checks") type = "Check[]";
    if (name === "enabled") type = "VisibilityCondition";
    // The validator treats an omitted nullable prop as null, so nullable props are optional.
    const nullable = isNullable(value);
    return { name, type, required: !isOptional(value) && !nullable, nullable, values };
  });
}

export interface ComponentInfo {
  name: string;
  description: string;
  props: PropRow[];
  events: string[];
  acceptsChildren: boolean;
  example?: unknown;
}

function componentInfos(definitions: Record<string, unknown>): ComponentInfo[] {
  return Object.entries(definitions).map(([name, def]) => {
    const d = def as {
      props: unknown;
      description: string;
      events?: string[];
      slots?: string[];
      example?: unknown;
    };
    return {
      name,
      description: d.description,
      props: rows(d.props),
      events: d.events ?? [],
      acceptsChildren: (d.slots?.length ?? 0) > 0,
      example: d.example,
    };
  });
}

/** The SwiftUI forms catalog (packages/swift/src/catalog.ts). */
export const components = componentInfos(componentDefinitions);

/** The 14 PDF document components (packages/swift/src/pdf.ts). */
export const pdfComponents = componentInfos(pdfComponentDefinitions as Record<string, unknown>);

/** The PDF fillable form-field components (packages/swift/src/pdf-forms.ts). */
export const pdfFormComponents = componentInfos(pdfFormComponentDefinitions as Record<string, unknown>);

export interface ActionInfo {
  name: string;
  description: string;
  params: PropRow[];
}

export const actions: ActionInfo[] = Object.entries(actionDefinitions).map(([name, def]) => ({
  name,
  description: def.description,
  params: rows(def.params),
}));

export const checkTypes = builtInCheckTypes.map((type) => ({
  type,
  description: checkTypeDescriptions[type],
}));
