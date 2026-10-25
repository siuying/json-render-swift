import { VisibilityConditionStrictSchema } from "@json-render/core";
import { z } from "zod";

// =============================================================================
// Shared prop schemas
// =============================================================================

/**
 * Names of core's `builtInValidationFunctions`, in core's declaration order.
 * Kept in sync by a test against `@json-render/core`.
 */
export const builtInCheckTypes = [
  "required",
  "email",
  "minLength",
  "maxLength",
  "pattern",
  "min",
  "max",
  "numeric",
  "url",
  "matches",
  "equalTo",
  "lessThan",
  "greaterThan",
  "requiredIf",
] as const;

export type BuiltInCheckType = (typeof builtInCheckTypes)[number];

/** A check arg may be a literal or a `{ "$state": "/path" }` reference. */
const stateRef = z.object({ $state: z.string() });
const dynamicNumber = z.union([z.number(), stateRef]);
const dynamicString = z.union([z.string(), stateRef]);

const checkSchema = <
  T extends BuiltInCheckType,
  A extends z.ZodRawShape | null,
>(
  type: T,
  args: A,
) =>
  z.object({
    type: z.literal(type),
    ...(args ? { args: z.object(args) } : { args: z.object({}).nullish() }),
    message: z.string(),
  });

/**
 * One validation check: mirrors core's `ValidationCheck` (`{ type, args?, message }`)
 * with `type` restricted to core's built-in functions and per-type `args`.
 */
export const validationCheckSchema = z.discriminatedUnion("type", [
  checkSchema("required", null),
  checkSchema("email", null),
  checkSchema("minLength", { min: dynamicNumber }),
  checkSchema("maxLength", { max: dynamicNumber }),
  checkSchema("pattern", { pattern: dynamicString }),
  checkSchema("min", { min: dynamicNumber }),
  checkSchema("max", { max: dynamicNumber }),
  checkSchema("numeric", null),
  checkSchema("url", null),
  checkSchema("matches", { other: z.unknown() }),
  checkSchema("equalTo", { other: z.unknown() }),
  checkSchema("lessThan", { other: z.unknown() }),
  checkSchema("greaterThan", { other: z.unknown() }),
  checkSchema("requiredIf", { field: z.unknown() }),
]);

/** How each built-in check is described to the LLM (args shown as JSON). */
export const checkTypeDescriptions: Record<BuiltInCheckType, string> = {
  required: "value is non-empty (trimmed string, non-empty array, not null)",
  email: "valid email address",
  minLength: 'string length >= min. args: { "min": N }',
  maxLength: 'string length <= max. args: { "max": N }',
  pattern: 'string matches a regex. args: { "pattern": "^[0-9]{5}$" }',
  min: 'number >= min. Stepper/Slider only: TextField values are strings and always fail. args: { "min": N }',
  max: 'number <= max. Stepper/Slider only: TextField values are strings and always fail. args: { "max": N }',
  numeric:
    "number, or a string that parses as a number (use for numeric TextFields)",
  url: "valid absolute URL (https://...)",
  matches:
    'equals another value. args: { "other": { "$state": "/form/password" } }',
  equalTo: "alias of matches",
  lessThan:
    'less than another value (numbers, or ISO dates). args: { "other": { "$state": "/form/endDate" } }',
  greaterThan:
    'greater than another value (numbers, or ISO dates). args: { "other": { "$state": "/form/startDate" } }',
  requiredIf:
    'required only when another value is truthy. args: { "field": { "$state": "/form/hasCompany" } }',
};

const checks = z.array(validationCheckSchema).nullish();
const validateOn = z.enum(["change", "blur", "submit"]).nullish();
/** core ValidationConfig.enabled: checks run only while this visibility condition holds. */
const enabled = VisibilityConditionStrictSchema.nullish();

const contentType = z
  .enum([
    "name",
    "givenName",
    "familyName",
    "email",
    "phone",
    "username",
    "newPassword",
    "password",
    "oneTimeCode",
    "streetAddress",
    "city",
    "postalCode",
    "countryName",
    "organizationName",
    "url",
  ])
  .nullish();

const pickerOption = z.object({
  label: z.string(),
  value: z.union([z.string(), z.number()]),
});

// =============================================================================
// Component Definitions
// =============================================================================

/**
 * SwiftUI form component definitions.
 *
 * Optional props use `.nullish()` because LLMs often emit `null` for unset props.
 * Binding props (`value`, `isOn`, `selection`) take `{ "$bindState": "/form/..." }`.
 */
