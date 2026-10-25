/**
 * The JavaScriptCore bridge API (`globalThis.JSONRenderBridge`). `installBridge()` builds it over
 * the built-in catalogs plus any the app passes, and installs it. Importing this module has no
 * side effects: the shipped bundle's entry is src/bridge-entry.ts, and an app bundle with its own
 * catalogs imports `installBridge` from `@json-render/swift/bridge`.
 *
 * Conventions (see docs/ARCHITECTURE.md "JS bridge API"):
 * - Object arguments may be passed either as JS values or as JSON strings.
 *   (`compilerPush`'s chunk is raw stream text, never parsed.)
 * - Return values are plain JSON-serialisable JS values.
 * - `invoke(method, argsJSON)` wraps any method for string-only callers:
 *   it takes a JSON array of arguments and returns a JSON string
 *   `{"result": <value>}` or `{"error": {"message": "...", "stack": "..."}}`.
 *
 * Must run in a bare JSContext: no fetch, structuredClone, TextEncoder, setTimeout.
 * `console` is optional (stubbed by the bundle banner when missing).
 */
import {
  buildUserPrompt as coreBuildUserPrompt,
  createSpecStreamCompiler,
} from "@json-render/core";
import type {
  JsonPatch,
  Catalog as CoreCatalog,
  PromptOptions,
  Spec,
  SpecStreamCompiler,
} from "@json-render/core";
import { catalog, pdfCatalog } from "./index";
import { autoFixSpecForCatalog, validateSpecForCatalog } from "./validate";
import type { SwiftUISpecValidation, ValidateSpecOptions } from "./validate";

declare const __BRIDGE_VERSION__: string | undefined;

const VERSION =
  typeof __BRIDGE_VERSION__ === "string" ? __BRIDGE_VERSION__ : "0.0.0-dev";

function parseArg<T>(value: unknown): T {
  return (typeof value === "string" ? JSON.parse(value) : value) as T;
}

function emptySpec(): Spec {
  return { root: "", elements: {} };
}

/** Plain-JSON copy (drops `undefined`, detaches from compiler-owned objects). */
function toJSON<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

/**
 * A catalog built with `defineCatalog` from `@json-render/core`. Element-based catalogs
 * (`{ root, elements, state? }` specs) work with every catalog-aware bridge method.
 */
export type Catalog = CoreCatalog<any, any>;

/** Catalogs every bridge has: "swiftui" (forms, the default) and "pdf" (documents). */
export type BuiltInCatalogName = "swiftui" | "pdf";

/** A built-in catalog name or one passed to `installBridge({ catalogs })`. */
export type CatalogName = BuiltInCatalogName | (string & {});

export interface CatalogOptions {
  catalog?: CatalogName;
}

export interface InstallBridgeOptions {
  /** Extra catalogs by name, selectable with the `catalog` option. Names must not be built in. */
  catalogs?: Record<string, Catalog>;
}

function isCatalog(value: unknown): value is Catalog {
  const candidate = value as Partial<Catalog> | null;
  return (
    typeof candidate === "object" &&
    candidate !== null &&
    typeof candidate.prompt === "function" &&
    typeof candidate.validate === "function" &&
    typeof candidate.jsonSchema === "function" &&
    Array.isArray(candidate.componentNames) &&
    Array.isArray(candidate.actionNames)
  );
}

/** Built-ins first, then the app's catalogs in insertion order. */
function registerCatalogs(
  extra: Record<string, Catalog> | undefined,
): Map<string, Catalog> {
  const catalogs = new Map<string, Catalog>([
    ["swiftui", catalog],
    ["pdf", pdfCatalog],
  ]);
  const builtIns = [...catalogs.keys()];
  for (const [name, value] of Object.entries(extra ?? {})) {
    if (builtIns.includes(name)) {
      throw new Error(
        `Catalog name "${name}" is built in and cannot be replaced; choose another name (built-in catalogs: ${builtIns.join(", ")})`,
      );
    }
    if (!isCatalog(value)) {
      throw new Error(
        `Catalog "${name}" is not a catalog; create it with defineCatalog from @json-render/core`,
      );
    }
    catalogs.set(name, value);
  }
  return catalogs;
}

function catalogSelector(
  catalogs: Map<string, Catalog>,
): (options: unknown) => Catalog {
  return (options) => {
    const name =
      (parseArg<CatalogOptions | null | undefined>(options) ?? {}).catalog ??
      "swiftui";
    const selected = typeof name === "string" ? catalogs.get(name) : undefined;
    if (!selected) {
      throw new Error(
        `Unknown catalog: ${String(name)} (expected ${[...catalogs.keys()].join(" | ")})`,
      );
    }
    return selected;
  };
}

export interface SystemPromptOptions extends CatalogOptions {
  customRules?: string[];
  mode?: "standalone" | "inline";
}

export interface UserPromptInput {
  prompt: string;
  currentSpec?: Spec | null;
  state?: Record<string, unknown> | null;
  maxPromptLength?: number;
}

