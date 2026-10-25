/**
 * Generates fixtures/parity/*.json by running @json-render/core over hand-written
 * inputs. The Swift SDK asserts its native resolver / visibility / validation
 * engines produce the same `expected` values.
 *
 *   pnpm --filter @json-render/swift gen:fixtures
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  evaluateVisibility,
  getByPath,
  resolveActionParam,
  resolveBindings,
  resolveElementProps,
  resolvePropValue,
  resolveRepeatItemStatePath,
  resolveRepeatStatePath,
  runValidation,
} from "@json-render/core";
import type {
  PropResolutionContext,
  Spec,
  UIElement,
  ValidationConfig,
  VisibilityCondition,
} from "@json-render/core";

const outDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../../fixtures/parity",
);

// core warns on unknown validators / $computed / $bindItem; keep the output clean.
console.warn = () => {};

const UNDEFINED_NOTE =
  "JSON has no undefined: inside objects a key that resolves to undefined is omitted, inside arrays it becomes null.";

// =============================================================================
// Expressions
// =============================================================================

const exprState = {
  form: {
    name: "Ada",
    email: "ada@example.com",
    age: 36,
    ratio: 1.5,
    hundred: 100,
    agree: true,
    off: false,
    empty: "",
    nothing: null,
    zero: 0,
    tags: ["a", "b"],
    address: { city: "London" },
    plan: "pro",
  },
  "a/b": 1,
  "m~n": 2,
  count: "5",
};

type PropCase = {
  name: string;
  value: unknown;
  state?: Record<string, unknown>;
};

const propCases: PropCase[] = [
  { name: "literal string passes through", value: "hello" },
  { name: "literal number passes through", value: 42 },
  { name: "literal boolean passes through", value: false },
  { name: "null passes through", value: null },
  { name: "$state reads a string", value: { $state: "/form/name" } },
  { name: "$state reads a number", value: { $state: "/form/age" } },
  { name: "$state reads an object", value: { $state: "/form/address" } },
  { name: "$state reads null", value: { $state: "/form/nothing" } },
  {
    name: "$state missing key is undefined",
    value: { $state: "/form/missing" },
  },
  {
    name: "$state missing nested key is undefined",
    value: { $state: "/form/address/zip" },
  },
  {
    name: "$state through null is undefined",
    value: { $state: "/form/nothing/x" },
  },
  {
    name: "$state into a string is undefined",
    value: { $state: "/form/name/0" },
  },
  { name: '$state "" returns the whole state', value: { $state: "" } },
  { name: '$state "/" returns the whole state', value: { $state: "/" } },
  { name: "$state array index", value: { $state: "/form/tags/1" } },
  {
    name: "$state array index out of range is undefined",
    value: { $state: "/form/tags/5" },
  },
  {
    name: "$state array index with leading zero (parseInt)",
    value: { $state: "/form/tags/01" },
  },
  {
    name: "$state non-numeric array segment is undefined",
    value: { $state: "/form/tags/length" },
  },
  { name: "$state escaped ~1 segment", value: { $state: "/a~1b" } },
  { name: "$state escaped ~0 segment", value: { $state: "/m~0n" } },
  {
    name: "$state with non-string path is a plain object",
    value: { $state: 5 },
  },
  { name: "$bindState reads the value", value: { $bindState: "/form/email" } },
  {
    name: "$bindState missing is undefined",
    value: { $bindState: "/form/missing" },
  },
  {
    name: "$cond true picks $then",
    value: { $cond: { $state: "/form/agree" }, $then: "yes", $else: "no" },
  },
  {
    name: "$cond eq false picks $else",
    value: {
      $cond: { $state: "/form/plan", eq: "free" },
      $then: "Free",
      $else: "Paid",
    },
  },
  {
    name: "$cond branches are resolved",
    value: {
      $cond: { $state: "/form/agree" },
      $then: { $template: "Hi ${/form/name}" },
      $else: { $state: "/form/email" },
    },
  },
  {
    name: "$cond with array (AND) condition",
    value: {
      $cond: [{ $state: "/form/agree" }, { $state: "/form/age", gte: 18 }],
      $then: "adult",
      $else: "minor",
    },
  },
  {
    name: "$cond with $or condition",
    value: {
      $cond: {
        $or: [{ $state: "/form/off" }, { $state: "/form/plan", eq: "pro" }],
      },
      $then: 1,
      $else: 0,
    },
  },
  {
    name: "$cond nested in $then",
    value: {
      $cond: { $state: "/form/agree" },
      $then: { $cond: { $state: "/form/off" }, $then: "a", $else: "b" },
      $else: "c",
    },
  },
  {
    name: "$cond without $else is a plain object (values still resolved)",
    value: { $cond: { $state: "/form/name" }, $then: "x" },
  },
  {
    name: "$template interpolates",
    value: { $template: "Hello ${/form/name}!" },
  },
  {
    name: "$template missing path is empty",
    value: { $template: "[${/form/missing}]" },
  },
  {
    name: "$template null is empty",
    value: { $template: "[${/form/nothing}]" },
  },
  { name: "$template integer", value: { $template: "${/form/age} years" } },
  {
    name: "$template integral double prints without decimals",
    value: { $template: "${/form/hundred}" },
  },
  { name: "$template decimal", value: { $template: "${/form/ratio}" } },
  { name: "$template zero", value: { $template: "${/form/zero}" } },
  {
    name: "$template booleans",
    value: { $template: "${/form/agree}/${/form/off}" },
  },
  { name: "$template empty string", value: { $template: "[${/form/empty}]" } },
  {
    name: "$template array uses JS String()",
    value: { $template: "${/form/tags}" },
  },
  {
    name: "$template object uses JS String()",
    value: { $template: "${/form/address}" },
  },
  {
    name: "$template bare name falls back to /name",
    value: { $template: "Count: ${count}" },
  },
  {
    name: "$template bare missing name is empty",
    value: { $template: "[${nope}]" },
  },
  {
    name: "$template multiple placeholders",
    value: { $template: "${/form/name} <${/form/email}> on ${/form/plan}" },
  },
  {
    name: "$template without placeholders",
    value: { $template: "plain text" },
  },
  {
    name: "$template empty placeholder stays literal",
    value: { $template: "a${}b" },
  },
  { name: "$template escaped pointer", value: { $template: "${/a~1b}" } },
  {
    name: "array elements are resolved",
    value: [{ $state: "/form/name" }, "x", { $state: "/form/missing" }],
  },
  {
    name: "plain object values are resolved recursively",
    value: {
      name: { $state: "/form/name" },
      nested: { city: { $state: "/form/address/city" } },
      missing: { $state: "/form/missing" },
    },
  },
  {
    name: "$item outside a repeat is undefined (out of scope)",
    value: { $item: "title" },
  },
  {
    name: "$index outside a repeat is undefined (out of scope)",
    value: { $index: true },
  },
  {
    name: "$bindItem outside a repeat is undefined (out of scope)",
    value: { $bindItem: "title" },
  },
  {
    name: "$computed without functions is undefined (out of scope)",
    value: { $computed: "fullName" },
  },
];

type PropsCase = { name: string; props: Record<string, unknown> };

const propsCases: PropsCase[] = [
  {
    name: "TextField props: bindings, literals and check args",
    props: {
      label: "Confirm password",
      value: { $bindState: "/form/confirm" },
      placeholder: null,
      checks: [
        { type: "required", message: "Required" },
        {
          type: "matches",
          args: { other: { $state: "/form/name" } },
          message: "Must match",
        },
      ],
      validateOn: "blur",
    },
  },
  {
    name: "Stepper props with $template label",
    props: {
      label: { $template: "Guests: ${/form/age}" },
      value: { $bindState: "/form/age" },
      minimum: 1,
      maximum: 100,
    },
  },
  {
    name: "Picker props with options array",
    props: {
      label: "Plan",
      selection: { $bindState: "/form/plan" },
      options: [
        { label: "Free", value: "free" },
        { label: { $template: "Pro (${/form/name})" }, value: "pro" },
      ],
    },
  },
  {
    name: "Button props with $cond",
    props: {
      label: {
        $cond: { $state: "/form/agree" },
        $then: "Submit",
        $else: "Agree first",
      },
      disabled: { $cond: { $state: "/form/agree" }, $then: false, $else: true },
    },
  },
  {
    name: "missing bound value is omitted from resolved props",
    props: { label: "Phone", value: { $bindState: "/form/phone" } },
  },
];

/** JSON Pointers (relative to the result) of every undefined value core produced, "" for the result itself. */
function undefinedPaths(value: unknown, path = ""): string[] {
  if (value === undefined) return [path];
  if (Array.isArray(value)) {
    return value.flatMap((item, i) => undefinedPaths(item, `${path}/${i}`));
  }
  if (typeof value === "object" && value !== null) {
    return Object.entries(value).flatMap(([key, item]) =>
      undefinedPaths(
        item,
        `${path}/${key.replace(/~/g, "~0").replace(/\//g, "~1")}`,
      ),
    );
  }
  return [];
}

