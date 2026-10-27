import { describe, expect, it } from "vitest";
import {
  builtInValidationFunctions,
  compileSpecStream,
} from "@json-render/core";
import {
  builtInCheckTypes,
  catalog,
  checkTypeDescriptions,
  componentDefinitions,
  promptExampleJsonl,
  validateSwiftUISpec,
  validateSpecForCatalog,
  autoFixSwiftUISpec,
  actionDefinitions,
} from "../src/index";
import { fixtureSpecs } from "./helpers";

const ARCHITECTURE_COMPONENTS = [
  "Form",
  "Section",
  "VStack",
  "HStack",
  "Text",
  "TextField",
  "SecureField",
  "Toggle",
  "Picker",
  "DatePicker",
  "Stepper",
  "Slider",
  "LabeledContent",
  "Button",
  "Divider",
  "BarChart",
  "LineChart",
  "AreaChart",
  "PieChart",
];

const ARCHITECTURE_ACTIONS = [
  "setState",
  "pushState",
  "removeState",
  "resetForm",
  "submit",
  "showAlert",
  "openURL",
];

function minimalSpec(elements: Record<string, unknown>, state?: object) {
  return {
    root: "form",
    elements: {
      form: { type: "Form", props: {}, children: ["section"] },
      section: { type: "Section", props: {}, children: Object.keys(elements) },
      ...elements,
    },
    ...(state ? { state } : {}),
  };
}

describe("catalog", () => {
  it("contains exactly the ARCHITECTURE components and actions", () => {
    expect([...catalog.componentNames].sort()).toEqual(
      [...ARCHITECTURE_COMPONENTS].sort(),
    );
    expect([...catalog.actionNames].sort()).toEqual(
      [...ARCHITECTURE_ACTIONS].sort(),
    );
  });

  it("mirrors core's built-in validation functions", () => {
    expect([...builtInCheckTypes]).toEqual(
      Object.keys(builtInValidationFunctions),
    );
    expect(Object.keys(checkTypeDescriptions)).toEqual([...builtInCheckTypes]);
  });

  it("gives every component a description and valid example props", () => {
    for (const [name, def] of Object.entries(componentDefinitions)) {
      expect(def.description, name).toBeTruthy();
      if ("example" in def) {
        const spec = minimalSpec({
          sample: { type: name, props: def.example, children: [] },
        });
        const result = validateSwiftUISpec(catalog, spec);
        expect(result.issues, name).toEqual([]);
      }
    }
  });

  it("validates the prompt example", () => {
    const spec = compileSpecStream(promptExampleJsonl);
    expect(validateSwiftUISpec(catalog, spec)).toEqual({
      valid: true,
      issues: [],
    });
  });
});

describe("fixture specs", () => {
  for (const [file, spec] of fixtureSpecs()) {
    it(`${file} validates with no issues`, () => {
      expect(validateSwiftUISpec(catalog, spec)).toEqual({
        valid: true,
        issues: [],
      });
    });

    it(`${file} keeps state, on and visible through catalog.validate`, () => {
      const result = catalog.validate(spec);
      expect(result.success).toBe(true);
      expect(result.data).toEqual(spec);
    });
  }
});