function createBridge(catalogs: Map<string, Catalog>) {
  const selectCatalog = catalogSelector(catalogs);
  const compilers = new Map<number, SpecStreamCompiler<Spec>>();
  let nextHandle = 1;

  function getCompiler(handle: number): SpecStreamCompiler<Spec> {
    const compiler = compilers.get(handle);
    if (!compiler) throw new Error(`Unknown compiler handle: ${handle}`);
    return compiler;
  }

  const bridge = {
    version(): string {
      return VERSION;
    },

    systemPrompt(options?: SystemPromptOptions | string | null): string {
      const opts =
        parseArg<SystemPromptOptions | null | undefined>(options) ?? {};
      const promptOptions: PromptOptions = {};
      if (opts.customRules) promptOptions.customRules = opts.customRules;
      if (opts.mode) promptOptions.mode = opts.mode;
      return selectCatalog(opts).prompt(promptOptions);
    },

    buildUserPrompt(input: UserPromptInput | string): string {
      const { prompt, currentSpec, state, maxPromptLength } =
        parseArg<UserPromptInput>(input);
      return coreBuildUserPrompt({
        prompt,
        currentSpec,
        state,
        maxPromptLength,
      });
    },

    catalogManifest(options?: CatalogOptions | string | null): {
      components: string[];
      actions: string[];
    } {
      const selected = selectCatalog(options);
      return {
        components: [...selected.componentNames],
        actions: [...selected.actionNames],
      };
    },

    /**
     * JSON Schema of the spec (root, elements map, state; per-component props are described
     * by the system prompt and checked by validateSpec, not by this schema).
     *
     * `strict: true` is rejected: LLM structured-output schemas (e.g. OpenAI strict mode)
     * require every object to list fixed keys with `additionalProperties: false`, but a spec's
     * `elements` and `state` are maps keyed by LLM-chosen names. core's strict conversion
     * turns them into empty closed objects, which would force the model to emit
     * `"elements": {}`. Generate with the system prompt + JSONL patch stream instead.
     */
    jsonSchema(
      options?: ({ strict?: boolean } & CatalogOptions) | string | null,
    ): object {
      const { strict } = parseArg<{ strict?: boolean } | null>(options) ?? {};
      if (strict) {
        throw new Error(
          "jsonSchema({ strict: true }) is not supported: json-render specs key elements and state by dynamic names, which strict structured-output schemas cannot express (they would only allow an empty elements map). Use systemPrompt() with the JSONL patch stream, or jsonSchema() without strict for validation.",
        );
      }
      return selectCatalog(options).jsonSchema();
    },

    validateSpec(
      spec: unknown,
      options?: (CatalogOptions & ValidateSpecOptions) | string | null,
    ): SwiftUISpecValidation {
      const { hostValidators, hostActions } =
        parseArg<ValidateSpecOptions | null>(options) ?? {};
      return toJSON(
        validateSpecForCatalog(selectCatalog(options), parseArg(spec), {
          hostValidators: Array.isArray(hostValidators)
            ? hostValidators
            : undefined,
          hostActions: Array.isArray(hostActions) ? hostActions : undefined,
        }),
      );
    },

    autoFixSpec(
      spec: Spec | string,
      options?: CatalogOptions | string | null,
    ): Spec {
      return toJSON(
        autoFixSpecForCatalog(selectCatalog(options), parseArg(spec)) as Spec,
      );
    },

    createCompiler(initial?: Spec | string | null): number {
      const seed = parseArg<Spec | null | undefined>(initial) ?? emptySpec();
      const handle = nextHandle++;
      compilers.set(handle, createSpecStreamCompiler<Spec>(toJSON(seed)));
      return handle;
    },

    compilerPush(
      handle: number,
      chunk: string,
    ): { spec: Spec; newPatches: JsonPatch[] } {
      const { result, newPatches } = getCompiler(handle).push(String(chunk));
      return { spec: toJSON(result), newPatches: toJSON(newPatches) };
    },

    compilerFinish(handle: number): Spec {
      const compiler = getCompiler(handle);
      compilers.delete(handle);
      return toJSON(compiler.getResult());
    },

    /** Free an abandoned compiler without flushing. No-op for unknown handles. */
    compilerDispose(handle: number): void {
      compilers.delete(handle);
    },

    invoke(method: string, argsJSON?: string | null): string {
      try {
        const fn = (bridge as Record<string, unknown>)[method];
        if (typeof fn !== "function" || method === "invoke") {
          throw new Error(`Unknown bridge method: ${method}`);
        }
        const args = argsJSON ? (JSON.parse(argsJSON) as unknown[]) : [];
        const result: unknown = fn(...(Array.isArray(args) ? args : [args]));
        return JSON.stringify({ result: result === undefined ? null : result });
      } catch (error) {
        const err = error as { message?: unknown; stack?: unknown } | null;
        return JSON.stringify({
          error: {
            message: String(err?.message ?? error),
            stack: typeof err?.stack === "string" ? err.stack : undefined,
          },
        });
      }
    },
  };

  return bridge;
}

export type JSONRenderBridgeAPI = ReturnType<typeof createBridge>;

/**
 * Builds the bridge API over the built-in catalogs ("swiftui", "pdf") plus `options.catalogs`,
 * installs it as `globalThis.JSONRenderBridge` (replacing any previous one) and returns it.
 * Throws if a custom catalog name is built in or a value is not a catalog.
 *
 * ```ts
 * import { installBridge } from "@json-render/swift/bridge";
 * installBridge({ catalogs: { database: databaseCatalog } });
 * ```
 */
export function installBridge(
  options: InstallBridgeOptions = {},
): JSONRenderBridgeAPI {
  const bridge = createBridge(registerCatalogs(options.catalogs));
  (globalThis as { JSONRenderBridge?: JSONRenderBridgeAPI }).JSONRenderBridge =
    bridge;
  return bridge;
}