function expectedValue(value: unknown): {
  expected: unknown;
  undefined?: true;
  undefinedPaths: string[];
} {
  return value === undefined
    ? { expected: null, undefined: true, undefinedPaths: [""] }
    : {
        expected: JSON.parse(JSON.stringify(value)),
        undefinedPaths: undefinedPaths(value),
      };
}

const expressions = {
  description: [
    "Prop expression parity cases generated by @json-render/core (resolvePropValue, resolveElementProps, resolveBindings).",
    'Each case: { "name", "fn", "state", ...input, "expected", "undefined"?, "undefinedPaths" }.',
    'fn "resolvePropValue": input "value" (any JSON). expected = resolvePropValue(value, { stateModel: state }). When core returns undefined, "expected" is null and "undefined": true.',
    'fn "resolveElementProps": input "props" (object). expected = resolveElementProps(props, { stateModel: state }); "bindings" = resolveBindings(props, ctx) (prop name -> state path, or null when there are none).',
    UNDEFINED_NOTE,
    '"undefinedPaths" lists JSON Pointers (relative to the result; "" is the result itself) of every value core resolved to undefined, so consumers can tell undefined from null: an object key in undefinedPaths is present-but-undefined in core (and omitted from "expected"); an array index in undefinedPaths is undefined in core (and null in "expected"). Empty when the result contains no undefined.',
    "$item/$index/$bindItem/$computed are out of scope for v1: outside a repeat (and without functions) core resolves them to undefined.",
  ].join(" "),
  cases: [
    ...propCases.map(({ name, value, state = exprState }) => ({
      name,
      fn: "resolvePropValue",
      state,
      value,
      ...expectedValue(resolvePropValue(value, { stateModel: state })),
    })),
    ...propsCases.map(({ name, props }) => {
      const ctx = { stateModel: exprState };
      return {
        name,
        fn: "resolveElementProps",
        state: exprState,
        props,
        ...expectedValue(resolveElementProps(props, ctx)),
        bindings: resolveBindings(props, ctx) ?? null,
      };
    }),
  ],
};

// =============================================================================
// Visibility
// =============================================================================

const visState = {
  form: {
    accountType: "business",
    agree: true,
    off: false,
    count: 3,
    zero: 0,
    empty: "",
    nothing: null,
    str3: "3",
    tags: [],
    address: {},
    name: "Ada",
    max: 5,
  },
};

type VisCase = {
  name: string;
  condition?: unknown;
  state?: Record<string, unknown>;
};

