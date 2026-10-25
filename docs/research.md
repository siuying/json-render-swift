# json-render research for a SwiftUI forms port

Source checkout studied: `/Volumes/External/Developer/json-render` (pnpm monorepo, inspected 2026-10-25). The report focuses on `packages/core`, `packages/react-native`, and the React Native, chat, and no-AI examples.

## 1. Spec format

Core's canonical v2 spec is a flat element map, not a recursive component tree. The public types live in `packages/core/src/types.ts` (`UIElement`, `FlatElement`, `Spec`). Each map key is the element identity. `root` points to one such key; `children` and each slot value contain keys, not inline nodes.

```json
{
  "root": "screen",
  "elements": {
    "screen": { "type": "Column", "props": { "gap": 12 }, "children": ["email", "submit"] },
    "email": { "type": "TextInput", "props": { "label": "Email", "value": { "$bindState": "/form/email" } }, "children": [] },
    "submit": { "type": "Button", "props": { "label": "Continue" }, "on": { "press": { "action": "setState", "params": { "statePath": "/submitted", "value": true } } }, "children": [] }
  },
  "state": { "form": { "email": "" }, "submitted": false }
}
```

An element's runtime shape is `{ type, props, children?, slots?, visible?, on?, repeat?, watch? }`. `props` are component-specific. `children` are ordered element keys. `slots` maps named slots to ordered key arrays. `visible` is a top-level condition. `on` maps event names to one action binding or an array of bindings. `repeat` is `{ statePath, key? }`; `statePath` is a JSON Pointer string or `{ "$item": "field" }` within a repeat scope. `watch` maps JSON Pointer paths to actions. Only `type` and `props` are required by the TypeScript `UIElement` interface; renderer package schemas may tighten this.

A second, human-friendly tree form is supported by `nestedToFlat()` in `packages/core/src/types.ts`. It accepts inline child objects, creates `el-0`, `el-1`, etc. keys, then returns the normal flat `{root,elements,state?}`. It hoists `state` from the root node. `FlatElement` is another interchange shape for arrays: it adds `key` and optional `parentKey` (null on root) so callers can rebuild the tree. Neither is the normal streamed output shape.

Exact nested example from the function's docstring, normalized:

```json
{"type":"Card","props":{"title":"Hello"},"children":[{"type":"Text","props":{"content":"World"}}],"state":{"count":0}}
```

`validateSpec()` in `packages/core/src/spec-validator.ts` checks root existence, dangling child/slot references, malformed `visible`, fields misplaced in props, repeat requirements and repeat path/sample-state validity. Orphan checks are optional. `autoFixSpec()` can relocate `visible`, `on`, `repeat`, and `watch` from props and optionally prune dangling references.

### Schema drift to account for

The current `packages/react-native/src/schema.ts` declares `root`, `elements`, and each element's `type`, `props`, required `children`, optional `visible`, and optional `repeat`. It does **not** declare `state`, `slots`, `on`, or `watch`, although the core `Spec` type and renderer support them and the prompt teaches `on` and `state`. Since catalog validation uses Zod `safeParse()`, whose ordinary object schemas strip unknown keys, validate/parse can discard those undeclared fields. The React schema should be inspected as another reference: its schema includes more of the runtime contract. For a SwiftUI catalog, explicitly align the schema with fields the Swift renderer will support and with the core prompt. Do not assume the RN Zod/catalog schema validates every runtime field today.

## 2. Catalog and schema API

`defineSchema(builder, options?)` in `packages/core/src/schema.ts` takes a builder callback over `s`. Builder methods are `string`, `number`, `boolean`, `array(type)`, `object(shape)`, `record(valueType)`, `any`, `zod`, `ref(path)`, `propsOf(path)`, `map(entryShape)`, and `optional()`. This is a small schema DSL, not Zod itself. At runtime it builds Zod validators and JSON Schema. Use `s.zod()` to say the catalog provides a Zod schema. `s.ref("catalog.components")` constrains element type to catalog keys; `s.propsOf("catalog.components")` expresses props from those component schemas, though validation falls back to a permissive record when there are multiple component prop schemas.

The schema declares both the spec grammar and catalog grammar. Then `defineCatalog(schema, data)` (shorthand for `schema.createCatalog(data)`) accepts concrete catalog entries. A component entry convention is `{ props: z.object(...), description, slots?, events?, example? }`; an action entry is `{ params: z.object(...), description }`. Core prompt code reads `description`, `slots`, `events`, Zod props, and examples. `example` helps produce prompt examples; if absent, core derives example props from the Zod schema. `Catalog` exposes `componentNames`, `actionNames`, `prompt(options)`, `jsonSchema({strict?})`, `validate(spec)`, and `zodSchema()`.

