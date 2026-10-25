import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { compileSpecStream, createSpecStreamCompiler } from "@json-render/core";
import type { Spec } from "@json-render/core";
import {
  pdfCatalog,
  pdfFormComponentDefinitions,
  pdfFormFieldTypes,
  validateSpecForCatalog,
} from "../src/index";
import { chunk, readJSON, readText, repoDir } from "./helpers";

const form = readJSON<Spec>(
  join(repoDir, "fixtures/pdf/application-form.json"),
);
const formJsonl = readText(
  join(repoDir, "fixtures/pdf/application-form.jsonl"),
);

const validate = (spec: unknown) => validateSpecForCatalog(pdfCatalog, spec);
const codes = (spec: unknown) =>
  validate(spec).issues.map((i) => [i.severity, i.code, i.path]);

const doc = (elements: Record<string, unknown>, state?: object) => ({
  root: "doc",
  elements: {
    doc: { type: "Document", props: {}, children: ["page"] },
    page: {
      type: "Page",
      props: { size: "A4" },
      children: Object.keys(elements).filter((k) => !k.startsWith("_")),
    },
    // Keys starting with "_" are not page children; the prefix is dropped (also in children).
    ...Object.fromEntries(
      Object.entries(elements).map(([k, v]) => {
        const el = v as { children?: string[] };
        return [
          k.replace(/^_/, ""),
          {
            ...el,
            children: (el.children ?? []).map((c) => c.replace(/^_/, "")),
          },
        ];
      }),
    ),
  },
  ...(state ? { state } : {}),
});
const input = (name: unknown, extra: object = {}) => ({
  type: "TextInput",
  props: { name, ...extra },
  children: [],
});
const fieldSet = (name: unknown, children: string[], extra: object = {}) => ({
  type: "FieldSet",
  props: { name },
  children,
  ...extra,
});
const choice = (type: string, props: object) => ({
  type,
  props: {
    name: "pick",
    options: [
      { label: "A", value: "a" },
      { label: "B", value: "b" },
    ],
    ...props,
  },
  children: [],
});

describe("pdf form components", () => {
  it("adds the contract's form components", () => {
    expect(Object.keys(pdfFormComponentDefinitions)).toEqual([
      "FieldSet",
      ...pdfFormFieldTypes,
    ]);
    expect(pdfFormComponentDefinitions.FieldSet.slots).toEqual(["default"]);
    for (const type of pdfFormFieldTypes) {
      expect(pdfFormComponentDefinitions[type].slots, type).toEqual([]);
    }
  });

  it("lists the form components and rules in the prompt", () => {
    const prompt = pdfCatalog.prompt();
    for (const name of Object.keys(pdfFormComponentDefinitions)) {
      expect(prompt).toContain(`- ${name}: `);
    }
    expect(prompt).toContain("FILLABLE FORMS");
    expect(prompt).toContain("never put fields inside a Table");
    expect(prompt).toContain("RadioGroup for 2-5 mutually exclusive options");
    expect(prompt).toContain(
      'never "Off" for RadioGroup values or a Checkbox exportValue',
    );
  });
});

describe("application-form fixture", () => {
  it("validates with no issues", () => {
    expect(validate(form)).toEqual({ valid: true, issues: [] });
  });

  it("uses every form component, nested FieldSets, multiline, multiSelect and prefilled state", () => {
    const elements = Object.values(form.elements);
    const types = new Set(elements.map((e) => e.type));
    for (const type of [
      "FieldSet",
      ...pdfFormFieldTypes,
      "Heading",
      "Text",
      "Divider",
      "PageNumber",
    ]) {
      expect(types.has(type), type).toBe(true);
    }
    expect(form.elements.address!.type).toBe("FieldSet"); // inside FieldSet "applicant"
    expect(
      elements.some(
        (e) => e.type === "TextInput" && e.props.multiline === true,
      ),
    ).toBe(true);
    expect(
      elements.some(
        (e) => e.type === "ListBox" && e.props.multiSelect === true,
      ),
    ).toBe(true);
    expect(JSON.stringify(form)).toContain('"$state":"/applicant/firstName"');
    expect(form.elements.references!.repeat).toEqual({
      statePath: "/references",
      key: "id",
    });
  });

  it("application-form.jsonl compiles to the spec, including split chunks", () => {
    expect(compileSpecStream(formJsonl)).toEqual(form);
    const compiler = createSpecStreamCompiler<Spec>({ root: "", elements: {} });
    for (const piece of chunk(formJsonl, 53)) compiler.push(piece);
    expect(compiler.getResult()).toEqual(form);
  });
});