const visCases: VisCase[] = [
  { name: "no condition is visible" },
  { name: "true", condition: true },
  { name: "false", condition: false },
  { name: "truthy string", condition: { $state: "/form/name" } },
  { name: "true boolean", condition: { $state: "/form/agree" } },
  { name: "false boolean", condition: { $state: "/form/off" } },
  { name: "empty string is falsy", condition: { $state: "/form/empty" } },
  { name: "zero is falsy", condition: { $state: "/form/zero" } },
  { name: "non-zero number is truthy", condition: { $state: "/form/count" } },
  { name: "null is falsy", condition: { $state: "/form/nothing" } },
  { name: "missing is falsy", condition: { $state: "/form/missing" } },
  { name: "empty array is truthy (JS)", condition: { $state: "/form/tags" } },
  {
    name: "empty object is truthy (JS)",
    condition: { $state: "/form/address" },
  },
  {
    name: "not inverts falsy",
    condition: { $state: "/form/empty", not: true },
  },
  {
    name: "not inverts truthy",
    condition: { $state: "/form/agree", not: true },
  },
  { name: "not on missing", condition: { $state: "/form/missing", not: true } },
  {
    name: "eq string match",
    condition: { $state: "/form/accountType", eq: "business" },
  },
  {
    name: "eq string mismatch",
    condition: { $state: "/form/accountType", eq: "personal" },
  },
  {
    name: "eq is strict: number vs numeric string",
    condition: { $state: "/form/str3", eq: 3 },
  },
  { name: "eq number", condition: { $state: "/form/count", eq: 3 } },
  {
    name: "eq is strict: 0 vs false",
    condition: { $state: "/form/zero", eq: false },
  },
  { name: "eq true", condition: { $state: "/form/agree", eq: true } },
  {
    name: "eq null matches null",
    condition: { $state: "/form/nothing", eq: null },
  },
  {
    name: "eq null does not match missing (undefined)",
    condition: { $state: "/form/missing", eq: null },
  },
  { name: "eq empty string", condition: { $state: "/form/empty", eq: "" } },
  {
    name: "eq with $state reference",
    condition: { $state: "/form/count", eq: { $state: "/form/count" } },
  },
  {
    name: "eq missing vs missing $state reference (undefined === undefined)",
    condition: { $state: "/form/missing", eq: { $state: "/form/other" } },
  },
  {
    name: "eq with not",
    condition: { $state: "/form/accountType", eq: "business", not: true },
  },
  {
    name: "neq mismatch",
    condition: { $state: "/form/accountType", neq: "personal" },
  },
  {
    name: "neq match",
    condition: { $state: "/form/accountType", neq: "business" },
  },
  {
    name: "neq missing vs empty string",
    condition: { $state: "/form/missing", neq: "" },
  },
  { name: "gt true", condition: { $state: "/form/count", gt: 2 } },
  { name: "gt false when equal", condition: { $state: "/form/count", gt: 3 } },
  {
    name: "gt numeric string is false",
    condition: { $state: "/form/str3", gt: 1 },
  },
  {
    name: "gt missing is false",
    condition: { $state: "/form/missing", gt: 0 },
  },
  {
    name: "gt with not on missing is true",
    condition: { $state: "/form/missing", gt: 0, not: true },
  },
  { name: "gte equal", condition: { $state: "/form/count", gte: 3 } },
  { name: "lt", condition: { $state: "/form/count", lt: 5 } },
  { name: "lt false", condition: { $state: "/form/count", lt: 1 } },
  { name: "lte equal", condition: { $state: "/form/count", lte: 3 } },
  {
    name: "lt with $state reference",
    condition: { $state: "/form/count", lt: { $state: "/form/max" } },
  },
  {
    name: "gt with missing $state reference is false",
    condition: { $state: "/form/count", gt: { $state: "/form/missing" } },
  },
  {
    name: "first operator wins (eq before gt)",
    condition: { $state: "/form/count", eq: 3, gt: 10 },
  },
  {
    name: "array: all true",
    condition: [{ $state: "/form/agree" }, { $state: "/form/count", gte: 1 }],
  },
  {
    name: "array: one false",
    condition: [{ $state: "/form/agree" }, { $state: "/form/off" }],
  },
  { name: "empty array is true", condition: [] },
  {
    name: "$and all true",
    condition: {
      $and: [{ $state: "/form/agree" }, { $state: "/form/name", eq: "Ada" }],
    },
  },
  {
    name: "$and one false",
    condition: { $and: [{ $state: "/form/agree" }, false] },
  },
  { name: "$and empty is true", condition: { $and: [] } },
  {
    name: "$or one true",
    condition: {
      $or: [
        { $state: "/form/off" },
        { $state: "/form/accountType", eq: "business" },
      ],
    },
  },
  {
    name: "$or none true",
    condition: { $or: [{ $state: "/form/off" }, { $state: "/form/empty" }] },
  },
  { name: "$or empty is false", condition: { $or: [] } },
  {
    name: "$or inside $and",
    condition: {
      $and: [
        { $state: "/form/agree" },
        {
          $or: [
            { $state: "/form/accountType", eq: "personal" },
            { $state: "/form/count", gt: 2 },
          ],
        },
      ],
    },
  },
  {
    name: "$and inside $or with arrays",
    condition: {
      $or: [{ $and: [{ $state: "/form/off" }] }, [{ $state: "/form/agree" }]],
    },
  },
  {
    name: "default-tab pattern: $or with not on missing",
    condition: {
      $or: [
        { $state: "/form/tab", eq: "home" },
        { $state: "/form/tab", not: true },
      ],
    },
  },
  {
    name: "$item outside repeat is falsy (out of scope)",
    condition: { $item: "done" },
  },
];

const visibility = {
  description: [
    "Visibility parity cases generated by @json-render/core evaluateVisibility.",
    'Each case: { "name", "condition"?, "state", "expected": boolean }. expected = evaluateVisibility(condition, { stateModel: state }).',
    'A case without "condition" means condition === undefined (always visible).',
    'Note core semantics: eq/neq are strict (===, so missing !== null and 3 !== "3"); gt/gte/lt/lte require both sides to be numbers; operator precedence is eq, neq, gt, gte, lt, lte; truthiness follows JS ("" / 0 / null / missing are falsy, [] and {} are truthy).',
  ].join(" "),
  cases: visCases.map(({ name, condition, state = visState }) => ({
    name,
    ...(condition !== undefined ? { condition } : {}),
    state,
    expected: evaluateVisibility(condition as VisibilityCondition | undefined, {
      stateModel: state,
    }),
  })),
};

// =============================================================================
// Validation
// =============================================================================

const valState = {
  form: {
    password: "hunter22",
    accountType: "business",
    personal: "",
    agree: true,
    min: 3,
    startDate: "2025-06-01",
    count: 5,
  },
};

type ValCase = {
  name: string;
  config: ValidationConfig;
  value?: unknown;
  state?: Record<string, unknown>;
};

const one = (
  type: string,
  args?: Record<string, unknown>,
): ValidationConfig => ({
  checks: [{ type, ...(args ? { args } : {}), message: `${type} failed` }],
});

