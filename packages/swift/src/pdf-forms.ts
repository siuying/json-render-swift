import { z } from "zod";

/**
 * Set on `pdfCatalog`: `validateSpecForCatalog` runs the PDF form-field checks only for catalogs
 * carrying it, never because a catalog happens to have a `FieldSet` component. A registered
 * symbol, so separately bundled copies of this module (tsup's CommonJS entries) agree.
 */
export const pdfFormFieldsMarker = Symbol.for(
  "@json-render/swift/pdf-form-fields",
);

/** True for the built-in PDF catalog (see `pdfFormFieldsMarker`). */
export function hasPdfFormFields(catalog: object): boolean {
  return (catalog as Record<symbol, unknown>)[pdfFormFieldsMarker] === true;
}

// =============================================================================
// Fillable PDF form components (AcroForm). Names follow @react-pdf/renderer 4.9
// (FieldSet, TextInput, Checkbox, Select; List -> ListBox to avoid clashing with the
// static List) plus RadioGroup, which react-pdf lacks. See docs/PDF-FORMS.md.
// Optional props are `.nullable()` like upstream's PDF catalog (omitted = null).
// =============================================================================

/** A choice: `label` is shown, `value` is the PDF export value read back from the filled form. */
const option = z.object({
  label: z.string(),
  value: z.string(),
});

const fieldName = z.string();

export const pdfFormComponentDefinitions = {
  FieldSet: {
    props: z.object({
      name: fieldName,
      label: z.string().nullable(),
    }),
    slots: ["default"],
    description:
      'Groups related form fields under an optional label and scopes their names: a TextInput "email" inside FieldSet "applicant" is the PDF field "applicant.email". May nest.',
    example: { name: "applicant", label: "Applicant" },
  },

  TextInput: {
    props: z.object({
      name: fieldName,
      label: z.string().nullable(),
      value: z.string().nullable(),
      placeholder: z.string().nullable(),
      required: z.boolean().nullable(),
      readOnly: z.boolean().nullable(),
      maxLength: z.number().nullable(),
      multiline: z.boolean().nullable(),
      lines: z.number().nullable(),
      password: z.boolean().nullable(),
      align: z.enum(["left", "center", "right"]).nullable(),
      fontSize: z.number().nullable(),
      width: z.number().nullable(),
    }),
    slots: [],
    description:
      "Fillable text field with its label drawn above. multiline + lines (visible lines) for longer answers; width in points (default: full width). placeholder is a short format hint shown with the label, e.g. MM/DD/YYYY.",
    example: {
      name: "email",
      label: "Email",
      value: { $state: "/applicant/email" },
      placeholder: "name@example.com",
      required: true,
    },
  },

  Checkbox: {
    props: z.object({
      name: fieldName,
      label: z.string(),
      checked: z.boolean().nullable(),
      required: z.boolean().nullable(),
      readOnly: z.boolean().nullable(),
      exportValue: z.string().nullable(),
    }),
    slots: [],
    description:
      'Fillable yes/no box with its label to the right. exportValue is the value stored when checked (default "Yes").',
    example: {
      name: "consent",
      label: "I agree to the terms",
      checked: false,
      required: true,
    },
  },

  RadioGroup: {
    props: z.object({
      name: fieldName,
      label: z.string().nullable(),
      options: z.array(option),
      value: z.string().nullable(),
      direction: z.enum(["vertical", "horizontal"]).nullable(),
      required: z.boolean().nullable(),
      readOnly: z.boolean().nullable(),
    }),
    slots: [],
    description:
      "One choice from a few options, all visible as radio buttons. value is the selected option value.",
    example: {
      name: "status",
      label: "Employment status",
      options: [
        { label: "Employed", value: "employed" },
        { label: "Self-employed", value: "selfEmployed" },
        { label: "Student", value: "student" },
      ],
      value: "employed",
      direction: "horizontal",
    },
  },

  Select: {
    props: z.object({
      name: fieldName,
      label: z.string().nullable(),
      options: z.array(option),
      value: z.string().nullable(),
      editable: z.boolean().nullable(),
      required: z.boolean().nullable(),
      readOnly: z.boolean().nullable(),
      width: z.number().nullable(),
    }),
    slots: [],
    description:
      "Drop-down with one choice from a longer list. editable: true also accepts typed text.",
    example: {
      name: "state",
      label: "State",
      options: [
        { label: "California", value: "CA" },
        { label: "New York", value: "NY" },
      ],
      value: "CA",
      width: 140,
    },
  },

  ListBox: {
    props: z.object({
      name: fieldName,
      label: z.string().nullable(),
      options: z.array(option),
      value: z.union([z.string(), z.array(z.string())]).nullable(),
      multiSelect: z.boolean().nullable(),
      rows: z.number().nullable(),
      required: z.boolean().nullable(),
      readOnly: z.boolean().nullable(),
    }),
    slots: [],
    description:
      "Scrollable list showing `rows` options. With multiSelect: true several may be chosen and value is an array of option values.",
    example: {
      name: "languages",
      label: "Languages",
      options: [
        { label: "English", value: "en" },
        { label: "Spanish", value: "es" },
        { label: "French", value: "fr" },
      ],
      value: ["en"],
      multiSelect: true,
      rows: 3,
    },
  },
};

/** Component types that become AcroForm fields (FieldSet is a name scope, not a field). */
export const pdfFormFieldTypes = [
  "TextInput",
  "Checkbox",
  "RadioGroup",
  "Select",
  "ListBox",
] as const;

/** Prompt rules for fillable forms, appended after upstream's PDF rules. */
export const pdfFormRules = [
  "FILLABLE FORMS: Use TextInput, Checkbox, RadioGroup, Select and ListBox for anything the reader fills in; they become real PDF form fields. Give every field a short label and a camelCase name that is unique within its FieldSet (and differs from FieldSet names at the same level). Group related fields in a FieldSet (its name prefixes the field names, e.g. applicant.email); keep instructions and section titles as Heading/Text/Divider.",
  'Choices use options [{ "label": "Full time", "value": "fullTime" }] with unique values (never "Off" for RadioGroup values or a Checkbox exportValue); a preset value must be one of them. RadioGroup for 2-5 mutually exclusive options that should all be visible, Select for longer lists, ListBox with multiSelect: true when several may apply, Checkbox for a single yes/no or consent.',
  'Prefill fields from /state ("value": { "$state": "/applicant/name" }, "checked": { "$state": "/consent" }). Lay fields out with Row/Column (e.g. first and last name side by side); never put fields inside a Table. Inside a repeat, make names unique per item, e.g. "name": { "$template": "guest_${id}" } or a FieldSet named the same way.',
];