describe("validateSwiftUISpec", () => {
  const field = (props: Record<string, unknown>, extra: object = {}) =>
    minimalSpec({
      field: { type: "TextField", props, children: [], ...extra },
    });

  it("accepts dynamic expressions in typed props", () => {
    const result = validateSwiftUISpec(
      catalog,
      minimalSpec({
        guests: {
          type: "Stepper",
          props: {
            label: { $template: "Guests: ${/form/guests}" },
            value: { $bindState: "/form/guests" },
            minimum: { $state: "/limits/min" },
            disabled: {
              $cond: { $state: "/form/locked" },
              $then: true,
              $else: false,
            },
            checks: [
              {
                type: "max",
                args: { max: { $state: "/limits/max" } },
                message: "Too many",
              },
            ],
          },
          children: [],
        },
      }),
    );
    expect(result).toEqual({ valid: true, issues: [] });
  });

  it("accepts null for optional props", () => {
    const result = validateSwiftUISpec(
      catalog,
      field({
        label: "Name",
        placeholder: null,
        keyboard: null,
        checks: null,
        validateOn: null,
      }),
    );
    expect(result).toEqual({ valid: true, issues: [] });
  });

  it("reports missing required props and bad enum values", () => {
    const result = validateSwiftUISpec(catalog, field({ keyboard: "numeric" }));
    expect(result.valid).toBe(false);
    expect(result.issues.map((i) => i.path).sort()).toEqual([
      "/elements/field/props/keyboard",
      "/elements/field/props/label",
    ]);
    expect(result.issues.every((i) => i.code === "props")).toBe(true);
  });

  it("checks validation check types and args", () => {
    const result = validateSwiftUISpec(
      catalog,
      field({
        label: "Code",
        checks: [
          { type: "minLength", args: { value: 3 }, message: "Too short" },
          { type: "isPrime", message: "Not prime" },
          { type: "required" },
        ],
      }),
    );
    expect(result.issues.map((i) => [i.severity, i.path])).toEqual([
      // Non-built-in types are host validators: a warning, not an error.
      ["warning", "/elements/field/props/checks/1/type"],
      ["error", "/elements/field/props/checks/0/args/min"],
      ["error", "/elements/field/props/checks/2/message"],
    ]);
  });

  it("reports unknown component types", () => {
    const result = validateSwiftUISpec(
      catalog,
      minimalSpec({ field: { type: "Input", props: {}, children: [] } }),
    );
    expect(result.valid).toBe(false);
    expect(result.issues[0]).toMatchObject({
      severity: "error",
      path: "/elements/field/type",
      code: "schema",
    });
  });

  it("reports core structural issues", () => {
    const result = validateSwiftUISpec(
      catalog,
      field({ label: "Name", visible: { $state: "/x" } }),
    );
    expect(result.issues).toContainEqual(
      expect.objectContaining({
        code: "visible_in_props",
        path: "/elements/field",
        severity: "error",
      }),
    );

    const dangling = validateSwiftUISpec(catalog, {
      root: "form",
      elements: { form: { type: "Form", props: {}, children: ["missing"] } },
    });
    expect(dangling.issues).toContainEqual(
      expect.objectContaining({ code: "missing_child", severity: "error" }),
    );
  });

  it("warns about unknown props, events and actions", () => {
    const result = validateSwiftUISpec(
      catalog,
      field(
        { label: "Name", name: "name" },
        {
          on: {
            press: { action: "track", params: {} },
            change: { action: "setState", params: { value: 1 } },
          },
        },
      ),
    );
    expect(result.issues.map((i) => [i.severity, i.code, i.path])).toEqual([
      ["warning", "unknown_prop", "/elements/field/props/name"],
      ["warning", "unknown_event", "/elements/field/on/press"],
      ["warning", "unknown_action", "/elements/field/on/press/action"],
      ["error", "action_params", "/elements/field/on/change/params/statePath"],
    ]);
  });

  it("rejects non-object specs and elements", () => {
    expect(validateSwiftUISpec(catalog, null).valid).toBe(false);
    expect(validateSwiftUISpec(catalog, { root: "a" }).valid).toBe(false);
    expect(
      validateSwiftUISpec(catalog, { root: "a", elements: { a: null } })
        .issues[0],
    ).toMatchObject({ path: "/elements/a", code: "schema" });
  });
});