const valCases: ValCase[] = [
  // required
  { name: "required: non-empty string", config: one("required"), value: "a" },
  { name: "required: empty string", config: one("required"), value: "" },
  {
    name: "required: whitespace-only string",
    config: one("required"),
    value: "   ",
  },
  { name: "required: null", config: one("required"), value: null },
  { name: "required: undefined (missing value)", config: one("required") },
  { name: "required: zero passes", config: one("required"), value: 0 },
  { name: "required: false passes", config: one("required"), value: false },
  { name: "required: empty array", config: one("required"), value: [] },
  { name: "required: non-empty array", config: one("required"), value: ["x"] },
  { name: "required: empty object passes", config: one("required"), value: {} },
  // email
  { name: "email: valid", config: one("email"), value: "ada@example.com" },
  { name: "email: missing TLD", config: one("email"), value: "ada@example" },
  {
    name: "email: contains space",
    config: one("email"),
    value: "a da@example.com",
  },
  { name: "email: empty string", config: one("email"), value: "" },
  { name: "email: non-string", config: one("email"), value: 42 },
  {
    name: "email: subdomains and plus",
    config: one("email"),
    value: "a.b+c@mail.example.co.uk",
  },
  // minLength / maxLength
  {
    name: "minLength: exactly min",
    config: one("minLength", { min: 3 }),
    value: "abc",
  },
  {
    name: "minLength: too short",
    config: one("minLength", { min: 3 }),
    value: "ab",
  },
  {
    name: "minLength: string arg fails",
    config: one("minLength", { min: "3" }),
    value: "abcdef",
  },
  {
    name: "minLength: missing args fails",
    config: one("minLength"),
    value: "abcdef",
  },
  {
    name: "minLength: non-string value fails",
    config: one("minLength", { min: 1 }),
    value: 12345,
  },
  {
    name: "minLength: $state arg",
    config: one("minLength", { min: { $state: "/form/min" } }),
    value: "abcd",
  },
  {
    name: "minLength: counts UTF-16 code units",
    config: one("minLength", { min: 2 }),
    value: "😀",
  },
  {
    name: "maxLength: within",
    config: one("maxLength", { max: 5 }),
    value: "abc",
  },
  {
    name: "maxLength: too long",
    config: one("maxLength", { max: 2 }),
    value: "abc",
  },
  {
    name: "maxLength: empty string",
    config: one("maxLength", { max: 0 }),
    value: "",
  },
  // pattern
  {
    name: "pattern: anchored match",
    config: one("pattern", { pattern: "^[0-9]{5}$" }),
    value: "94107",
  },
  {
    name: "pattern: anchored mismatch",
    config: one("pattern", { pattern: "^[0-9]{5}$" }),
    value: "9410",
  },
  {
    name: "pattern: unanchored matches substring",
    config: one("pattern", { pattern: "abc" }),
    value: "xxabcxx",
  },
  {
    name: "pattern: \\d class",
    config: one("pattern", { pattern: "^\\d{3}-\\d{4}$" }),
    value: "555-1234",
  },
  {
    name: "pattern: invalid regex fails",
    config: one("pattern", { pattern: "[" }),
    value: "[",
  },
  {
    name: "pattern: non-string value fails",
    config: one("pattern", { pattern: ".*" }),
    value: 5,
  },
  {
    name: "pattern: empty string vs optional pattern",
    config: one("pattern", { pattern: "^[A-Z]*$" }),
    value: "",
  },
  // min / max
  { name: "min: above", config: one("min", { min: 3 }), value: 5 },
  { name: "min: equal", config: one("min", { min: 3 }), value: 3 },
  { name: "min: below", config: one("min", { min: 3 }), value: 2 },
  {
    name: "min: numeric string fails",
    config: one("min", { min: 3 }),
    value: "5",
  },
  { name: "min: decimal", config: one("min", { min: 0.5 }), value: 0.75 },
  { name: "max: below", config: one("max", { max: 10 }), value: 7 },
  { name: "max: above", config: one("max", { max: 10 }), value: 11 },
  {
    name: "max: $state arg",
    config: one("max", { max: { $state: "/form/count" } }),
    value: 5,
  },
  // numeric
  { name: "numeric: number", config: one("numeric"), value: 3 },
  { name: "numeric: decimal string", config: one("numeric"), value: "3.5" },
  { name: "numeric: negative string", config: one("numeric"), value: "-2" },
  {
    name: "numeric: padded string (Number trims)",
    config: one("numeric"),
    value: " 42 ",
  },
  { name: "numeric: exponent string", config: one("numeric"), value: "1e3" },
  {
    name: "numeric: hex string (Number parses 0x)",
    config: one("numeric"),
    value: "0x1F",
  },
  { name: "numeric: empty string", config: one("numeric"), value: "" },
  { name: "numeric: whitespace", config: one("numeric"), value: "  " },
  { name: "numeric: letters", config: one("numeric"), value: "12abc" },
  { name: "numeric: boolean fails", config: one("numeric"), value: true },
  // url
  { name: "url: https", config: one("url"), value: "https://example.com" },
  {
    name: "url: with port, path and query",
    config: one("url"),
    value: "http://localhost:3000/a?b=1#c",
  },
  {
    name: "url: mailto scheme",
    config: one("url"),
    value: "mailto:ada@example.com",
  },
  { name: "url: missing scheme", config: one("url"), value: "example.com" },
  { name: "url: empty string", config: one("url"), value: "" },
  {
    name: "url: space in host",
    config: one("url"),
    value: "https://exa mple.com",
  },
  { name: "url: non-string", config: one("url"), value: 1 },
  // matches / equalTo
  {
    name: "matches: equal to $state",
    config: one("matches", { other: { $state: "/form/password" } }),
    value: "hunter22",
  },
  {
    name: "matches: differs from $state",
    config: one("matches", { other: { $state: "/form/password" } }),
    value: "hunter2",
  },
  {
    name: "matches: literal true (consent toggle)",
    config: one("matches", { other: true }),
    value: true,
  },
  {
    name: "matches: false vs true",
    config: one("matches", { other: true }),
    value: false,
  },
  {
    name: "matches: strict number vs string",
    config: one("matches", { other: 1 }),
    value: "1",
  },
  {
    name: "matches: missing value and missing other (undefined === undefined)",
    config: one("matches", { other: { $state: "/form/nope" } }),
  },
  {
    name: "matches: no args compares to undefined",
    config: one("matches"),
    value: "x",
  },
  {
    name: "equalTo: alias of matches",
    config: one("equalTo", { other: { $state: "/form/password" } }),
    value: "hunter22",
  },
  // lessThan / greaterThan
  {
    name: "lessThan: numbers",
    config: one("lessThan", { other: 2 }),
    value: 1,
  },
  {
    name: "lessThan: equal numbers",
    config: one("lessThan", { other: 2 }),
    value: 2,
  },
  {
    name: "lessThan: ISO dates",
    config: one("lessThan", { other: { $state: "/form/startDate" } }),
    value: "2025-05-31",
  },
  {
    name: "lessThan: numeric string vs number coerces",
    config: one("lessThan", { other: 5 }),
    value: "3",
  },
  {
    name: "lessThan: two strings compare lexicographically",
    config: one("lessThan", { other: "9" }),
    value: "10",
  },
  {
    name: "lessThan: empty value fails",
    config: one("lessThan", { other: 5 }),
    value: "",
  },
  {
    name: "lessThan: null fails",
    config: one("lessThan", { other: 5 }),
    value: null,
  },
  {
    name: "lessThan: missing other fails",
    config: one("lessThan", { other: { $state: "/form/nope" } }),
    value: 1,
  },
  {
    name: "lessThan: non-numeric string vs number fails",
    config: one("lessThan", { other: 5 }),
    value: "abc",
  },
  {
    name: "lessThan: boolean coerces to number",
    config: one("lessThan", { other: 5 }),
    value: true,
  },
  {
    name: "greaterThan: end date after start",
    config: one("greaterThan", { other: { $state: "/form/startDate" } }),
    value: "2025-06-02",
  },
  {
    name: "greaterThan: end date equal to start",
    config: one("greaterThan", { other: { $state: "/form/startDate" } }),
    value: "2025-06-01",
  },
  {
    name: "greaterThan: number vs numeric string",
    config: one("greaterThan", { other: "3" }),
    value: 7,
  },
  {
    name: "greaterThan: zero vs negative",
    config: one("greaterThan", { other: -1 }),
    value: 0,
  },
  // requiredIf
  {
    name: "requiredIf: condition truthy, value empty",
    config: one("requiredIf", { field: { $state: "/form/accountType" } }),
    value: "",
  },
  {
    name: "requiredIf: condition truthy, value filled",
    config: one("requiredIf", { field: { $state: "/form/accountType" } }),
    value: "Acme",
  },
  {
    name: "requiredIf: condition empty string, value empty",
    config: one("requiredIf", { field: { $state: "/form/personal" } }),
    value: "",
  },
  {
    name: "requiredIf: condition missing, value missing",
    config: one("requiredIf", { field: { $state: "/form/nope" } }),
  },
  {
    name: "requiredIf: condition true, value whitespace",
    config: one("requiredIf", { field: { $state: "/form/agree" } }),
    value: "  ",
  },
  // config-level behaviour
  { name: "no checks is valid", config: {}, value: "" },
  { name: "empty checks is valid", config: { checks: [] }, value: "" },
  { name: "unknown check type passes", config: one("isPrime"), value: 4 },
  {
    name: "multiple checks: errors in order",
    config: {
      checks: [
        { type: "required", message: "Password is required" },
        {
          type: "minLength",
          args: { min: 8 },
          message: "At least 8 characters",
        },
        {
          type: "pattern",
          args: { pattern: "[0-9]" },
          message: "Include a number",
        },
      ],
      validateOn: "blur",
    },
    value: "",
  },
  {
    name: "multiple checks: partial failure",
    config: {
      checks: [
        { type: "required", message: "Password is required" },
        {
          type: "minLength",
          args: { min: 8 },
          message: "At least 8 characters",
        },
        {
          type: "pattern",
          args: { pattern: "[0-9]" },
          message: "Include a number",
        },
      ],
    },
    value: "abc1",
  },
  {
    name: "enabled false skips all checks",
    config: {
      checks: [{ type: "required", message: "Company is required" }],
      enabled: { $state: "/form/accountType", eq: "personal" },
    },
    value: "",
  },
  {
    name: "enabled true runs checks",
    config: {
      checks: [{ type: "required", message: "Company is required" }],
      enabled: { $state: "/form/accountType", eq: "business" },
    },
    value: "",
  },
  {
    name: "enabled literal false is ignored (core only checks a truthy enabled)",
    config: { checks: [{ type: "required", message: "x" }], enabled: false },
    value: "",
  },
  {
    name: "enabled with $or",
    config: {
      checks: [{ type: "email", message: "Invalid email" }],
      enabled: { $or: [{ $state: "/form/nope" }, { $state: "/form/agree" }] },
    },
    value: "nope",
  },
];

