import { existsSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";
import { beforeAll, describe, expect, it } from "vitest";
import type { Spec } from "@json-render/core";
import { catalog, pdfCatalog } from "../src/index";
import type { JSONRenderBridgeAPI } from "../src/bridge";
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
