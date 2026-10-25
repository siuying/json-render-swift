import { resolvePropValue } from "@json-render/core";
import { pdfFormFieldTypes } from "./pdf-forms";
import type { SwiftUISpecIssue } from "./validate";

const FIELD_TYPES = new Set<string>(pdfFormFieldTypes);
const CHOICE_TYPES = new Set(["RadioGroup", "Select", "ListBox"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function pointer(segments: (string | number)[]): string {
  return segments
    .map((s) => `/${String(s).replace(/~/g, "~0").replace(/\//g, "~1")}`)
    .join("");
}

/** True when an expression can differ between repeat items ($item/$index/$bindItem or a bare ${field}). */
function dependsOnItem(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(dependsOnItem);
  if (!isRecord(value)) return false;
  if ("$item" in value || "$index" in value || "$bindItem" in value)
    return true;
  if (
    typeof value.$template === "string" &&
    /\$\{(?!\/)[^}]+\}/.test(value.$template)
  ) {
    return true;
  }
  return Object.values(value).some(dependsOnItem);
}

interface NamePart {
  /** Statically known partial name, undefined when it depends on runtime/repeat values. */
  text: string | undefined;
  /** Differs per repeat item. */
  varies: boolean;
}

/**
 * Form-field checks for catalogs with FieldSet/TextInput/... (docs/PDF-FORMS.md):
 * - fully qualified names (FieldSet names joined with ".") are unique across fields and
 *   FieldSets (one PDF field-tree namespace); duplicates are errors
 * - Checkbox exportValue and RadioGroup option values are button appearance states: not
 *   "Off" (reserved off state) and not empty
 * - partial names are non-empty and contain no "." (PDF partial field names cannot)
 * - inside a repeat, a field whose full name does not vary per item is a warning (every copy
 *   would share one name; the renderer then suffixes #2, #3)
 * - literal choice options have unique values, and a literal value is one of them
 * Walks from the root like the renderer; unreachable elements are ignored.
 */
export function pdfFormFieldIssues(
  spec: Record<string, unknown>,
): SwiftUISpecIssue[] {
  const issues: SwiftUISpecIssue[] = [];
  if (!isRecord(spec.elements) || typeof spec.root !== "string") return issues;
  const elements = spec.elements;
  const state = isRecord(spec.state) ? spec.state : {};
  /** Fully qualified name -> first element using it. FieldSets and fields share one namespace. */
  const names = new Map<string, { key: string; fieldSet: boolean }>();

  const register = (
    qualified: string,
    key: string,
    fieldSet: boolean,
    namePath: string,
  ) => {
    const first = names.get(qualified);
    if (first === undefined) {
      names.set(qualified, { key, fieldSet });
      return;
    }
    const kinds =
      first.fieldSet === fieldSet
        ? fieldSet
          ? "two FieldSets"
          : "two fields"
        : "a FieldSet and a field";
    issues.push({
      severity: "error",
      message: `${namePath}: duplicate form field name "${qualified}", used by ${kinds} (also element "${first.key}"). Field and FieldSet names must be unique per document.`,
      path: namePath,
      code: "duplicate_field_name",
    });
  };

  /** Button appearance states: "Off" is the PDF's reserved off state, and a state needs a name. */
  const checkStateName = (value: unknown, path: string, what: string) => {
    if (value === "Off" || value === "") {
      issues.push({
        severity: "error",
        message: `${path}: ${what} ${JSON.stringify(value)} is not allowed; "Off" is the PDF's reserved off state and the value must be non-empty.`,
        path,
        code: "reserved_value",
      });
    }
  };

  const namePart = (value: unknown, inRepeat: boolean): NamePart => {
    if (typeof value === "string") return { text: value, varies: false };
    if (inRepeat) return { text: undefined, varies: dependsOnItem(value) };
    const resolved = resolvePropValue(value, { stateModel: state });
    return {
      text: typeof resolved === "string" ? resolved : undefined,
      varies: false,
    };
  };

  const checkChoices = (
    key: string,
    type: string,
    props: Record<string, unknown>,
  ) => {
    if (!Array.isArray(props.options)) return;
    const values = new Set<string>();
    props.options.forEach((option, i) => {
      if (!isRecord(option) || typeof option.value !== "string") return;
      if (values.has(option.value)) {
        const path = pointer(["elements", key, "props", "options", i, "value"]);
        issues.push({
          severity: "error",
          message: `${path}: duplicate option value "${option.value}"; option values must be unique.`,
          path,
          code: "duplicate_option",
        });
      }
      values.add(option.value);
    });

    const value = props.value;
    const path = pointer(["elements", key, "props", "value"]);
    const notAnOption = (v: string) =>
      issues.push({
        severity: "error",
        message: `${path}: "${v}" is not one of the option values (${[...values].map((x) => `"${x}"`).join(", ")}).`,
        path,
        code: "invalid_option_value",
      });
    if (typeof value === "string") {
      const freeText = type === "Select" && props.editable === true;
      if (value !== "" && !freeText && !values.has(value)) notAnOption(value);
    } else if (type === "ListBox" && Array.isArray(value)) {
      for (const v of value) {
        if (typeof v === "string" && v !== "" && !values.has(v)) notAnOption(v);
      }
      if (value.length > 1 && props.multiSelect !== true) {
        issues.push({
          severity: "warning",
          message: `${path}: several values selected but multiSelect is not true; only one can be selected.`,
          path,
          code: "invalid_option_value",
        });
      }
    }
  };

  const walk = (
    key: string,
    prefix: string[] | undefined,
    prefixVaries: boolean,
    inRepeat: boolean,
    ancestors: Set<string>,
  ) => {
    const element = elements[key];
    if (!isRecord(element) || ancestors.has(key)) return;
    const type = element.type;
    const props = isRecord(element.props) ? element.props : {};
    let childPrefix = prefix;
    let childVaries = prefixVaries;

    if (
      type === "FieldSet" ||
      (typeof type === "string" && FIELD_TYPES.has(type))
    ) {
      const namePath = pointer(["elements", key, "props", "name"]);
      if (
        typeof props.name === "string" &&
        (props.name === "" || props.name.includes("."))
      ) {
        issues.push({
          severity: "error",
          message: `${namePath}: field names must be non-empty and must not contain "." (FieldSet nesting builds dotted names).`,
          path: namePath,
          code: "invalid_field_name",
        });
      }
      const part = namePart(props.name, inRepeat);
      const full =
        prefix !== undefined && part.text !== undefined
          ? [...prefix, part.text]
          : undefined;
      const varies = prefixVaries || part.varies;

      if (type === "FieldSet") {
        childPrefix = full;
        childVaries = varies;
        if (!inRepeat && full !== undefined) {
          register(full.join("."), key, true, namePath);
        }
      } else if (inRepeat && !varies) {
        issues.push({
          severity: "warning",
          message: `Element "${key}" is repeated but its field name does not change per item, so every copy shares one PDF field name. Use e.g. { "$template": "guest_\${id}" } for the name (or for an enclosing FieldSet).`,
          path: namePath,
          code: "repeated_field_name",
        });
      } else if (!inRepeat && full !== undefined) {
        register(full.join("."), key, false, namePath);
      }
      if (type === "Checkbox") {
        checkStateName(
          props.exportValue,
          pointer(["elements", key, "props", "exportValue"]),
          "exportValue",
        );
      }
      if (type === "RadioGroup" && Array.isArray(props.options)) {
        props.options.forEach((option, i) => {
          if (isRecord(option)) {
            checkStateName(
              option.value,
              pointer(["elements", key, "props", "options", i, "value"]),
              "radio option value",
            );
          }
        });
      }
      if (typeof type === "string" && CHOICE_TYPES.has(type)) {
        checkChoices(key, type, props);
      }
    }

    const childInRepeat = inRepeat || isRecord(element.repeat);
    const next = new Set(ancestors).add(key);
    if (Array.isArray(element.children)) {
      for (const child of element.children) {
        if (typeof child === "string") {
          walk(child, childPrefix, childVaries, childInRepeat, next);
        }
      }
    }
  };

  walk(spec.root, [], false, false, new Set());
  return issues;
}