export const componentDefinitions = {
  // ==========================================================================
  // Containers
  // ==========================================================================

  Form: {
    props: z.object({
      title: z.string().nullish(),
      subtitle: z.string().nullish(),
    }),
    slots: ["default"],
    description:
      "Root of every form (SwiftUI Form with a navigation title). Children are Sections.",
    example: { title: "Create Account" },
  },

  Section: {
    props: z.object({
      header: z.string().nullish(),
      footer: z.string().nullish(),
    }),
    slots: ["default"],
    description:
      "Groups related fields under a header. footer is small helper text below the group.",
    example: { header: "Account" },
  },

  VStack: {
    props: z.object({
      spacing: z.number().nullish(),
      alignment: z.enum(["leading", "center", "trailing"]).nullish(),
    }),
    slots: ["default"],
    description:
      "Vertical stack inside one form row. Rarely needed: Section already stacks rows.",
    example: { spacing: 8, alignment: "leading" },
  },

  HStack: {
    props: z.object({
      spacing: z.number().nullish(),
      alignment: z.enum(["top", "center", "bottom"]).nullish(),
    }),
    slots: ["default"],
    description:
      "Horizontal stack inside one form row, e.g. two buttons side by side.",
    example: { spacing: 12 },
  },

  // ==========================================================================
  // Display
  // ==========================================================================

  Text: {
    props: z.object({
      content: z.string(),
      style: z
        .enum([
          "largeTitle",
          "title",
          "title2",
          "headline",
          "subheadline",
          "body",
          "callout",
          "caption",
          "footnote",
        ])
        .nullish(),
      color: z
        .enum([
          "primary",
          "secondary",
          "accent",
          "red",
          "orange",
          "green",
          "blue",
        ])
        .nullish(),
    }),
    description:
      'Static or dynamic text. content may be { "$template": "Hi ${/form/name}" }.',
    example: {
      content: "We never share your email.",
      style: "footnote",
      color: "secondary",
    },
  },

  LabeledContent: {
    props: z.object({
      label: z.string(),
      value: z.string().nullish(),
    }),
    description:
      'Read-only label/value row, e.g. a live summary: value { "$template": "${/form/guests} guests" }.',
    example: {
      label: "Guests",
      value: { $template: "${/form/guests} people" },
    },
  },

  Divider: {
    props: z.object({}),
    description: "Thin separator line.",
  },

  // ==========================================================================
  // Inputs
  // ==========================================================================

  TextField: {
    props: z.object({
      label: z.string(),
      placeholder: z.string().nullish(),
      value: z.string().nullish(),
      keyboard: z
        .enum(["default", "email", "number", "decimal", "phone", "url"])
        .nullish(),
      contentType,
      autocapitalization: z
        .enum(["never", "words", "sentences", "characters"])
        .nullish(),
      multiline: z.boolean().nullish(),
      lineLimit: z.number().nullish(),
      disabled: z.boolean().nullish(),
      checks,
      enabled,
      validateOn,
    }),
    events: ["submit", "change"],
    description:
      "Text input; its value is always a string. multiline: true (optionally with lineLimit) for long answers.",
    example: {
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
  },

  SecureField: {
    props: z.object({
      label: z.string(),
      placeholder: z.string().nullish(),
      value: z.string().nullish(),
      contentType: z.enum(["password", "newPassword", "oneTimeCode"]).nullish(),
      disabled: z.boolean().nullish(),
      checks,
      enabled,
      validateOn,
    }),
    events: ["submit", "change"],
    description:
      'Masked password input. contentType "newPassword" on sign-up, "password" on sign-in.',
    example: {
      label: "Password",
      value: { $bindState: "/form/password" },
      contentType: "newPassword",
      checks: [
        { type: "required", message: "Password is required" },
        {
          type: "minLength",
          args: { min: 8 },
          message: "At least 8 characters",
        },
      ],
      validateOn: "blur",
    },
  },

  Toggle: {
    props: z.object({
      label: z.string(),
      isOn: z.boolean().nullish(),
      disabled: z.boolean().nullish(),
      checks,
      enabled,
      validateOn,
    }),
    events: ["change"],
    description:
      'On/off switch. For mandatory consent use the check { "type": "matches", "args": { "other": true }, "message": "..." } ("required" passes for false).',
    example: {
      label: "Subscribe to newsletter",
      isOn: { $bindState: "/form/newsletter" },
    },
  },

  Picker: {
    props: z.object({
      label: z.string(),
      selection: z.union([z.string(), z.number()]).nullish(),
      options: z.array(pickerOption),
      style: z
        .enum(["menu", "segmented", "inline", "wheel", "navigationLink"])
        .nullish(),
      disabled: z.boolean().nullish(),
      checks,
      enabled,
      validateOn,
    }),
    events: ["change"],
    description:
      'Choose one of options; selection holds the chosen value. Seed it with an option value, or "" plus a "required" check to force a choice. style "segmented" for 2-4 short options, "menu" otherwise.',
    example: {
      label: "Plan",
      selection: { $bindState: "/form/plan" },
      options: [
        { label: "Free", value: "free" },
        { label: "Pro", value: "pro" },
      ],
      style: "segmented",
    },
  },

  DatePicker: {
    props: z.object({
      label: z.string(),
      selection: z.string().nullish(),
      components: z.enum(["date", "hourAndMinute", "dateAndTime"]).nullish(),
      minimum: z.string().nullish(),
      maximum: z.string().nullish(),
      style: z.enum(["automatic", "compact", "graphical", "wheel"]).nullish(),
      disabled: z.boolean().nullish(),
      checks,
      enabled,
      validateOn,
    }),
    events: ["change"],
    description:
      'Date and/or time as an ISO-8601 string: "YYYY-MM-DD" when components is "date" (default), otherwise a full datetime like "2025-06-01T18:30:00Z". minimum/maximum use the same format.',
    example: {
      label: "Date of birth",
      selection: { $bindState: "/form/birthday" },
      components: "date",
      maximum: "2010-12-31",
    },
  },

  Stepper: {
    props: z.object({
      label: z.string(),
      value: z.number().nullish(),
      minimum: z.number().nullish(),
      maximum: z.number().nullish(),
      step: z.number().nullish(),
      disabled: z.boolean().nullish(),
      checks,
      enabled,
    }),
    events: ["change"],
    description:
      'Integer counter (guests, quantity). Show the live value in the label: { "$template": "Guests: ${/form/guests}" }.',
    example: {
      label: { $template: "Guests: ${/form/guests}" },
      value: { $bindState: "/form/guests" },
      minimum: 1,
      maximum: 10,
    },
  },

  Slider: {
    props: z.object({
      label: z.string(),
      value: z.number().nullish(),
      minimum: z.number(),
      maximum: z.number(),
      step: z.number().nullish(),
      showValue: z.boolean().nullish(),
      disabled: z.boolean().nullish(),
      checks,
      enabled,
    }),
    events: ["change"],
    description:
      "Numeric range (rating, budget). Seed value within minimum...maximum; showValue displays it.",
    example: {
      label: "Satisfaction",
      value: { $bindState: "/form/satisfaction" },
      minimum: 0,
      maximum: 10,
      step: 1,
      showValue: true,
    },
  },

  // ==========================================================================
  // Actions
  // ==========================================================================

  Button: {
    props: z.object({
      label: z.string(),
      systemImage: z.string().nullish(),
      role: z.enum(["cancel", "destructive"]).nullish(),
      style: z
        .enum([
          "automatic",
          "borderedProminent",
          "bordered",
          "borderless",
          "plain",
        ])
        .nullish(),
      disabled: z.boolean().nullish(),
    }),
    events: ["press"],
    description:
      'Tappable button; bind on.press to an action. The primary submit button uses style "borderedProminent". systemImage is an SF Symbol name (e.g. "paperplane").',
    example: { label: "Submit", style: "borderedProminent" },
  },
};

// =============================================================================
// Action Definitions
// =============================================================================

/**
 * Actions the native runtime handles. Hosts may register more by name.
 */
export const actionDefinitions = {
  submit: {
    params: z.object({
      data: z.unknown(),
    }),
    description:
      'Validate every visible field that has checks; if any fail, show the errors and stop. Otherwise send data to the app. Params: { "data": { "$state": "/form" } }.',
  },

  resetForm: {
    params: z.object({
      statePath: z.string().nullish(),
      value: z.unknown().optional(),
    }),
    description:
      "Restore the initial /state and clear validation errors. Params: none (or statePath + value to reset one path).",
  },

  setState: {
    params: z.object({
      statePath: z.string(),
      value: z.unknown(),
    }),
    description:
      'Set a state value. Params: { "statePath": "/form/plan", "value": "pro" }.',
  },

  pushState: {
    params: z.object({
      statePath: z.string(),
      value: z.unknown(),
      clearStatePath: z.string().nullish(),
    }),
    description:
      'Append value to the array at statePath. "$id" anywhere in value becomes a unique id; clearStatePath is reset to "" afterwards. Params: { "statePath": "/form/guests", "value": { "id": "$id", "name": { "$state": "/form/guestName" } }, "clearStatePath": "/form/guestName" }.',
  },

  removeState: {
    params: z.object({
      statePath: z.string(),
      index: z.number(),
    }),
    description:
      'Remove the array item at index. Params: { "statePath": "/form/tags", "index": 0 }.',
  },

  showAlert: {
    params: z.object({
      title: z.string(),
      message: z.string().nullish(),
    }),
    description: 'Show an alert. Params: { "title": "...", "message": "..." }.',
  },

  openURL: {
    params: z.object({
      url: z.string(),
    }),
    description:
      'Open a URL, e.g. terms of service. Params: { "url": "https://..." }.',
  },
};

export type ComponentName = keyof typeof componentDefinitions;
export type ActionName = keyof typeof actionDefinitions;
