/**
 * Dev-only: maps the json-render PDF form components onto @react-pdf/renderer 4.9 so the
 * upstream renderer can draw reference PDFs (see render-pdf-references.ts). Geometry follows
 * docs/PDF-FORMS.md: text 22 pt (multiline lines x 14 + 8), checkbox 12 pt, select 22 pt,
 * list rows x 14 + 6, labels drawn as static text outside the widget.
 *
 * react-pdf limits (the native renderer does better):
 * - choices are plain strings, so Select/ListBox options use their labels as /Opt and value;
 * - ListBox `value` is a single string (first selected option);
 * - there is no radio button: RadioGroup is drawn as static "(x) / ( )" text;
 * - nested react-pdf FieldSets make renderToBuffer hang forever, so only the outermost
 *   FieldSet becomes a react-pdf FieldSet; inner FieldSets are Views and prefix their
 *   fields' partial names ("address.street"), giving the same fully qualified names.
 */
import React from "react";
import {
  Checkbox as PdfCheckbox,
  FieldSet as PdfFieldSet,
  List as PdfList,
  Select as PdfSelect,
  Text as PdfText,
  TextInput as PdfTextInput,
  View,
} from "@react-pdf/renderer";

const h = React.createElement;

/** Names of FieldSets nested inside the outermost one; null outside any FieldSet. */
const FieldSetScope = React.createContext<string[] | null>(null);

function useFieldName(name: unknown): string | undefined {
  const scope = React.useContext(FieldSetScope);
  if (typeof name !== "string") return undefined;
  return scope && scope.length > 0 ? [...scope, name].join(".") : name;
}

interface Option {
  label: string;
  value: string;
}

type Props = Record<string, unknown> & {
  name?: string;
  label?: string | null;
  options?: Option[];
};

interface RenderProps {
  element: { props: Props };
  children?: React.ReactNode;
}

const border = {
  borderWidth: 1,
  borderColor: "#9ca3af",
  borderStyle: "solid" as const,
};

function label(text: unknown, hint?: unknown): React.ReactElement | null {
  if (typeof text !== "string" || text === "") return null;
  return h(
    PdfText,
    { style: { fontSize: 9, color: "#374151", marginBottom: 2 } },
    text,
    typeof hint === "string" && hint !== ""
      ? h(PdfText, { style: { color: "#9ca3af" } }, `  ${hint}`)
      : null,
  );
}

const str = (v: unknown) => (typeof v === "string" && v !== "" ? v : undefined);
const num = (v: unknown) => (typeof v === "number" ? v : undefined);

function labelFor(
  options: Option[] | undefined,
  value: unknown,
): string | undefined {
  return options?.find((o) => o.value === value)?.label;
}

function FieldSet({ element, children }: RenderProps) {
  const p = element.props;
  const scope = React.useContext(FieldSetScope);
  const name = typeof p.name === "string" ? p.name : "group";
  const body =
    scope === null
      ? h(
          FieldSetScope.Provider,
          { value: [] },
          h(PdfFieldSet, { name }, children),
        )
      : h(
          FieldSetScope.Provider,
          { value: [...scope, name] },
          h(View, null, children),
        );
  return h(
    View,
    { style: { marginBottom: 4 } },
    typeof p.label === "string"
      ? h(
          PdfText,
          {
            style: {
              fontSize: scope === null ? 11 : 10,
              fontFamily: "Helvetica-Bold",
              marginBottom: 4,
            },
          },
          p.label,
        )
      : null,
    body,
  );
}

function TextInput({ element }: RenderProps) {
  const p = element.props;
  const lines = num(p.lines) ?? 3;
  return h(
    View,
    null,
    label(p.label, p.placeholder),
    h(PdfTextInput as unknown as React.ComponentType<Record<string, unknown>>, {
      name: useFieldName(p.name),
      value: str(p.value),
      multiline: p.multiline === true,
      password: p.password === true,
      maxLength: num(p.maxLength),
      required: p.required === true,
      readOnly: p.readOnly === true,
      align: p.align ?? undefined,
      fontSize: num(p.fontSize) ?? 10,
      style: {
        ...border,
        width: num(p.width) ?? "100%",
        height: p.multiline === true ? lines * 14 + 8 : 22,
      },
    }),
  );
}

function Checkbox({ element }: RenderProps) {
  const p = element.props;
  return h(
    View,
    { style: { flexDirection: "row", alignItems: "center", gap: 6 } },
    h(PdfCheckbox as unknown as React.ComponentType<Record<string, unknown>>, {
      name: useFieldName(p.name),
      checked: p.checked === true,
      onState: str(p.exportValue) ?? "Yes",
      offState: "Off",
      required: p.required === true,
      readOnly: p.readOnly === true,
      style: { ...border, width: 12, height: 12 },
    }),
    h(PdfText, { style: { fontSize: 10 } }, String(p.label ?? "")),
  );
}

function Select({ element }: RenderProps) {
  const p = element.props;
  return h(
    View,
    null,
    label(p.label),
    h(PdfSelect as unknown as React.ComponentType<Record<string, unknown>>, {
      name: useFieldName(p.name),
      select: (p.options ?? []).map((o) => o.label),
      value: labelFor(p.options, p.value),
      edit: p.editable === true,
      noSpell: true,
      required: p.required === true,
      readOnly: p.readOnly === true,
      style: {
        ...border,
        width: num(p.width) ?? "100%",
        height: 22,
        fontSize: 10,
      },
    }),
  );
}

function ListBox({ element }: RenderProps) {
  const p = element.props;
  const first = Array.isArray(p.value) ? p.value[0] : p.value;
  const rows = num(p.rows) ?? 4;
  return h(
    View,
    null,
    label(p.label),
    h(PdfList as unknown as React.ComponentType<Record<string, unknown>>, {
      name: useFieldName(p.name),
      select: (p.options ?? []).map((o) => o.label),
      value: labelFor(p.options, first),
      multiSelect: p.multiSelect === true,
      edit: false,
      noSpell: true,
      required: p.required === true,
      readOnly: p.readOnly === true,
      style: { ...border, width: "100%", height: rows * 14 + 6, fontSize: 10 },
    }),
  );
}

function RadioGroup({ element }: RenderProps) {
  const p = element.props;
  const horizontal = p.direction === "horizontal";
  return h(
    View,
    null,
    label(p.label, "(radio group: static in this reference)"),
    h(
      View,
      {
        style: {
          flexDirection: horizontal ? "row" : "column",
          gap: horizontal ? 14 : 3,
        },
      },
      ...(p.options ?? []).map((o, i) =>
        h(
          PdfText,
          { key: i, style: { fontSize: 10 } },
          `${o.value === p.value ? "(x)" : "( )"} ${o.label}`,
        ),
      ),
    ),
  );
}

export const formReferenceComponents = {
  FieldSet,
  TextInput,
  Checkbox,
  RadioGroup,
  Select,
  ListBox,
};