Minimal RN-style definition:

```ts
export const schema = defineSchema(s => ({
  spec: s.object({
    root: s.string(),
    elements: s.record(s.object({
      type: s.ref("catalog.components"),
      props: s.propsOf("catalog.components"),
      children: s.array(s.string()),
      visible: { ...s.any(), ...s.optional() },
      repeat: { ...s.any(), ...s.optional() },
    })),
  }),
  catalog: s.object({
    components: s.map({ props: s.zod(), slots: s.array(s.string()), description: s.string(), example: s.any() }),
    actions: s.map({ params: s.zod(), description: s.string() }),
  }),
}));
const catalog = defineCatalog(schema, { components: { ... }, actions: { ... } });
```

Actual source: `packages/react-native/src/schema.ts` and `packages/react-native/src/catalog.ts`. RN's `standardComponentDefinitions` uses Zod v4, carries descriptions/slot/event metadata, and provides reusable definitions. Layout components include `Container`, `Row`, `Column`, `ScrollContainer`, `SafeArea`, `Spacer`, `Pressable`, and `Divider`; content includes `Heading`, `Paragraph`, `Label`, `Image`, and others; form widgets include `TextInput`, `Switch`, `Checkbox`, `Slider`, and select/radio-like components. `TextInput` accepts nullable `placeholder`, `value`, `secureTextEntry`, `keyboardType`, `multiline`, `numberOfLines`, `label`, `flex`; its events are `submit`, `focus`, `blur`. It documents `$bindState` for two-way binding. `Switch`/`Checkbox` have nullable `checked`, `label`, `disabled` and a `change` event. `Pressable` has `press` and `longPress` and a default child slot.

RN's standard catalog component names, grouped as in `packages/react-native/src/catalog.ts`, are layout (`Container`, `Row`, `Column`, `ScrollContainer`, `SafeArea`, `Spacer`, `Pressable`, `Divider`), content (`Heading`, `Paragraph`, `Label`, `Image`, `Avatar`, `Badge`, `Chip`), inputs/actions (`Button`, `TextInput`, `Switch`, `Checkbox`, `Slider`, `SearchBar`), feedback (`Spinner`, `ProgressBar`), and composite (`Card`, `ListItem`, `Modal`). Each definition carries a Zod props schema and description, with optional `slots`, `events`, `example`. `standardActionDefinitions` include `navigate`, `goBack`, `showAlert`, `share`, `openURL`, `setState`, `pushState`, `removeState`, and `refresh`. `setState` params are `statePath` and `value`. `pushState` takes `statePath`, `value`, optional `clearStatePath`, and documents `{ "$state": "/path" }` references and `"$id"`. The example `examples/react-native/lib/render/catalog.ts` imports `schema` from `@json-render/react-native/schema`, definitions from `/catalog`, extends components with an `Icon`, and calls `defineCatalog(schema, { components, actions })`.

## 3. System prompt generation

Call `catalog.prompt(options)`; core implements it as `generatePrompt()` in `packages/core/src/schema.ts`. Options include `system`, `customRules`, `mode` (`standalone` default or `inline`; old `generate`/`chat` aliases), `editModes`, and `directives`. A schema can replace the generic prompt with `promptTemplate(context)` and can supply `defaultRules` and `builtInActions` through `defineSchema` options. Default rules are included before user `customRules`.

Standalone mode instructs the model to output **only JSONL RFC 6902 JSON Patch**, one JSON object per line. It says to start with `/root`, then interleave `/elements` and `/state` patches so UI can appear incrementally. Inline mode allows brief prose and encloses patch lines in a ` ```spec ` fence. It then generates examples from the actual catalog, lists component props/descriptions/slots/events and available actions, and documents dynamic state, repeats, actions, events, visibility and state pointer syntax. Core asks for RFC 6902 operations but specifically describes add/remove/replace in the main instruction; the patch compiler supports all six standard ops.

Prompt excerpt (with component names representative of RN):

```text
You are a UI generator that outputs JSON.

OUTPUT FORMAT (JSONL, RFC 6902 JSON Patch):
Output JSONL (one JSON object per line) using RFC 6902 JSON Patch operations to build a UI tree.
Each line is a JSON patch operation (add, remove, replace). Start with /root, then stream /elements and /state patches interleaved so the UI fills in progressively as it streams.