describe("review regressions", () => {
  const textField = (
    props: unknown = { label: "Name" },
    extra: object = {},
  ) => ({
    root: "a",
    elements: { a: { type: "TextField", props, children: [], ...extra } },
  });
  const codes = (spec: unknown) =>
    validateSwiftUISpec(catalog, spec).issues.map((i) => [
      i.severity,
      i.code,
      i.path,
    ]);

  describe("1: malformed element fields are reported, never thrown", () => {
    it("non-array children", () => {
      const result = validateSwiftUISpec(
        catalog,
        textField(undefined, { children: 7 }),
      );
      expect(result.valid).toBe(false);
      expect(result.issues).toContainEqual(
        expect.objectContaining({
          code: "schema",
          path: "/elements/a/children",
        }),
      );
    });

    it("primitive props", () => {
      const result = validateSwiftUISpec(catalog, textField("x"));
      expect(result.valid).toBe(false);
      expect(codes(textField("x"))).toEqual([
        ["error", "schema", "/elements/a/props"],
      ]);
    });

    it("children containing non-strings, non-string root, null on/watch", () => {
      for (const spec of [
        textField(undefined, { children: ["b", 3, null] }),
        { ...textField(), root: 5 },
        textField(undefined, { on: null, watch: 3, visible: "x" }),
        textField(undefined, { type: 9 }),
        textField(undefined, { props: null }),
      ]) {
        expect(() => validateSwiftUISpec(catalog, spec)).not.toThrow();
        expect(validateSwiftUISpec(catalog, spec).valid).toBe(false);
      }
    });
  });

  describe("2: only well-formed expressions are accepted", () => {
    it("rejects a non-string $bindState path", () => {
      expect(
        codes(textField({ label: "Name", value: { $bindState: 42 } })),
      ).toEqual([["error", "expression", "/elements/a/props/value"]]);
    });

    it("rejects $cond without $else and $cond with an invalid condition", () => {
      expect(codes(textField({ label: { $cond: true, $then: "x" } }))).toEqual([
        ["error", "expression", "/elements/a/props/label"],
      ]);
      expect(
        codes(
          textField({
            label: { $cond: { $state: 1 }, $then: "x", $else: "y" },
          }),
        ),
      ).toEqual([["error", "expression", "/elements/a/props/label"]]);
    });

    it("type-checks both $cond branches and $template results", () => {
      expect(
        codes(
          textField({
            label: "Name",
            keyboard: {
              $cond: { $state: "/form/x" },
              $then: "email",
              $else: "telephone",
            },
          }),
        ),
      ).toEqual([["error", "props", "/elements/a/props/keyboard/$else"]]);
      const stepper = {
        root: "a",
        elements: {
          a: {
            type: "Stepper",
            props: { label: "Guests", value: { $template: "${/form/guests}" } },
            children: [],
          },
        },
      };
      expect(codes(stepper)).toEqual([
        ["error", "props", "/elements/a/props/value"],
      ]);
    });

    it("does not treat the props container itself as an expression", () => {
      expect(codes(textField({ $state: 42 }))).toEqual([
        ["error", "props", "/elements/a/props/label"],
        ["warning", "unknown_prop", "/elements/a/props/$state"],
      ]);
    });

    it("does not treat action params as an expression", () => {
      expect(
        codes(
          textField(undefined, {
            on: { submit: { action: "submit", params: { $state: "/form" } } },
          }),
        ),
      ).toEqual([
        ["error", "action_params", "/elements/a/on/submit/params/data"],
      ]);
    });

    it("rejects malformed expressions nested in check args", () => {
      expect(
        codes(
          textField({
            label: "Name",
            checks: [
              {
                type: "minLength",
                args: { min: { $state: null } },
                message: "x",
              },
            ],
          }),
        ),
      ).toEqual([
        ["error", "expression", "/elements/a/props/checks/0/args/min"],
      ]);
    });

    it("warns on out-of-scope expressions", () => {
      expect(codes(textField({ label: { $item: "title" } }))).toEqual([
        ["warning", "unsupported_expression", "/elements/a/props/label"],
      ]);
    });

    it("still accepts valid dynamic values everywhere", () => {
      expect(
        codes(
          textField(
            {
              label: {
                $cond: { $state: "/form/x" },
                $then: { $template: "A ${/x}" },
                $else: "B",
              },
              value: { $bindState: "/form/name" },
              disabled: { $state: "/form/locked" },
              checks: [
                {
                  type: "maxLength",
                  args: { max: { $state: "/limits/max" } },
                  message: "x",
                },
                {
                  type: "matches",
                  args: { other: { $state: "/form/other" } },
                  message: "y",
                },
              ],
            },
            {
              on: {
                submit: {
                  action: "setState",
                  params: { statePath: "/x", value: { $state: "/y" } },
                },
              },
            },
          ),
        ),
      ).toEqual([]);
    });
  });

  describe("3: repeat and slots are ignored", () => {
    it("repeat over missing state is not an error", () => {
      const spec = {
        root: "form",
        elements: {
          form: {
            type: "Form",
            props: {},
            children: ["t"],
            repeat: { statePath: "/absent" },
          },
          t: { type: "Text", props: { content: "Hi" }, children: [] },
        },
        state: {},
      };
      expect(validateSwiftUISpec(catalog, spec)).toEqual({
        valid: true,
        issues: [],
      });
    });

    it("dangling slot references are not an error", () => {
      expect(
        validateSwiftUISpec(
          catalog,
          textField(undefined, { slots: { default: ["missing"] } }),
        ),
      ).toEqual({ valid: true, issues: [] });
    });

    it("malformed repeat / slots do not throw", () => {
      for (const extra of [
        { repeat: null },
        { slots: { default: null } },
        { slots: 5 },
      ]) {
        expect(
          validateSwiftUISpec(catalog, textField(undefined, extra)),
        ).toEqual({
          valid: true,
          issues: [],
        });
        expect(() =>
          autoFixSwiftUISpec(textField(undefined, extra)),
        ).not.toThrow();
      }
    });

    it("autoFix preserves ignored and malformed fields unchanged", () => {
      const spec = {
        root: "form",
        elements: {
          form: {
            type: "Form",
            props: {},
            children: ["a", "ghost"],
            slots: { default: null },
            repeat: null,
          },
          a: { type: "TextField", props: "x", children: 7 },
          b: null,
        },
      };
      expect(autoFixSwiftUISpec(spec)).toEqual({
        root: "form",
        elements: {
          form: {
            type: "Form",
            props: {},
            children: ["a"],
            slots: { default: null },
            repeat: null,
          },
          a: { type: "TextField", props: "x", children: 7 },
          b: null,
        },
      });
      expect(autoFixSwiftUISpec(null)).toBe(null);
      expect(autoFixSwiftUISpec({ root: "a" })).toEqual({ root: "a" });
    });
  });

  describe("4: watch bindings are validated like on bindings", () => {
    const binding = { action: "setState", params: { value: 1 } };

    it("missing params", () => {
      expect(
        codes(textField(undefined, { watch: { "/form/a": binding } })),
      ).toEqual([
        [
          "error",
          "action_params",
          "/elements/a/watch/~1form~1a/params/statePath",
        ],
      ]);
      expect(codes(textField(undefined, { on: { change: binding } }))).toEqual([
        ["error", "action_params", "/elements/a/on/change/params/statePath"],
      ]);
    });

    it("malformed bindings, arrays and unknown actions", () => {
      expect(
        codes(
          textField(undefined, {
            watch: {
              "/form/a": [
                { action: "track" },
                "oops",
                { action: "openURL", params: 3 },
              ],
            },
          }),
        ),
      ).toEqual([
        ["warning", "unknown_action", "/elements/a/watch/~1form~1a/0/action"],
        ["error", "action_params", "/elements/a/watch/~1form~1a/1"],
        ["error", "action_params", "/elements/a/watch/~1form~1a/2/params"],
      ]);
    });
  });

  describe("checks accept core ValidationConfig.enabled", () => {
    const withEnabled = (enabled: unknown) =>
      textField({
        label: "Company",
        value: { $bindState: "/form/company" },
        checks: [{ type: "required", message: "Required" }],
        enabled,
      });

    it("accepts visibility conditions", () => {
      for (const enabled of [
        { $state: "/form/accountType", eq: "business" },
        [{ $state: "/form/a" }, { $state: "/form/b", not: true }],
        { $or: [{ $state: "/form/a" }, { $state: "/form/n", gt: 2 }] },
        true,
        null,
      ]) {
        expect(validateSwiftUISpec(catalog, withEnabled(enabled))).toEqual({
          valid: true,
          issues: [],
        });
      }
    });

    it("rejects malformed conditions instead of treating them as expressions", () => {
      for (const enabled of [
        { $state: "/form/a", eq: 1, bogus: true },
        { $cond: { $state: "/x" }, $then: true, $else: false },
        "yes",
      ]) {
        expect(codes(withEnabled(enabled))).toEqual([
          ["error", "props", "/elements/a/props/enabled"],
        ]);
      }
    });

    it("is available on every component that takes checks", () => {
      for (const [name, def] of Object.entries(componentDefinitions)) {
        const shape = (
          def.props as unknown as { shape: Record<string, unknown> }
        ).shape;
        expect("enabled" in shape, name).toBe("checks" in shape);
      }
    });
  });

  describe("host-registered validators and actions", () => {
    const withChecks = (checks: unknown[], extra: object = {}) =>
      textField({ label: "Card", checks }, extra);

    it("custom check types warn instead of failing", () => {
      expect(
        codes(
          withChecks([
            { type: "luhn", args: { digits: 16 }, message: "Invalid card" },
          ]),
        ),
      ).toEqual([
        ["warning", "unknown_check", "/elements/a/props/checks/0/type"],
      ]);
    });

    it("hostValidators suppresses the warning", () => {
      const spec = withChecks([
        { type: "required", message: "Required" },
        { type: "luhn", message: "Invalid card" },
      ]);
      expect(
        validateSpecForCatalog(catalog, spec, { hostValidators: ["luhn"] }),
      ).toEqual({ valid: true, issues: [] });
    });

    it("custom checks still need a message and object args", () => {
      expect(
        codes(
          withChecks([
            { type: "luhn", args: 3 },
            { type: "required", args: { x: 1 } },
          ]),
        ),
      ).toEqual([
        ["warning", "unknown_check", "/elements/a/props/checks/0/type"],
        ["error", "props", "/elements/a/props/checks/0/args"],
        ["error", "props", "/elements/a/props/checks/0/message"],
        ["error", "props", "/elements/a/props/checks/1/message"],
      ]);
    });

    it("built-in check args are still type-checked", () => {
      expect(
        codes(
          withChecks([{ type: "minLength", args: { value: 3 }, message: "x" }]),
        ),
      ).toEqual([["error", "props", "/elements/a/props/checks/0/args/min"]]);
    });

    it("hostActions suppresses unknown_action", () => {
      const spec = textField(undefined, {
        on: { submit: { action: "track", params: {} } },
        watch: { "/form/a": [{ action: "track" }, { action: "other" }] },
      });
      expect(
        validateSpecForCatalog(catalog, spec, {
          hostActions: ["track"],
        }).issues.map((i) => [i.code, i.path]),
      ).toEqual([["unknown_action", "/elements/a/watch/~1form~1a/1/action"]]);
    });
  });

  it("pushState documents clearStatePath and $id", () => {
    const pushState = actionDefinitions.pushState;
    expect(Object.keys(pushState.params.shape)).toEqual([
      "statePath",
      "value",
      "clearStatePath",
    ]);
    expect(pushState.description).toContain('"$id"');
    expect(catalog.prompt()).toContain("clearStatePath");
    expect(
      codes(
        textField(undefined, {
          on: {
            submit: {
              action: "pushState",
              params: {
                statePath: "/xs",
                value: { id: "$id" },
                clearStatePath: "/x",
              },
            },
          },
        }),
      ),
    ).toEqual([]);
  });
});
