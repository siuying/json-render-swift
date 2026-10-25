import type { z } from "zod";

/**
 * Format a component's Zod props as `{ key?: type, ... }` for a system prompt.
 * Optional and nullable props are shown as optional (LLMs may omit them).
 * `typeNames` replaces the formatted type of specific prop keys (e.g. checks -> "Check[]").
 */
export function formatProps(
  props: z.ZodType | undefined,
  formatZodType: (schema: z.ZodType) => string,
  typeNames: Record<string, string> = {},
): string {
  const shape = (props as { shape?: Record<string, z.ZodType> } | undefined)
    ?.shape;
  if (!shape) return "{}";
  const entries = Object.entries(shape).map(([key, value]) => {
    // Same rule as core's formatZodType: optional/nullable wrappers are optional keys.
    const wrapper = (value as { _def?: { type?: string } })._def?.type;
    const optional = wrapper === "optional" || wrapper === "nullable";
    const type = typeNames[key] ?? formatZodType(value);
    return `${key}${optional ? "?" : ""}: ${type}`;
  });
  return entries.length > 0 ? `{ ${entries.join(", ")} }` : "{}";
}