Example output (each line is a separate JSON object):
{"op":"add","path":"/root","value":"main"}
{"op":"add","path":"/elements/main","value":{"type":"Container", ...}}
...
```

Exact example entries depend on catalog order and schema definition. In `inline` mode there is a ` ```spec ` fence instruction. For edits, `buildUserPrompt()` in `packages/core/src/prompt.ts` calls edit-mode instructions and includes current spec and optional state context. Fresh generation prompt appends a reminder to output root first, then interleave elements/state.

## 4. Streaming

The transport format is JSONL, with one RFC 6902 patch per line, not RFC 6902 as one JSON array. A stream starts from an empty or seeded partial object, commonly `{}`; first patches add `/root`, then `/elements/<key>`, `/state/...`. Example:

```text
{"op":"add","path":"/root","value":"main"}
{"op":"add","path":"/elements/main","value":{"type":"Column","props":{},"children":["name"]}}
{"op":"add","path":"/elements/name","value":{"type":"TextInput","props":{"value":{"$bindState":"/form/name"}},"children":[]}}
{"op":"add","path":"/state/form","value":{"name":""}}
```

`createSpecStreamCompiler<T>(initial?)` buffers arbitrary text chunks until newline, parses each complete JSON line with `parseSpecStreamLine`, mutates the result via `applySpecStreamPatch`, returns `{ result, newPatches }`, and flushes a trailing final line through `getResult()`. `compileSpecStream(text, initial?)` handles a completed string. `applySpecStreamPatch` supports add/remove/replace/move/copy/test, using JSON Pointer helpers. `createMixedStreamParser()` additionally splits ordinary prose and patch lines; `createJsonRenderTransform()` / `pipeJsonRender()` classify AI SDK UI stream chunks into text and `data-spec` patch parts. Fenced `spec` blocks are recognized in mixed/AI SDK parsing. See `packages/core/src/types.ts` and `packages/react-native/src/hooks.ts` (`useUIStream`).

## 5. Data binding and dynamic expressions

The state model is a nested JSON object, normally seeded by `spec.state`. State paths use RFC 6901 JSON Pointer syntax (`/form/email`, `/todos/0/title`), not dot notation. `getByPath`, `setByPath`, `addByPath`, `removeByPath`, `resolveDynamicValue`, and `createStateStore` are core utilities. `StateStore` has `get(path)`, `set(path,value)`, `update(map)`, `getSnapshot()`, and `subscribe(listener)`; the built-in store is framework-free.

`{ "$state": "/path" }` reads a state value. `{ "$bindState": "/path" }` reads the same value but `resolveBindings()` also gives the renderer the writeback path. In a repeat, `{ "$item": "field" }` reads item data, `{ "$index": true }` gives the numeric index, and `{ "$bindItem": "field" }` resolves to a writable absolute path. The renderer resolves prop expressions through `resolveElementProps()` and binding paths through `resolveBindings()` in `packages/core/src/props.ts`; RN components use `useBoundProp()` to subscribe/read and write via the state provider. For example RN `TextInput` maps `value` to `$bindState` and uses `onChangeText` to update that bound path.

Other expressions: `$cond` with `$then`/`$else` selects dynamically, `$template` interpolates `${/absolute/path}` and `${bareField}` (bare field checks current repeat item then `/field` in global state), `$computed` invokes a host-registered function, and registered custom directives can add `$...` expressions. `$state` and `$cond` also work recursively in props and action/validation args. Core resolves values; renderer subscribes and causes view updates.

## 6. Actions

An action declaration in catalog is a Zod `params` schema plus human description. An element references it at top-level: `on: { "press": { "action": "submit", "params": { ... } } }`. A binding can also include `confirm`, `onSuccess`, `onError`, and `preventDefault`. Params are recursively resolved. `$state` means read the current value; `$item` in action params is special and resolves to an absolute state path, while `$index` resolves to an index. Bindings can be arrays, executed in order. Core functions are `resolveAction()` and `executeAction()` in `packages/core/src/actions.ts`; UI renderer catches the event, resolves binding, then dispatches to a host handler.

React Native `ActionProvider` handles `setState`, `pushState`, `removeState` itself; custom action handlers receive `(params, setState, state)` through `defineRegistry`/provider. `createStandardActionHandlers()` adds platform handlers for alert/share/openURL/navigation/etc. `builtInActions` on a schema are prompt-only, runtime-handled actions with no catalog handler needed. Current RN uses catalog action declarations for state actions. Note: `standardActionDefinitions` does not itself define `pop`/`push` navigation actions suggested by some RN default prompt examples; check runtime/catalog parity before relying on those examples.