describe("form field validation", () => {
  it("rejects duplicate fully qualified names", () => {
    expect(codes(doc({ a: input("email"), b: input("email") }))).toEqual([
      ["error", "duplicate_field_name", "/elements/b/props/name"],
    ]);
  });

  it("qualifies names with FieldSet nesting", () => {
    expect(
      validate(
        doc({
          home: fieldSet("home", ["_home-street"]),
          work: fieldSet("work", ["_work-outer"]),
          "_home-street": input("street"),
          "_work-outer": fieldSet("address", ["_work-street"]),
          "_work-street": input("street"),
          street: input("street"),
        }),
      ),
    ).toEqual({ valid: true, issues: [] });

    expect(
      codes(
        doc({
          a: fieldSet("home", ["_x"]),
          b: fieldSet("home", ["_y"]),
          _x: input("street"),
          _y: input("street"),
        }),
      ),
    ).toEqual([
      // Two FieldSets with one name are rejected (review #3), as are their colliding fields.
      ["error", "duplicate_field_name", "/elements/b/props/name"],
      ["error", "duplicate_field_name", "/elements/y/props/name"],
    ]);
  });

  it("FieldSet and field names share one namespace (review #3)", () => {
    expect(
      codes(
        doc({
          person: input("person"),
          group: fieldSet("person", ["_name"]),
          _name: input("name"),
        }),
      ),
    ).toEqual([
      ["error", "duplicate_field_name", "/elements/group/props/name"],
    ]);
    // A field may reuse a FieldSet's name at a different level.
    expect(
      validate(
        doc({ group: fieldSet("person", ["_inner"]), _inner: input("person") }),
      ),
    ).toEqual({ valid: true, issues: [] });
  });

  it('rejects "Off" and empty button states (review #1); choices may use "Off"', () => {
    expect(
      codes(
        doc({
          consent: {
            type: "Checkbox",
            props: {
              name: "consent",
              label: "OK",
              checked: true,
              exportValue: "Off",
            },
            children: [],
          },
          empty: {
            type: "Checkbox",
            props: { name: "empty", label: "OK", exportValue: "" },
            children: [],
          },
          radio: choice("RadioGroup", {
            name: "radio",
            options: [
              { label: "On", value: "On" },
              { label: "Off", value: "Off" },
            ],
            value: "Off",
          }),
          select: choice("Select", {
            name: "select",
            options: [
              { label: "On", value: "On" },
              { label: "Off", value: "Off" },
            ],
            value: "Off",
          }),
          list: choice("ListBox", {
            name: "list",
            options: [{ label: "Off", value: "Off" }],
            value: ["Off"],
            multiSelect: true,
          }),
        }),
      ),
    ).toEqual([
      ["error", "reserved_value", "/elements/consent/props/exportValue"],
      ["error", "reserved_value", "/elements/empty/props/exportValue"],
      ["error", "reserved_value", "/elements/radio/props/options/1/value"],
    ]);
  });

  it("resolves $state / $template names outside a repeat for the duplicate check", () => {
    expect(
      codes(
        doc(
          {
            a: input({ $state: "/fieldName" }),
            b: input({ $template: "${/prefix}name" }),
          },
          { fieldName: "fullname", prefix: "full" },
        ),
      ),
    ).toEqual([["error", "duplicate_field_name", "/elements/b/props/name"]]);
  });

  it("rejects empty names and names containing a dot", () => {
    expect(codes(doc({ a: input(""), b: input("a.b") }))).toEqual([
      ["error", "invalid_field_name", "/elements/a/props/name"],
      ["error", "invalid_field_name", "/elements/b/props/name"],
    ]);
  });

  it("warns when a repeated field's name does not vary per item", () => {
    const repeated = (fieldName: unknown, setName?: unknown) =>
      doc(
        {
          rows: {
            type: "Column",
            props: {},
            repeat: { statePath: "/rows", key: "id" },
            children: setName === undefined ? ["_field"] : ["_set"],
          },
          ...(setName === undefined
            ? {}
            : { _set: fieldSet(setName, ["_field"]) }),
          _field: input(fieldName),
        },
        { rows: [{ id: "1" }, { id: "2" }], prefix: "x" },
      );
    expect(codes(repeated("name"))).toEqual([
      ["warning", "repeated_field_name", "/elements/field/props/name"],
    ]);
    expect(codes(repeated({ $template: "${/prefix}_name" }))).toEqual([
      ["warning", "repeated_field_name", "/elements/field/props/name"],
    ]);
    // Varies per item: templated with an item field, $item, or an enclosing FieldSet that varies.
    expect(validate(repeated({ $template: "name_${id}" }))).toEqual({
      valid: true,
      issues: [],
    });
    expect(validate(repeated({ $item: "id" }))).toEqual({
      valid: true,
      issues: [],
    });
    expect(validate(repeated("name", { $template: "row${id}" }))).toEqual({
      valid: true,
      issues: [],
    });
  });

  it("checks option values", () => {
    expect(
      codes(
        doc({
          dup: choice("RadioGroup", {
            name: "dup",
            options: [
              { label: "A", value: "a" },
              { label: "Also A", value: "a" },
            ],
          }),
          bad: choice("Select", { name: "bad", value: "c" }),
          free: choice("Select", {
            name: "free",
            value: "typed",
            editable: true,
          }),
          empty: choice("RadioGroup", { name: "empty", value: "" }),
          list: choice("ListBox", {
            name: "list",
            value: ["a", "z"],
            multiSelect: true,
          }),
          single: choice("ListBox", { name: "single", value: ["a", "b"] }),
          bound: choice("Select", { name: "bound", value: { $state: "/x" } }),
        }),
      ),
    ).toEqual([
      ["error", "duplicate_option", "/elements/dup/props/options/1/value"],
      ["error", "invalid_option_value", "/elements/bad/props/value"],
      ["error", "invalid_option_value", "/elements/list/props/value"],
      ["warning", "invalid_option_value", "/elements/single/props/value"],
    ]);
  });

  it("ignores unreachable elements", () => {
    const spec = doc({ a: input("x"), _orphan: input("x") });
    expect(validate(spec)).toEqual({ valid: true, issues: [] });
  });
});

describe("pdf-form-fields parity fixture", () => {
  const { description, cases } = readJSON<{
    description: string;
    cases: {
      name: string;
      expected: { name: string; pointer: string | null }[];
    }[];
  }>(join(repoDir, "fixtures/parity/pdf-form-fields.json"));

  it("documents the FormFieldInfo shape and covers the application form", () => {
    expect(description).toContain("FormFieldInfo");
    const app = cases.find((c) => c.name === "application-form fixture")!;
    const names = app.expected.map((f) => f.name);
    expect(new Set(names).size).toBe(names.length);
    expect(names).toContain("applicant.address.street");
    expect(names).toContain("reference2.relationship");
    expect(
      app.expected.find((f) => f.name === "reference2.relationship")!.pointer,
    ).toBe("/references/1/relationship");
  });

  it("pins the #2 suffix for duplicate names", () => {
    const dup = cases.find((c) => c.name.startsWith("duplicate names"))!;
    expect(dup.expected.map((f) => f.name)).toEqual([
      "outer.inner.x",
      "agree",
      "agree#2",
    ]);
  });
});
