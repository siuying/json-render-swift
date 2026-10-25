import { existsSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { defineCatalog, defineSchema } from "@json-render/core";
import type { Spec } from "@json-render/core";
import { z } from "zod";
import {
  catalog,
  pdfCatalog,
  pdfSchema,
  validateSpecForCatalog,
} from "../src/index";
import { installBridge } from "../src/bridge";
import type { JSONRenderBridgeAPI } from "../src/bridge";
import { testCatalog, testSpec } from "./fixtures/test-catalog";
import {
  chunk,
  packageDir,
  readJSON,
  readText,
  repoDir,
  specsDir,
} from "./helpers";

const bundlePath = join(packageDir, "dist", "json-render-bridge.js");
const swiftResource = join(
  repoDir,
  "swift/JSONRender/Sources/JSONRenderSwiftUI/Resources/json-render-bridge.js",
);
const testBundlePath = join(packageDir, "dist", "test-catalog-bridge.js");
const testFixture = join(repoDir, "fixtures/bridge/test-catalog-bridge.js");

// Checked before any test calls installBridge: importing the module must not install it.
const installedOnImport = "JSONRenderBridge" in globalThis;

/** Copy a value out of the vm realm so vitest compares plain host objects. */
const plain = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

let context: vm.Context;
let bridge: JSONRenderBridgeAPI;

beforeAll(() => {
  if (!existsSync(bundlePath)) {
    throw new Error(
      "dist/json-render-bridge.js is missing: run `pnpm build` first",
    );
  }
  // Bare context: no console, fetch, structuredClone, TextEncoder, setTimeout, URL...
  context = vm.createContext({});
  vm.runInContext(readText(bundlePath), context, {
    filename: "json-render-bridge.js",
  });
  bridge = vm.runInContext(
    "globalThis.JSONRenderBridge",
    context,
  ) as JSONRenderBridgeAPI;
});

const registration = readJSON<Spec>(join(specsDir, "registration.json"));
const registrationJsonl = readText(join(specsDir, "registration.jsonl"));

describe("bridge bundle in a bare JS context", () => {
  it("runs without host globals", () => {
    const globals = vm.runInContext(
      "['fetch','structuredClone','TextEncoder','setTimeout','process'].filter(function (k) { return typeof globalThis[k] !== 'undefined'; })",
      context,
    );
    expect(plain(globals)).toEqual([]);
    expect(typeof bridge).toBe("object");
  });

  it("installs only the built-in catalogs", () => {
    expect(() => bridge.catalogManifest({ catalog: "test" })).toThrow(
      "Unknown catalog: test (expected swiftui | pdf)",
    );
  });

  it("is the bundle copied into the Swift package", () => {
    expect(readText(swiftResource)).toBe(readText(bundlePath));
  });

  it("version()", () => {
    const pkg = readJSON<{ version: string }>(join(packageDir, "package.json"));
    expect(bridge.version()).toBe(pkg.version);
  });

  it("systemPrompt() matches catalog.prompt()", () => {
    expect(bridge.systemPrompt()).toBe(catalog.prompt());
    expect(bridge.systemPrompt(null)).toBe(catalog.prompt());
    const options = {
      customRules: ["Use metric units."],
      mode: "inline" as const,
    };
    expect(bridge.systemPrompt(options)).toBe(catalog.prompt(options));
    expect(bridge.systemPrompt(JSON.stringify(options))).toBe(
      catalog.prompt(options),
    );
  });

  it("buildUserPrompt() for fresh and edit prompts", () => {
    const fresh = bridge.buildUserPrompt({
      prompt: "A newsletter signup form",
    });
    expect(fresh.startsWith("A newsletter signup form")).toBe(true);
    expect(fresh).toContain("Output /root first");

    const edit = bridge.buildUserPrompt(
      JSON.stringify({
        prompt: "Add a phone field",
        currentSpec: registration,
        state: { form: { email: "a@b.co" } },
      }),
    );
    expect(edit).toContain("CURRENT UI STATE");
    expect(edit).toContain("USER REQUEST: Add a phone field");
    expect(edit).toContain("AVAILABLE STATE");
  });

  it("catalogManifest()", () => {
    expect(plain(bridge.catalogManifest())).toEqual({
      components: catalog.componentNames,
      actions: catalog.actionNames,
    });
  });

  it("jsonSchema()", () => {
    const schema = plain(bridge.jsonSchema()) as {
      type: string;
      properties: Record<
        string,
        { additionalProperties?: { properties?: object } }
      >;
      required: string[];
    };
    expect(schema.type).toBe("object");
    expect(schema.required).toEqual(["root", "elements"]);
    expect(Object.keys(schema.properties)).toEqual([
      "root",
      "elements",
      "state",
    ]);
    expect(
      Object.keys(
        schema.properties.elements!.additionalProperties!.properties!,
      ),
    ).toEqual(["type", "props", "children", "visible", "on", "watch"]);
    expect(plain(bridge.jsonSchema({ strict: false }))).toEqual(
      catalog.jsonSchema(),
    );
  });

  it("jsonSchema({ strict: true }) is rejected with an explanation", () => {
    // core's strict conversion closes dynamic-key maps: elements could only be {}.
    const strict = catalog.jsonSchema({ strict: true }) as {
      properties: { elements: object };
    };
    expect(strict.properties.elements).toEqual({
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false,
    });
    expect(() => bridge.jsonSchema({ strict: true })).toThrow(
      /strict: true \}\) is not supported/,
    );
    const viaInvoke = JSON.parse(
      bridge.invoke(
        "jsonSchema",
        JSON.stringify([{ catalog: "pdf", strict: true }]),
      ),
    );
    expect(viaInvoke.error.message).toMatch(/JSONL patch stream/);
  });

  it("validateSpec() accepts hostValidators / hostActions", () => {
    const spec = {
      root: "form",
      elements: {
        form: { type: "Form", props: {}, children: ["code"] },
        code: {
          type: "TextField",
          props: {
            label: "Code",
            value: { $bindState: "/form/code" },
            checks: [
              { type: "luhn", args: { digits: 16 }, message: "Invalid card" },
            ],
          },
          on: { submit: { action: "track", params: { event: "code" } } },
          children: [],
        },
      },
      state: { form: { code: "" } },
    };
    expect(
      plain(bridge.validateSpec(spec)).issues.map((i) => [i.severity, i.code]),
    ).toEqual([
      ["warning", "unknown_check"],
      ["warning", "unknown_action"],
    ]);
    expect(
      plain(
        bridge.validateSpec(
          JSON.stringify(spec),
          JSON.stringify({ hostValidators: ["luhn"], hostActions: ["track"] }),
        ),
      ),
    ).toEqual({ valid: true, issues: [] });
  });

  it("validateSpec() accepts objects and JSON strings", () => {
    expect(plain(bridge.validateSpec(registration))).toEqual({
      valid: true,
      issues: [],
    });
    expect(plain(bridge.validateSpec(JSON.stringify(registration)))).toEqual({
      valid: true,
      issues: [],
    });

    const broken = structuredClone(registration);
    broken.elements.email!.props = {
      ...broken.elements.email!.props,
      keyboard: "emailAddress",
    };
    (broken.elements.form!.children as string[]).push("ghost");
    const result = plain(bridge.validateSpec(broken));
    expect(result.valid).toBe(false);
    expect(result.issues.map((i) => [i.severity, i.path])).toEqual([
      ["error", "/elements/form"],
      ["error", "/elements/email/props/keyboard"],
    ]);
  });

  it("autoFixSpec() moves misplaced fields and prunes dangling children", () => {
    const spec = {
      root: "form",
      elements: {
        form: { type: "Form", props: {}, children: ["field", "ghost"] },
        field: {
          type: "TextField",
          props: {
            label: "Name",
            visible: { $state: "/show" },
            on: {
              submit: {
                action: "submit",
                params: { data: { $state: "/form" } },
              },
            },
          },
          children: [],
        },
      },
    };
    const fixed = plain(bridge.autoFixSpec(JSON.stringify(spec)));
    expect(fixed.elements.form!.children).toEqual(["field"]);
    expect(fixed.elements.field).toEqual({
      type: "TextField",
      props: { label: "Name" },
      visible: { $state: "/show" },
      on: {
        submit: { action: "submit", params: { data: { $state: "/form" } } },
      },
      children: [],
    });
    expect(plain(bridge.validateSpec(fixed)).valid).toBe(true);
  });

  it("stream compiler: chunks split mid-line produce the full spec", () => {
    const handle = bridge.createCompiler();
    expect(typeof handle).toBe("number");
    let patches = 0;
    let last: Spec | undefined;
    for (const piece of chunk(registrationJsonl, 37)) {
      const { spec, newPatches } = bridge.compilerPush(handle, piece);
      patches += newPatches.length;
      last = spec;
    }
    expect(last?.root).toBe("form");
    const final = plain(bridge.compilerFinish(handle));
    expect(final).toEqual(registration);
    expect(patches).toBe(registrationJsonl.trim().split("\n").length);
    expect(() => bridge.compilerPush(handle, "")).toThrow(
      /Unknown compiler handle/,
    );
  });

  it("stream compiler: starts from an initial spec and flushes the trailing line", () => {
    const handle = bridge.createCompiler(JSON.stringify(registration));
    const first = bridge.compilerPush(
      handle,
      '{"op":"replace","path":"/elements/form/props/title","value":"Sign Up"}\n{"op":"add","path":"/state/form/phone","va',
    );
    expect(plain(first.newPatches)).toEqual([
      { op: "replace", path: "/elements/form/props/title", value: "Sign Up" },
    ]);
    expect(first.spec.elements.form!.props.title).toBe("Sign Up");
    bridge.compilerPush(handle, 'lue":""}');
    const final = plain(bridge.compilerFinish(handle)) as Spec;
    expect(final.state).toEqual({
      form: { ...(registration.state!.form as object), phone: "" },
    });
    // The seed spec passed in is not mutated by the compiler.
    expect(registration.elements.form!.props.title).toBe("Create Account");
  });

  it("stream compiler: handles are independent", () => {
    const a = bridge.createCompiler();
    const b = bridge.createCompiler();
    expect(a).not.toBe(b);
    bridge.compilerPush(a, '{"op":"add","path":"/root","value":"a"}\n');
    bridge.compilerPush(b, '{"op":"add","path":"/root","value":"b"}\n');
    expect(bridge.compilerFinish(a).root).toBe("a");
    expect(bridge.compilerFinish(b).root).toBe("b");
  });

  it("invoke() wraps methods for string-only callers", () => {
    expect(JSON.parse(bridge.invoke("version"))).toEqual({
      result: bridge.version(),
    });
    expect(
      JSON.parse(bridge.invoke("validateSpec", JSON.stringify([registration]))),
    ).toEqual({
      result: { valid: true, issues: [] },
    });
    const handle = JSON.parse(bridge.invoke("createCompiler", "[]"))
      .result as number;
    const pushed = JSON.parse(
      bridge.invoke(
        "compilerPush",
        JSON.stringify([handle, '{"op":"add","path":"/root","value":"x"}\n']),
      ),
    );
    expect(pushed.result.spec.root).toBe("x");
    expect(
      JSON.parse(bridge.invoke("compilerFinish", JSON.stringify([handle])))
        .result.root,
    ).toBe("x");

    const unknown = JSON.parse(bridge.invoke("nope"));
    expect(unknown.error.message).toBe("Unknown bridge method: nope");
    const bad = JSON.parse(bridge.invoke("validateSpec", "{not json"));
    expect(typeof bad.error.message).toBe("string");
  });

  it("review reproduction: validateSpec returns issues instead of throwing", () => {
    const spec = (props: unknown = { label: "Name" }, extra: object = {}) => ({
      root: "a",
      elements: { a: { type: "TextField", props, children: [], ...extra } },
    });
    const run = (input: unknown) =>
      JSON.parse(bridge.invoke("validateSpec", JSON.stringify([input])));

    const malformedChildren = run(spec(undefined, { children: 7 }));
    expect(malformedChildren.error).toBeUndefined();
    expect(malformedChildren.result.valid).toBe(false);

    const malformedExpression = run(
      spec({ label: "Name", value: { $bindState: 42 } }),
    );
    expect(malformedExpression.result.valid).toBe(false);
    expect(malformedExpression.result.issues[0].code).toBe("expression");

    const ignoredSlots = run(
      spec(undefined, { slots: { default: ["missing"] } }),
    );
    expect(ignoredSlots.result).toEqual({ valid: true, issues: [] });

    const invalidWatch = run(
      spec(undefined, {
        watch: { "/form/a": { action: "setState", params: { value: 1 } } },
      }),
    );
    expect(invalidWatch.result.valid).toBe(false);
    expect(invalidWatch.result.issues[0].path).toBe(
      "/elements/a/watch/~1form~1a/params/statePath",
    );

    const autoFixed = JSON.parse(
      bridge.invoke(
        "autoFixSpec",
        JSON.stringify([spec("x", { children: 7, slots: { default: null } })]),
      ),
    );
    expect(autoFixed.error).toBeUndefined();
    expect(autoFixed.result.elements.a.props).toBe("x");
  });

  it("compilerDispose() frees a compiler without flushing", () => {
    const handle = bridge.createCompiler();
    bridge.compilerPush(
      handle,
      '{"op":"add","path":"/root","value":"x"}\n{"op":"add"',
    );
    expect(bridge.compilerDispose(handle)).toBeUndefined();
    expect(() => bridge.compilerFinish(handle)).toThrow(
      /Unknown compiler handle/,
    );
    expect(() => bridge.compilerDispose(handle)).not.toThrow();
    expect(() => bridge.compilerDispose(987654)).not.toThrow();
    expect(JSON.parse(bridge.invoke("compilerDispose", "[987654]"))).toEqual({
      result: null,
    });
  });

  describe("catalog option (PDF)", () => {
    const statement = readJSON<Spec>(
      join(repoDir, "fixtures/pdf/statement.json"),
    );
    const pdf = { catalog: "pdf" as const };

    it("systemPrompt() selects the catalog; default stays swiftui", () => {
      expect(bridge.systemPrompt(pdf)).toBe(pdfCatalog.prompt());
      expect(
        bridge.systemPrompt(
          JSON.stringify({ ...pdf, customRules: ["Use EUR."] }),
        ),
      ).toBe(pdfCatalog.prompt({ customRules: ["Use EUR."] }));
      expect(bridge.systemPrompt({ catalog: "swiftui" })).toBe(
        catalog.prompt(),
      );
      expect(bridge.systemPrompt({})).toBe(catalog.prompt());
    });

    it("catalogManifest()", () => {
      expect(plain(bridge.catalogManifest(pdf))).toEqual({
        components: pdfCatalog.componentNames,
        actions: [],
      });
      expect(plain(bridge.catalogManifest()).components).toEqual(
        catalog.componentNames,
      );
    });

    it("jsonSchema() declares state and repeat for PDF", () => {
      const schema = plain(bridge.jsonSchema(pdf)) as {
        properties: Record<
          string,
          { additionalProperties?: { properties?: object } }
        >;
      };
      expect(Object.keys(schema.properties)).toEqual([
        "root",
        "elements",
        "state",
      ]);
      expect(
        Object.keys(
          schema.properties.elements!.additionalProperties!.properties!,
        ),
      ).toEqual(["type", "props", "children", "visible", "repeat"]);
      expect(() => bridge.jsonSchema({ ...pdf, strict: true })).toThrow(
        /not supported/,
      );
    });

    it("validateSpec()", () => {
      expect(plain(bridge.validateSpec(statement, pdf))).toEqual({
        valid: true,
        issues: [],
      });
      expect(
        plain(
          bridge.validateSpec(JSON.stringify(statement), JSON.stringify(pdf)),
        ),
      ).toEqual({ valid: true, issues: [] });
      expect(plain(bridge.validateSpec(statement)).valid).toBe(false);
      const viaInvoke = JSON.parse(
        bridge.invoke("validateSpec", JSON.stringify([statement, pdf])),
      );
      expect(viaInvoke.result).toEqual({ valid: true, issues: [] });
    });

    it("autoFixSpec() keeps repeat for PDF and ignores it for forms", () => {
      const spec = {
        root: "doc",
        elements: {
          doc: { type: "Document", props: {}, children: ["list", "ghost"] },
          list: {
            type: "Column",
            props: { repeat: { statePath: "/xs" } },
            children: [],
          },
        },
      };
      const fixed = plain(bridge.autoFixSpec(spec, pdf));
      expect(fixed.elements.doc!.children).toEqual(["list"]);
      expect(fixed.elements.list).toEqual({
        type: "Column",
        props: {},
        children: [],
        repeat: { statePath: "/xs" },
      });
    });

    it("rejects unknown catalogs", () => {
      expect(() => bridge.systemPrompt({ catalog: "nope" as never })).toThrow(
        /Unknown catalog: nope/,
      );
      expect(
        JSON.parse(
          bridge.invoke(
            "validateSpec",
            JSON.stringify([statement, { catalog: "toString" }]),
          ),
        ).error.message,
      ).toMatch(/Unknown catalog/);
    });
  });
});