const validation = {
  description: [
    "Field validation parity cases generated by @json-render/core runValidation.",
    'Each case: { "name", "config": ValidationConfig { checks?: [{ type, args?, message }], validateOn?, enabled? }, "value"?, "state", "expected": { valid, errors: string[], checks: [{ type, valid, message }] } }.',
    'expected = runValidation(config, { value, stateModel: state }). A case without "value" means value === undefined (unbound / missing).',
    "Check args are resolved with resolvePropValue against state before the check runs; enabled is evaluated with evaluateVisibility and, when false, yields { valid: true, errors: [], checks: [] }.",
    "Unknown check types pass. url uses the WHATWG URL parser (new URL(value) must not throw).",
  ].join(" "),
  cases: valCases.map(({ name, config, value, state = valState }) => ({
    name,
    config,
    ...(value !== undefined ? { value } : {}),
    state,
    expected: runValidation(config, { value, stateModel: state }),
  })),
};

// =============================================================================
// Repeat scope ($item / $index / $bindItem, repeat expansion)
// =============================================================================

const repState = {
  todos: [
    {
      id: "a",
      title: "Buy milk",
      done: true,
      tags: ["x", "y"],
      meta: { owner: "Ada" },
    },
    { id: "b", title: "Walk", done: false, tags: [], meta: null },
  ],
  user: { name: "Ada" },
  title: "Global title",
};

interface Scope {
  item?: unknown;
  index?: number;
  basePath?: string;
}

const first: Scope = {
  item: repState.todos[0],
  index: 0,
  basePath: "/todos/0",
};
const second: Scope = {
  item: repState.todos[1],
  index: 1,
  basePath: "/todos/1",
};

function scopeContext(scope: Scope): PropResolutionContext {
  return {
    stateModel: repState,
    repeatItem: scope.item,
    repeatIndex: scope.index,
    repeatBasePath: scope.basePath,
  };
}

type ScopedCase = { name: string; value: unknown; scope: Scope };

const repeatPropCases: ScopedCase[] = [
  { name: "$item field", value: { $item: "title" }, scope: first },
  { name: '$item "" is the whole item', value: { $item: "" }, scope: first },
  {
    name: "$item with leading slash",
    value: { $item: "/title" },
    scope: first,
  },
  { name: "$item nested path", value: { $item: "meta/owner" }, scope: first },
  { name: "$item array index", value: { $item: "tags/1" }, scope: first },
  {
    name: "$item missing field is undefined",
    value: { $item: "missing" },
    scope: first,
  },
  {
    name: "$item through null is undefined",
    value: { $item: "meta/owner" },
    scope: second,
  },
  {
    name: "$item outside a repeat is undefined",
    value: { $item: "title" },
    scope: {},
  },
  {
    name: '$item "" on a primitive item',
    value: { $item: "" },
    scope: { item: "hello", index: 0, basePath: "/words/0" },
  },
  {
    name: "$item field on a primitive item is undefined",
    value: { $item: "length" },
    scope: { item: "hello", index: 0, basePath: "/words/0" },
  },
  { name: "$index", value: { $index: true }, scope: second },
  { name: "$index zero", value: { $index: true }, scope: first },
  {
    name: "$index outside a repeat is undefined",
    value: { $index: true },
    scope: {},
  },
  {
    name: "$index: false is a plain object",
    value: { $index: false },
    scope: first,
  },
  {
    name: "$bindItem reads state at basePath",
    value: { $bindItem: "done" },
    scope: first,
  },
  {
    name: '$bindItem "" reads the item from state',
    value: { $bindItem: "" },
    scope: second,
  },
  {
    name: "$bindItem reads state, not the item (basePath wins)",
    value: { $bindItem: "title" },
    scope: { item: repState.todos[0], index: 0, basePath: "/todos/1" },
  },
  {
    name: "$bindItem outside a repeat is undefined",
    value: { $bindItem: "done" },
    scope: {},
  },
  {
    name: "$template bare name reads the item",
    value: { $template: "${title}" },
    scope: first,
  },
  {
    name: "$template mixes item and absolute paths",
    value: { $template: "${title} for ${/user/name}" },
    scope: first,
  },
  {
    name: "$template bare nested path",
    value: { $template: "${meta/owner}" },
    scope: first,
  },
  {
    name: "$template bare name falls back to state when the item lacks it",
    value: { $template: "${title}" },
    scope: { item: { id: "z" }, index: 0, basePath: "/other/0" },
  },
  {
    name: "$template bare name falls back to state when the item value is null",
    value: { $template: "[${meta}]" },
    scope: second,
  },
  {
    name: "$template bare name outside a repeat reads /name",
    value: { $template: "${title}" },
    scope: {},
  },
  {
    name: "$cond on $item",
    value: { $cond: { $item: "done" }, $then: "done", $else: "open" },
    scope: second,
  },
  {
    name: "$cond on $index",
    value: { $cond: { $index: true, eq: 0 }, $then: "first", $else: "other" },
    scope: first,
  },
  {
    name: "nested object and array members resolve in scope",
    value: {
      label: { $item: "title" },
      row: [{ $index: true }, { $item: "id" }],
    },
    scope: second,
  },
];

const repeatBindingCases: {
  name: string;
  props: Record<string, unknown>;
  scope: Scope;
}[] = [
  {
    name: "$bindItem and $bindState bindings",
    props: {
      checked: { $bindItem: "done" },
      label: { $item: "title" },
      value: { $bindState: "/user/name" },
    },
    scope: first,
  },
  {
    name: '$bindItem "" binds the item path',
    props: { value: { $bindItem: "" } },
    scope: second,
  },
  {
    name: "$bindItem outside a repeat is dropped",
    props: {
      checked: { $bindItem: "done" },
      value: { $bindState: "/user/name" },
    },
    scope: {},
  },
];