## 7. Validation

Core declares `ValidationCheck` as `{ type, args?, message }` and `ValidationConfig` as `{ checks?, validateOn?: "change"|"blur"|"submit", enabled?: VisibilityCondition }` in `packages/core/src/validation.ts`. Built-ins include `required`, `email`, `minLength`, `maxLength`, `pattern`, numeric min/max, `matches`, and more; see `builtInValidationFunctions`. Custom functions can be passed by host. `runValidation(config, {value,stateModel,customFunctions})` evaluates `enabled`, resolves check args through prop-expression resolution, then runs each check and returns `{ valid, errors, checks }`. Unknown validator names warn and pass, so native should validate the catalog if strictness is desired. `check.required(...)`, `check.email(...)`, etc. are convenience constructors.

Core does not decide when UI validation runs. React/React Native `ValidationProvider` tracks per-path `touched`, `validated`, and results, registers configs, validates a field or all fields, and exposes field state. React form integrations call validation on change/blur according to `validateOn`; `validateAll()` supports submit. The no-AI example (`examples/no-ai/lib/examples.ts`, Registration Form) shows `checks` and `validateOn` nested in field component props, `$bindState`, a cross-field `matches` check, conditionally visible company field, and `validateForm` submit action. This is an app/runtime convention, not currently part of RN `TextInput` Zod props or `standardActionDefinitions`. The RN standard catalog's `TextInput` has no validation fields, and its standard actions have no `validateForm`; the RN `ValidationProvider` context exists but `packages/react-native/src/components/standard.tsx` does not wire its stock inputs into it. React form examples/tests are the clearest behavior reference.

## 8. Visibility

Visibility is an element-level condition, not a prop. Accepted values: booleans; a single `{ "$state": path, eq|neq|gt|gte|lt|lte|not? }`; item/index variants inside repeats; arrays mean implicit AND; `{ "$and": [...] }` and `{ "$or": [...] }` support nesting. Example:

```json
{"visible":{"$state":"/form/accountType","eq":"business"}}
```

Core `evaluateVisibility()` in `packages/core/src/visibility.ts` evaluates the condition against state and repeat context. RN's `VisibilityProvider` wraps it and subscribes to state via `useStateStore`. `validateSpec()` flags invalid condition shapes, and it warns if `visible` appears under `props`.

## 9. Core bundling and JavaScriptCore

`@json-render/core` has no React or DOM dependency. The package's runtime dependency is Zod (`^4.3.6`; also a peer `zod: ^4.0.0`). It is TypeScript/JavaScript and builds CJS and ESM. Main reusable exports from `packages/core/src/index.ts` for an iOS bridge:

- Schema/catalog/prompt: `defineSchema`, `defineCatalog`, catalog `prompt()`, `jsonSchema()`, `validate()`.
- Spec streaming: `parseSpecStreamLine`, `applySpecStreamPatch`, `applySpecPatch`, `compileSpecStream`, `createSpecStreamCompiler`, `createMixedStreamParser`, `createJsonRenderTransform`, `pipeJsonRender`.
- State/expressions: `createStateStore`, `getByPath`, `setByPath`, `resolveDynamicValue`, `resolvePropValue`, `resolveElementProps`, `resolveBindings`, `resolveActionParam`.
- Runtime behavior: `evaluateVisibility`, `validateSpec`, `autoFixSpec`, `runValidation`, `runValidationCheck`, `builtInValidationFunctions`, `resolveAction`, `executeAction`, `buildUserPrompt`, `diffToPatches`, `deepMergeSpec`.

For JavaScriptCore, make a narrow bridge entry file instead of bundling the full `index.ts`; core index also exports experimental composition/evaluator code and a stream transform irrelevant to form rendering. `createJsonRenderTransform` needs Web Streams globals (`TransformStream`, controller types); `experimental_createEvaluator` calls `fetch`; experimental composition calls `structuredClone`; several dev warnings read `process.env.NODE_ENV`. `structuredClone` and `fetch` are isolated to experimental paths; core state, prompt, schema, props, actions, validation, visibility, JSONL patch compiler do not need DOM or network. No core `TextEncoder` use found. Zod needs to be included or supplied to the JS context; schema and prompt generation depend on its runtime API and JSON Schema conversion. Test Zod v4 under the JSC version in the iOS deployment target, and shim/replace `process.env.NODE_ENV` during bundling. Avoid exporting transform/evaluator APIs from the IIFE if they are not used. A narrow esbuild IIFE can expose plain JSON-in/JSON-out methods, but passing Zod schema instances back and forth across Swift is not useful; define catalog and schema in the bundle, expose generated prompt/schema/validation and pure runtime operations.