describe("installBridge()", () => {
  const test = { catalog: "test" };

  afterEach(() => {
    delete (globalThis as { JSONRenderBridge?: unknown }).JSONRenderBridge;
  });

  it("importing the module does not install the bridge", () => {
    expect(installedOnImport).toBe(false);
  });

  it("installs globalThis.JSONRenderBridge and returns it", () => {
    const api = installBridge();
    expect(
      (globalThis as { JSONRenderBridge?: unknown }).JSONRenderBridge,
    ).toBe(api);
    expect(api.systemPrompt()).toBe(catalog.prompt());
    expect(api.catalogManifest({ catalog: "pdf" }).components).toEqual(
      pdfCatalog.componentNames,
    );
  });

  it("selects a custom catalog in every catalog-aware method", () => {
    const api = installBridge({ catalogs: { test: testCatalog } });
    expect(api.systemPrompt(test)).toBe(testCatalog.prompt());
    expect(
      api.systemPrompt(JSON.stringify({ ...test, customRules: ["Be brief."] })),
    ).toBe(testCatalog.prompt({ customRules: ["Be brief."] }));
    expect(api.catalogManifest(test)).toEqual({
      components: ["Board", "Metric"],
      actions: ["refresh"],
    });
    expect(api.jsonSchema(test)).toEqual(testCatalog.jsonSchema());
    expect(api.validateSpec(testSpec, test)).toEqual({
      valid: true,
      issues: [],
    });
    // The built-ins are still there and still the default.
    expect(api.systemPrompt()).toBe(catalog.prompt());
    expect(api.validateSpec(testSpec).valid).toBe(false);
  });

  it("validateSpec() checks custom components, props, events and action params", () => {
    const api = installBridge({ catalogs: { test: testCatalog } });
    const broken = structuredClone(testSpec) as Spec;
    broken.elements.board!.props = { title: 7, color: "red" };
    broken.elements.visits!.on = {
      press: { action: "refresh", params: {} },
      hold: { action: "refresh", params: { source: "x" } },
    };
    broken.elements.extra = { type: "Gauge", props: {}, children: [] };
    const result = api.validateSpec(broken, JSON.stringify(test));
    expect(result.valid).toBe(false);
    expect(result.issues.map((i) => [i.severity, i.code, i.path])).toEqual([
      ["error", "schema", "/elements/extra/type"],
      ["error", "props", "/elements/board/props/title"],
      ["warning", "unknown_prop", "/elements/board/props/color"],
      ["error", "action_params", "/elements/visits/on/press/params/source"],
      ["warning", "unknown_event", "/elements/visits/on/hold"],
    ]);
  });

  it("autoFixSpec() uses the custom catalog's element fields", () => {
    const api = installBridge({ catalogs: { test: testCatalog } });
    const spec = {
      root: "board",
      elements: {
        board: {
          type: "Board",
          props: { title: "T", visible: true },
          children: ["ghost"],
          repeat: { statePath: "/xs" },
        },
      },
    };
    const fixed = api.autoFixSpec(spec, test);
    expect(fixed.elements.board).toEqual({
      type: "Board",
      props: { title: "T" },
      children: [],
      visible: true,
      // Not declared by the test schema: kept as-is, not moved or validated.
      repeat: { statePath: "/xs" },
    });
  });

  it("rejects a custom catalog named like a built-in", () => {
    for (const name of ["swiftui", "pdf"]) {
      expect(() =>
        installBridge({ catalogs: { [name]: testCatalog } }),
      ).toThrow(
        `Catalog name "${name}" is built in and cannot be replaced; choose another name (built-in catalogs: swiftui, pdf)`,
      );
    }
    expect("JSONRenderBridge" in globalThis).toBe(false);
  });

  it("rejects values that are not catalogs", () => {
    expect(() =>
      installBridge({ catalogs: { bad: {} as typeof testCatalog } }),
    ).toThrow('Catalog "bad" is not a catalog');
  });

  it("unknown catalog names list every available catalog", () => {
    const api = installBridge({ catalogs: { test: testCatalog } });
    expect(() => api.catalogManifest({ catalog: "nope" })).toThrow(
      "Unknown catalog: nope (expected swiftui | pdf | test)",
    );
    for (const name of ["toString", "__proto__", "constructor"]) {
      const viaInvoke = JSON.parse(
        api.invoke(
          "validateSpec",
          JSON.stringify([testSpec, { catalog: name }]),
        ),
      );
      expect(viaInvoke.error.message).toMatch(/^Unknown catalog: /);
    }
  });

  it("bridges keep separate compiler handles", () => {
    const a = installBridge();
    const b = installBridge({ catalogs: { test: testCatalog } });
    const first = a.createCompiler();
    const second = a.createCompiler();
    // b has created no compilers, so a's handles are unknown to it.
    for (const handle of [first, second]) {
      expect(() => b.compilerPush(handle, "")).toThrow(
        `Unknown compiler handle: ${handle}`,
      );
    }
    // b counts its own handles, so its first one has the same number as a's first.
    const other = b.createCompiler();
    expect(other).toBe(first);
    a.compilerPush(first, '{"op":"add","path":"/root","value":"a"}\n');
    b.compilerPush(other, '{"op":"add","path":"/root","value":"b"}\n');
    a.compilerPush(second, '{"op":"add","path":"/root","value":"c"}\n');
    expect(a.compilerFinish(first)).toEqual({ root: "a", elements: {} });
    expect(b.compilerFinish(other)).toEqual({ root: "b", elements: {} });
    expect(() => b.compilerFinish(second)).toThrow(/Unknown compiler handle/);
    expect(a.compilerFinish(second)).toEqual({ root: "c", elements: {} });
  });

  it("form-field checks belong to the pdf catalog, not to a FieldSet component", async () => {
    const fieldSet = {
      props: z.object({ name: z.string() }),
      events: [],
      description: "Groups fields.",
    };
    const withFieldSet = defineCatalog(testCatalog.schema, {
      components: { ...testCatalog.data.components, FieldSet: fieldSet },
      actions: testCatalog.data.actions,
    });
    const api = installBridge({ catalogs: { profile: withFieldSet } });
    const spec = {
      root: "address",
      elements: {
        address: {
          type: "FieldSet",
          props: { name: "profile.address" },
          children: [],
        },
      },
    };
    expect(api.validateSpec(spec, { catalog: "profile" })).toEqual({
      valid: true,
      issues: [],
    });

    // The same FieldSet in the pdf catalog is rejected, also through a separately loaded copy
    // of the catalog (as tsup's CommonJS entries each bundle their own). An app catalog built from the
    // PDF schema and components is not the pdf catalog, so it doesn't get the checks.
    const pdfSpec = {
      root: "doc",
      elements: {
        doc: { type: "Document", props: {}, children: ["page"] },
        page: { type: "Page", props: {}, children: ["address"] },
        address: spec.elements.address,
      },
    };
    const codes = (result: { issues: { code?: string }[] }) =>
      result.issues.map((i) => i.code);
    expect(codes(api.validateSpec(pdfSpec, { catalog: "pdf" }))).toContain(
      "invalid_field_name",
    );
    vi.resetModules();
    const { pdfCatalog: copy } = await import("../src/pdf");
    expect(copy === pdfCatalog).toBe(false);
    expect(codes(validateSpecForCatalog(copy, pdfSpec))).toContain(
      "invalid_field_name",
    );
    const lookalike = defineCatalog(pdfSchema, {
      components: pdfCatalog.data.components,
      actions: {},
    });
    expect(codes(validateSpecForCatalog(lookalike, pdfSpec))).not.toContain(
      "invalid_field_name",
    );
  });

  it("validates watch bindings for a catalog that declares watch but not on", () => {
    const watchSchema = defineSchema((s) => ({
      spec: s.object({
        root: s.string(),
        elements: s.record(
          s.object({
            type: s.ref("catalog.components"),
            props: s.propsOf("catalog.components"),
            children: s.array(s.string()),
            watch: { ...s.record(s.any()), ...s.optional() },
          }),
        ),
        state: { ...s.record(s.any()), ...s.optional() },
      }),
      catalog: s.object({
        components: s.map({ props: s.zod(), description: s.string() }),
        actions: s.map({ params: s.zod(), description: s.string() }),
      }),
    }));
    const watchCatalog = defineCatalog(watchSchema, {
      components: testCatalog.data.components,
      actions: testCatalog.data.actions,
    });
    const api = installBridge({ catalogs: { watch: watchCatalog } });
    const spec = (params: object) => ({
      root: "board",
      elements: {
        board: {
          type: "Board",
          props: { title: "T" },
          children: [],
          watch: { "/filter": { action: "refresh", params } },
          // Not declared by this schema: ignored, never validated.
          on: { press: { action: "refresh", params: {} } },
        },
      },
    });
    const result = api.validateSpec(spec({}), { catalog: "watch" });
    expect(result.valid).toBe(false);
    expect(result.issues.map((i) => [i.severity, i.code, i.path])).toEqual([
      [
        "error",
        "action_params",
        "/elements/board/watch/~1filter/params/source",
      ],
    ]);
    expect(
      api.validateSpec(spec({ source: "sales" }), { catalog: "watch" }),
    ).toEqual({ valid: true, issues: [] });
  });

  describe("app bundle with a custom catalog in a bare JS context", () => {
    let app: JSONRenderBridgeAPI;

    beforeAll(() => {
      const appContext = vm.createContext({});
      vm.runInContext(readText(testFixture), appContext, {
        filename: "test-catalog-bridge.js",
      });
      app = vm.runInContext(
        "globalThis.JSONRenderBridge",
        appContext,
      ) as JSONRenderBridgeAPI;
    });

    it("is the bundle built from test/fixtures/test-catalog-bridge.ts", () => {
      expect(readText(testFixture)).toBe(readText(testBundlePath));
    });

    it("serves the custom catalog and the built-ins", () => {
      expect(plain(app.catalogManifest(test))).toEqual({
        components: ["Board", "Metric"],
        actions: ["refresh"],
      });
      expect(app.systemPrompt(test)).toBe(testCatalog.prompt());
      expect(
        JSON.parse(
          app.invoke("validateSpec", JSON.stringify([testSpec, test])),
        ),
      ).toEqual({ result: { valid: true, issues: [] } });
      expect(app.systemPrompt()).toBe(catalog.prompt());
    });
  });
});