const repeatActionCases: ScopedCase[] = [
  {
    name: "$item in an action param resolves to the item's state path",
    value: { $item: "title" },
    scope: first,
  },
  {
    name: '$item "" in an action param is the item path',
    value: { $item: "" },
    scope: second,
  },
  { name: "$index in an action param", value: { $index: true }, scope: second },
  {
    name: "$state in an action param reads state",
    value: { $state: "/user/name" },
    scope: first,
  },
  {
    name: "$item action param outside a repeat is undefined",
    value: { $item: "title" },
    scope: {},
  },
  {
    name: "nested $item in an action param object resolves to the value (only top level is a path)",
    value: { id: { $item: "id" } },
    scope: first,
  },
];

const repeatVisibilityCases: {
  name: string;
  condition: unknown;
  scope: Scope;
}[] = [
  { name: "$item truthy", condition: { $item: "done" }, scope: first },
  { name: "$item falsy", condition: { $item: "done" }, scope: second },
  { name: "$item not", condition: { $item: "done", not: true }, scope: second },
  {
    name: "$item empty array is truthy",
    condition: { $item: "tags" },
    scope: second,
  },
  {
    name: '$item "" whole item is truthy',
    condition: { $item: "" },
    scope: first,
  },
  {
    name: "$item eq $state reference",
    condition: { $item: "title", eq: { $state: "/todos/0/title" } },
    scope: first,
  },
  {
    name: "$item outside a repeat is falsy",
    condition: { $item: "done" },
    scope: {},
  },
  { name: "$index eq", condition: { $index: true, eq: 0 }, scope: first },
  {
    name: "$index truthiness: 0 is falsy",
    condition: { $index: true },
    scope: first,
  },
  {
    name: "$index truthiness: 1 is truthy",
    condition: { $index: true },
    scope: second,
  },
  { name: "$index gt", condition: { $index: true, gt: 0 }, scope: second },
  {
    name: "$index eq outside a repeat",
    condition: { $index: true, eq: 0 },
    scope: {},
  },
  {
    name: "array mixing $state and $item",
    condition: [{ $state: "/user/name" }, { $item: "done" }],
    scope: first,
  },
  {
    name: "$or of $item and $index",
    condition: { $or: [{ $item: "done" }, { $index: true, eq: 1 }] },
    scope: second,
  },
];

const repeatPathCases: {
  name: string;
  statePath: unknown;
  basePath?: string;
}[] = [
  {
    name: "absolute statePath ignores the base",
    statePath: "/todos",
    basePath: "/groups/0",
  },
  { name: "absolute statePath outside a repeat", statePath: "/todos" },
  {
    name: "$item field joins the base",
    statePath: { $item: "tags" },
    basePath: "/todos/0",
  },
  {
    name: "$item with leading slash joins the base",
    statePath: { $item: "/tags" },
    basePath: "/todos/0",
  },
  {
    name: '$item "" is the base',
    statePath: { $item: "" },
    basePath: "/todos/0",
  },
  {
    name: '$item "/" is the base',
    statePath: { $item: "/" },
    basePath: "/todos/0",
  },
  {
    name: "$item with a root base",
    statePath: { $item: "tags" },
    basePath: "/",
  },
  {
    name: "$item with an empty base",
    statePath: { $item: "tags" },
    basePath: "",
  },
  {
    name: "$item statePath outside a repeat is undefined",
    statePath: { $item: "tags" },
  },
];

const repeatItemPathCases: {
  name: string;
  statePath: string;
  index: number;
}[] = [
  { name: "item path", statePath: "/todos", index: 2 },
  { name: "item path under the root", statePath: "/", index: 0 },
  { name: "item path with an empty base", statePath: "", index: 1 },
];

/**
 * Mirrors @json-render/react-pdf's renderToBuffer element walk (render.tsx renderElement),
 * using core functions, and returns the rendered tree instead of React elements.
 */
interface RenderNode {
  key: string;
  type: string;
  props: Record<string, unknown>;
  scope?: { index: number | undefined; basePath: string };
  children: RenderNode[];
}

function renderTree(spec: Spec, knownTypes: string[]): RenderNode | null {
  const state = { ...spec.state };
  const visit = (key: string, scope: Scope): RenderNode | null => {
    const element: UIElement | undefined = spec.elements[key];
    if (!element) return null;
    const ctx: PropResolutionContext = {
      stateModel: state,
      repeatItem: scope.item,
      repeatIndex: scope.index,
      repeatBasePath: scope.basePath,
    };
    if (
      element.visible !== undefined &&
      !evaluateVisibility(element.visible, ctx)
    ) {
      return null;
    }
    const props = resolveElementProps(
      element.props as Record<string, unknown>,
      ctx,
    );
    if (!knownTypes.includes(element.type)) return null;
    const node: RenderNode = {
      key,
      type: element.type,
      props,
      ...(scope.basePath !== undefined
        ? { scope: { index: scope.index, basePath: scope.basePath } }
        : {}),
      children: [],
    };
    const add = (child: RenderNode | null) => {
      if (child) node.children.push(child);
    };
    if (element.repeat) {
      const statePath = resolveRepeatStatePath(
        element.repeat.statePath,
        scope.basePath,
      );
      if (statePath === undefined) return null;
      const items =
        (getByPath(state, statePath) as unknown[] | undefined) ?? [];
      items.map((item, index) => {
        const basePath = resolveRepeatItemStatePath(statePath, index);
        element.children?.forEach((child) =>
          add(visit(child, { item, index, basePath })),
        );
      });
    } else {
      element.children?.forEach((child) => add(visit(child, scope)));
    }
    return node;
  };
  return visit(spec.root, {});
}

const PDF_TYPES = [
  "Document",
  "Page",
  "View",
  "Row",
  "Column",
  "Heading",
  "Text",
  "Image",
  "Link",
  "Table",
  "List",
  "Divider",
  "Spacer",
  "PageNumber",
  // fillable form components (docs/PDF-FORMS.md)
  "FieldSet",
  "TextInput",
  "Checkbox",
  "RadioGroup",
  "Select",
  "ListBox",
];

const text = (props: Record<string, unknown>, extra: object = {}) => ({
  type: "Text",
  props,
  children: [],
  ...extra,
});

const formTreeSpec: Spec = {
  root: "guests",
  elements: {
    guests: {
      type: "Column",
      props: {},
      repeat: { statePath: "/guests", key: "id" },
      children: ["guest"],
    },
    guest: {
      type: "FieldSet",
      props: { name: { $template: "guest_${id}" }, label: { $item: "name" } },
      children: ["guest-name", "guest-meal", "guest-vegan"],
    },
    "guest-name": {
      type: "TextInput",
      props: { name: "name", label: "Name", value: { $item: "name" } },
      children: [],
    },
    "guest-meal": {
      type: "RadioGroup",
      props: {
        name: "meal",
        options: [
          { label: "Fish", value: "fish" },
          { label: "Veg", value: "veg" },
        ],
        value: { $bindItem: "meal" },
      },
      children: [],
    },
    "guest-vegan": {
      type: "Checkbox",
      props: {
        name: "vegan",
        label: "Vegan",
        checked: {
          $cond: { $item: "meal", eq: "veg" },
          $then: true,
          $else: false,
        },
      },
      children: [],
    },
  },
  state: {
    guests: [
      { id: "1", name: "Ada", meal: "fish" },
      { id: "2", name: "Grace", meal: "veg" },
    ],
  },
};