## 10. Examples and demo flow

Best direct generation reference is `examples/react-native`, because it already has a native prompt bar, an Expo API route, `useUIStream`, streamed spec rendering, and JSON/JSONL inspection. Its `app/api/generate+api.ts` builds `SYSTEM_PROMPT = catalog.prompt({ customRules })`, turns user input into a message with `buildUserPrompt({ prompt, currentSpec, state, maxPromptLength })`, calls AI SDK `streamText` using AI Gateway (default `anthropic/claude-haiku-4.5`), returns a text-stream response. `app/index.tsx` calls `useUIStream({ api, fetch, validate: true })`, sends prompt plus previous spec, and renders partial specs via `AppRenderer`. The app has UI/JSON/JSONL views, copy, clear, stop, error/loading state, and a keyboard-aware floating prompt bar. `AppRenderer` seeds state from initial spec only when root changes and wraps `Renderer` in State, Visibility, Action, and Validation providers.

`examples/chat` is the strongest reference for a conversational app. `app/api/generate/route.ts` rate-limits, converts AI SDK messages, streams an agent result, then passes it through `pipeJsonRender` so ordinary assistant prose and fenced spec patches become text/data parts. `lib/agent.ts` uses a `ToolLoopAgent`, catalog and tool definitions, and instructs the model to fetch data before writing a ` ```spec ` block. Its UI supports rich chat with visual specs. This is more complex than a forms-only prototype.

`examples/no-ai` demonstrates renderer behavior and authored fixtures rather than prompt generation. It has example selection and a Registration Form that demonstrates field binding, validation, cross-field checks, conditional fields, live `$template` output, and submit validation. It is the best validation UX reference. A SwiftUI forms demo can borrow the React Native prompt/stream inspection UX, plus the no-AI form fixture's field errors and registration interaction.

## 11. Build, versions, and external dependency use

Monorepo root: `pnpm@11.1.3`, Node `>=24`, TypeScript root dev dependency `5.9.2`, Turbo `^2.9.7`. Packages use tsup `^8.0.2`. `@json-render/core` and `@json-render/react-native` are both version `0.21.3`, marked public via `publishConfig.access: public`, with `dist` entry points, CJS/ESM and declaration exports. Core tsup entries are `src/index.ts` and `src/store-utils.ts`, externalizing `zod`. RN entries are index/schema/catalog; externalizes React, React Native, core, Zod. `@json-render/react-native` has core as a package dependency and React/React Native/Zod peers.

README install examples use published package names, e.g. `npm install @json-render/core @json-render/react-native`; in this checkout example apps use `workspace:*` because they live inside the pnpm workspace. An external prototype can use published versions with matching package versions, or consume a local package path/workspace during development. For a Swift package, the TypeScript catalog package could depend on `@json-render/core` and ship compiled JS/schema alongside TS typings. No existing Swift or JSCore package is present.

## Source map

- Core contracts and helpers: `packages/core/src/types.ts`, `schema.ts`, `prompt.ts`, `props.ts`, `actions.ts`, `validation.ts`, `visibility.ts`, `state-store.ts`, `spec-validator.ts`, `index.ts`, `package.json`, `tsup.config.ts`.
- RN schema and reusable catalog: `packages/react-native/src/schema.ts`, `catalog.ts`, `renderer.tsx`, `contexts/{state,actions,validation,visibility}.tsx`, `components/standard.tsx`, `hooks.ts`, `package.json`, `tsup.config.ts`.
- Generated native demo: `examples/react-native/app/index.tsx`, `app/api/generate+api.ts`, `lib/render/{catalog,renderer}.tsx`.
- Conversational demo: `examples/chat/app/api/generate/route.ts`, `lib/agent.ts`, `lib/render/catalog.ts`.
- Form fixture: `examples/no-ai/app/page.tsx`, `lib/examples.ts` (Registration Form).

Repository guidance checked: root `AGENTS.md`, `skills/core/SKILL.md`, and `skills/react-native/SKILL.md`. The skills describe core prompt/JSONL and binding APIs and RN standard components/providers. Their examples are useful but not a guarantee of current implementation parity, as the schema and validation gaps above show. Root `AGENTS.md` requires checking latest package versions before dependency changes, version sync across public packages, and type checking after changes; it also identifies the docs location and publishing workflow. No source checkout files were changed for this research.