const treeCases: { name: string; spec: Spec }[] = [
  {
    name: "form fields inside a repeated FieldSet resolve per item",
    spec: formTreeSpec,
  },
  {
    name: "repeat renders children once per item with $item / $index / visible",
    spec: {
      root: "list",
      elements: {
        list: {
          type: "Column",
          props: {},
          repeat: { statePath: "/todos", key: "id" },
          children: ["title", "index", "done-badge"],
        },
        title: text({ text: { $item: "title" } }),
        index: text({
          text: { $template: "#${id}" },
          fontSize: { $index: true },
        }),
        "done-badge": text({ text: "done" }, { visible: { $item: "done" } }),
      },
      state: repState,
    },
  },
  {
    name: "nested repeat with an item-relative statePath and $bindItem",
    spec: {
      root: "groups",
      elements: {
        groups: {
          type: "Column",
          props: {},
          repeat: { statePath: "/groups" },
          children: ["group-name", "items"],
        },
        "group-name": text({ text: { $item: "name" } }),
        items: {
          type: "Column",
          props: { gap: { $index: true } },
          repeat: { statePath: { $item: "items" } },
          children: ["item"],
        },
        item: text({
          text: { $template: "${label} (${/owner})" },
          fontSize: { $bindItem: "size" },
          color: {
            $cond: { $index: true, eq: 0 },
            $then: "#000000",
            $else: "#999999",
          },
        }),
      },
      state: {
        owner: "Ada",
        groups: [
          {
            name: "Fruit",
            items: [
              { label: "Apple", size: 10 },
              { label: "Pear", size: 11 },
            ],
          },
          { name: "Empty", items: [] },
          { name: "Veg", items: [{ label: "Kale", size: 12 }] },
        ],
      },
    },
  },
  {
    name: "repeat container props resolve in the outer scope; missing / null arrays render no items",
    spec: {
      root: "page",
      elements: {
        page: {
          type: "Column",
          props: {},
          children: ["missing", "nulled", "empty"],
        },
        missing: {
          type: "Column",
          props: { gap: { $index: true } },
          repeat: { statePath: "/nope" },
          children: ["t"],
        },
        nulled: {
          type: "Column",
          props: {},
          repeat: { statePath: "/nothing" },
          children: ["t"],
        },
        empty: {
          type: "Column",
          props: {},
          repeat: { statePath: "/list" },
          children: ["t"],
        },
        t: text({ text: { $item: "" } }),
      },
      state: { nothing: null, list: [] },
    },
  },
  {
    name: "hidden repeat container, $item statePath outside a repeat, missing children and unknown types are skipped",
    spec: {
      root: "page",
      elements: {
        page: {
          type: "Column",
          props: {},
          children: ["hidden", "relative", "ghost", "bogus", "words"],
        },
        hidden: {
          type: "Column",
          props: {},
          visible: false,
          repeat: { statePath: "/words" },
          children: ["w"],
        },
        relative: {
          type: "Column",
          props: {},
          repeat: { statePath: { $item: "words" } },
          children: ["w"],
        },
        bogus: { type: "Chart", props: {}, children: [] },
        words: {
          type: "Row",
          props: {},
          repeat: { statePath: "/words" },
          children: ["w", "ghost"],
        },
        w: text({ text: { $item: "" } }),
      },
      state: { words: ["alpha", "beta"] },
    },
  },
];

function treeCase({ name, spec }: { name: string; spec: Spec }) {
  const tree = renderTree(spec, PDF_TYPES);
  return {
    name,
    fn: "renderTree",
    spec,
    expected: JSON.parse(JSON.stringify(tree)),
    undefinedPaths: undefinedPaths(tree),
  };
}

const repeat = {
  description: [
    "Repeat-scope parity cases generated by @json-render/core (PDF catalog: repeat, $item, $index, $bindItem).",
    'Scope: "scope" is { "item"?, "index"?, "basePath"? } = core PropResolutionContext { repeatItem, repeatIndex, repeatBasePath } with stateModel = "state"; a missing key means undefined (outside a repeat).',
    'fn "resolvePropValue": { value, scope, state } -> expected = resolvePropValue(value, ctx).',
    'fn "resolveBindings": { props, scope, state } -> expected = resolveBindings(props, ctx) (prop -> state path), null when there are none.',
    'fn "resolveActionParam": { value, scope, state } -> expected = resolveActionParam(value, ctx); note a top-level $item resolves to the item\'s absolute state PATH here, not its value.',
    'fn "evaluateVisibility": { condition, scope, state } -> expected boolean.',
    'fn "resolveRepeatStatePath": { statePath, basePath? } -> expected path string (null + "undefined": true when core returns undefined).',
    'fn "resolveRepeatItemStatePath": { statePath, index } -> expected path string.',
    "fn \"renderTree\": { spec } -> expected tree mirroring @json-render/react-pdf renderToBuffer's element walk: node = { key, type, props (resolved), scope? { index, basePath } (present inside a repeat), children }. Order per element: visible (in the current scope) -> resolve props (current scope) -> skip unknown types (only PDF catalog components render: upstream's 14 plus the 6 form components) -> if repeat: statePath via resolveRepeatStatePath(statePath, current basePath) (undefined -> element not rendered), items = getByPath(state, path) ?? [], and for each item i the element's children render with { item, index: i, basePath: resolveRepeatItemStatePath(path, i) }; otherwise children render in the current scope. Missing child keys are skipped.",
    UNDEFINED_NOTE,
    '"undefinedPaths" (on value-returning cases) lists JSON Pointers into the result whose core value is undefined, "" for the result itself.',
  ].join(" "),
  cases: [
    ...repeatPropCases.map(({ name, value, scope }) => ({
      name,
      fn: "resolvePropValue",
      state: repState,
      scope,
      value,
      ...expectedValue(resolvePropValue(value, scopeContext(scope))),
    })),
    ...repeatBindingCases.map(({ name, props, scope }) => ({
      name,
      fn: "resolveBindings",
      state: repState,
      scope,
      props,
      expected: resolveBindings(props, scopeContext(scope)) ?? null,
    })),
    ...repeatActionCases.map(({ name, value, scope }) => ({
      name,
      fn: "resolveActionParam",
      state: repState,
      scope,
      value,
      ...expectedValue(resolveActionParam(value, scopeContext(scope))),
    })),
    ...repeatVisibilityCases.map(({ name, condition, scope }) => ({
      name,
      fn: "evaluateVisibility",
      state: repState,
      scope,
      condition,
      expected: evaluateVisibility(
        condition as VisibilityCondition,
        scopeContext(scope),
      ),
    })),
    ...repeatPathCases.map(({ name, statePath, basePath }) => ({
      name,
      fn: "resolveRepeatStatePath",
      statePath,
      ...(basePath !== undefined ? { basePath } : {}),
      ...expectedValue(
        resolveRepeatStatePath(
          statePath as string | { $item: string },
          basePath,
        ),
      ),
    })),
    ...repeatItemPathCases.map(({ name, statePath, index }) => ({
      name,
      fn: "resolveRepeatItemStatePath",
      statePath,
      index,
      expected: resolveRepeatItemStatePath(statePath, index),
    })),
    ...treeCases.map(treeCase),
  ],
};

// =============================================================================
// PDF form fields (docs/PDF-FORMS.md): expected PDFRenderResult.formFields
// =============================================================================

const FORM_FIELD_TYPES = [
  "TextInput",
  "Checkbox",
  "RadioGroup",
  "Select",
  "ListBox",
];

interface FormFieldInfo {
  name: string;
  type: string;
  value: unknown;
  pointer: string | null;
  options?: { label: string; value: string }[];
  required: boolean;
  readOnly: boolean;
  multiSelect?: boolean;
}

/** The JSON Pointer a field's value is bound to: $state / $bindState path, or $bindItem resolved in scope. */
function boundPointer(
  expr: unknown,
  basePath: string | undefined,
): string | null {
  if (typeof expr !== "object" || expr === null) return null;
  const e = expr as Record<string, unknown>;
  if (typeof e.$state === "string") return e.$state;
  if (typeof e.$bindState === "string") return e.$bindState;
  if (typeof e.$bindItem === "string" && basePath !== undefined) {
    return e.$bindItem === "" ? basePath : `${basePath}/${e.$bindItem}`;
  }
  return null;
}

function normalizeFieldValue(
  type: string,
  props: Record<string, unknown>,
): unknown {
  switch (type) {
    case "Checkbox":
      return props.checked === true;
    case "ListBox": {
      const v = props.value;
      if (props.multiSelect === true) {
        if (Array.isArray(v)) return v.filter((x) => typeof x === "string");
        return typeof v === "string" && v !== "" ? [v] : [];
      }
      const single = Array.isArray(v) ? v[0] : v;
      return typeof single === "string" && single !== "" ? single : null;
    }
    default:
      return typeof props.value === "string" && props.value !== ""
        ? props.value
        : null;
  }
}

/**
 * Fields in render order: fully qualified name = enclosing FieldSet names + name joined by
 * "."; a repeated full name gets "#2", "#3", ... (the renderer's defensive dedupe).
 */
function collectFormFields(spec: Spec): FormFieldInfo[] {
  const tree = renderTree(spec, PDF_TYPES);
  const fields: FormFieldInfo[] = [];
  const counts = new Map<string, number>();
  const visit = (node: RenderNode, prefix: string[]) => {
    const name = typeof node.props.name === "string" ? node.props.name : "";
    if (node.type === "FieldSet") {
      node.children.forEach((child) => visit(child, [...prefix, name]));
      return;
    }
    if (FORM_FIELD_TYPES.includes(node.type)) {
      let full = [...prefix, name].join(".");
      const seen = (counts.get(full) ?? 0) + 1;
      counts.set(full, seen);
      if (seen > 1) full = `${full}#${seen}`;
      const raw = spec.elements[node.key]!.props as Record<string, unknown>;
      const binding = node.type === "Checkbox" ? raw.checked : raw.value;
      const info: FormFieldInfo = {
        name: full,
        type: node.type,
        value: normalizeFieldValue(node.type, node.props),
        pointer: boundPointer(binding, node.scope?.basePath),
        required: node.props.required === true,
        readOnly: node.props.readOnly === true,
      };
      if (Array.isArray(node.props.options)) {
        info.options = node.props.options as FormFieldInfo["options"];
      }
      if (node.type === "ListBox")
        info.multiSelect = node.props.multiSelect === true;
      fields.push(info);
    }
    node.children.forEach((child) => visit(child, prefix));
  };
  if (tree) visit(tree, []);
  return fields;
}

const applicationForm = JSON.parse(
  await readFile(join(outDir, "../pdf/application-form.json"), "utf8"),
) as Spec;

const formFieldCases: { name: string; spec: Spec }[] = [
  { name: "application-form fixture", spec: applicationForm },
  {
    name: "duplicate names get #2 and nested FieldSets qualify names",
    spec: {
      root: "doc",
      elements: {
        doc: { type: "Document", props: {}, children: ["page"] },
        page: {
          type: "Page",
          props: { size: "A4" },
          children: ["outer", "dup-a", "dup-b"],
        },
        outer: {
          type: "FieldSet",
          props: { name: "outer" },
          children: ["inner"],
        },
        inner: {
          type: "FieldSet",
          props: { name: "inner" },
          children: ["deep"],
        },
        deep: {
          type: "TextInput",
          props: { name: "x", value: { $bindState: "/x" } },
          children: [],
        },
        "dup-a": {
          type: "Checkbox",
          props: { name: "agree", label: "A", checked: true },
          children: [],
        },
        "dup-b": {
          type: "Checkbox",
          props: { name: "agree", label: "B" },
          children: [],
        },
      },
      state: { x: "hello" },
    },
  },
  { name: "fields in a repeat bind via $bindItem", spec: formTreeSpec },
];

const pdfFormFields = {
  description: [
    "Expected form fields for PDF specs (docs/PDF-FORMS.md PDFRenderResult.formFields), computed from the renderTree walk documented in repeat.json.",
    'Each case: { "name", "spec", "expected": FormFieldInfo[] } in render (document) order.',
    'FormFieldInfo: { "name": fully qualified name (enclosing FieldSet names and the field name joined with "."; when a full name repeats, later fields get "#2", "#3", ...), "type": TextInput | Checkbox | RadioGroup | Select | ListBox, "value": normalized resolved value (TextInput/RadioGroup/Select: string, or null when empty/unset; Checkbox: boolean, checked === true; ListBox: string[] when multiSelect, else string or null), "pointer": JSON Pointer the value is bound to ($state / $bindState path of value, or of checked for Checkbox; $bindItem resolved against the repeat basePath), else null ($item reads are not bindings), "options"?: resolved options of choice fields, "required" / "readOnly": true only when exactly true, "multiSelect"?: ListBox only }.',
    "Hidden elements (visible false) produce no fields.",
  ].join(" "),
  cases: formFieldCases.map(({ name, spec }) => ({
    name,
    spec,
    expected: collectFormFields(spec),
  })),
};

// =============================================================================

await mkdir(outDir, { recursive: true });
for (const [file, data] of Object.entries({
  expressions,
  visibility,
  validation,
  repeat,
  "pdf-form-fields": pdfFormFields,
})) {
  await writeFile(
    join(outDir, `${file}.json`),
    `${JSON.stringify(data, null, 2)}\n`,
  );
  console.log(`fixtures/parity/${file}.json: ${data.cases.length} cases`);
}
