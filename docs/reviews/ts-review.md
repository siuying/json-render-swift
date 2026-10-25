# TypeScript review

Reviewed 2026-10-25 against `docs/ARCHITECTURE.md`, `docs/research.md`, the read-only upstream core source, and installed `@json-render/core@0.21.3`. Scope covers the workspace configuration, `packages/swiftui`, fixtures, and sample system prompt. Swift and iOS implementation files were not reviewed or edited.

Six verified findings: one high, three medium, two low. No source changes were made. Running the requested build regenerated its bundled resource output.

## Findings

### 1. High: malformed element fields throw before schema validation can report issues

Location: `packages/swiftui/src/validate.ts:137`.

The guard at line 122 only checks that each element is an object. Core's structural validator then assumes field types are already valid, but `catalog.validate` runs afterward. For an otherwise ordinary Form element, `children: 7` throws `TypeError: u.children is not iterable`; `props: "x"` throws on the `in` operator. Both were reproduced through the built IIFE. Through `invoke`, callers receive `{error: ...}` instead of the contracted `{result: {valid: false, issues: [...]}}`. Invalid LLM output therefore bypasses the normal validation and repair result.

Suggested fix: validate the structural grammar before calling core and return schema issues if it fails. Pass only safely typed element fields into the structural validator. Add cases for primitive props and non-array children. Handle ignored `repeat` and `slots` as described in finding 3 rather than passing their unchecked values to core.

### 2. Medium: expression detection suppresses errors for objects that are not valid expressions

Location: `packages/swiftui/src/validate.ts:43` and `packages/swiftui/src/validate.ts:78`.

Any object containing a recognized dollar key suppresses Zod issues at or below that object, regardless of the key's value or the expression's required fields. A TextField with `value: {"$bindState": 42}` passes with no issues. Core resolves that value to the unchanged object, not a string or a binding. An incomplete `{"$cond": true, "$then": "x"}` also passes even though core treats it as a plain object. More broadly, `props: {"$state": 42}` suppresses the missing required `label` error and leaves only an unknown-prop warning.

Failure scenario: a malformed binding or conditional from the LLM is declared valid but cannot supply the catalog's typed value. Missing mandatory props can also escape validation entirely.

Suggested fix: recognize and validate supported expression shapes, including string paths and both conditional branches. Permit expressions in individual prop values and action/check arguments, without interpreting the whole props or params container as an expression. Return errors for malformed expression objects instead of using the presence of a dollar key as a validation exemption. Add the examples above as regression cases while retaining tests for valid dynamic values.

### 3. Medium: validation rejects fields the contract says to ignore

Location: `packages/swiftui/src/validate.ts:137`.

The architecture explicitly says `repeat` and `slots` are out of scope and should be parsed and ignored gracefully. The schema omits them, but core validation receives the original input and enforces their semantics anyway. A Form with a valid Text child and `repeat: {"statePath": "/absent"}`, plus `state: {}`, returns a `repeat_state_mismatch` error. A valid leaf with `slots: {"default": ["missing"]}` returns `missing_child`, although the native v1 renderer is meant to ignore those slots. `repeat: null` and `slots: {"default": null}` additionally throw.

Suggested fix: construct a view of the spec without these ignored fields before structural validation. Keep supported fields such as `on`, `watch`, `visible`, and `state`. Add contract tests proving that ignored fields neither introduce validation failures nor throw. Consider the same normalization for `autoFixSpec`, whose core implementation also processes slots and repeats.

### 4. Medium: watch actions bypass action binding and parameter validation

Location: `packages/swiftui/src/validate.ts:194`.

Only `element.on` is checked for binding shape, action names, and required action params. The declared and preserved `watch` field is a record of arbitrary values and receives none of those checks. Reproduced with `watch: {"/form/a": {"action": "setState", "params": {"value": 1}}}` on a TextField: validation returns `{valid: true, issues: []}`. The identical action under `on.change` correctly returns an error for missing `statePath`.

Failure scenario: a spec passes validation, but changing the watched state dispatches an invalid built-in action. Unknown watch actions also omit the warning that would tell a host it needs to register a handler.

Suggested fix: share binding validation between `on` and `watch`, including single bindings, arrays, custom-action warnings, and catalog parameter checks. Preserve the distinct paths in reported issues. Add paired on/watch tests for malformed bindings and missing params.

### 5. Low: nested undefined results are lost in expression parity expectations

Location: `packages/swiftui/scripts/gen-parity-fixtures.ts:309` and `packages/swiftui/scripts/gen-parity-fixtures.ts:336`.

The generator flags a top-level undefined result, but JSON serialization erases nested undefined values. In the existing `array elements are resolved` case at line 217, core returns `["Ada", "x", undefined]`; the committed expected value is `["Ada", "x", null]`. In the recursive-object case, core returns an own `missing` property with an undefined value, while the fixture omits that property. These conversions are documented, but the fixtures cannot detect a native resolver that incorrectly substitutes null inside arrays or drops undefined object members during resolution.

This is a parity coverage limitation, not an incorrectly calculated JSON snapshot. Undefined and null differ in core equality and visibility semantics, so the distinction should survive semantic parity checks even if a final JSON serialization intentionally normalizes it.

Suggested fix: retain the JSON snapshot and add recursive metadata such as `undefinedPaths`, or encode undefined with a tagged value understood by the fixture consumer. Alternatively, add behavioral cases that exercise the missing/null distinction before serialization. Apply the encoding consistently to both expression functions.

### 6. Low: the prompt advertises validateOn on inputs whose catalog omits it

Location: `docs/system-prompt.sample.txt:48`, generated by `packages/swiftui/src/schema.ts:240`.

The general validation paragraph says inputs accept `validateOn`, but Stepper and Slider omit it from their schemas, consistent with the architecture table. A Stepper with `validateOn: "change"` passes validation with an `unknown_prop` warning saying the prop will be ignored. An LLM following this paragraph can therefore request validation timing that the catalog does not support.

Suggested fix: qualify the prompt so `validateOn` applies only to components that list it, and explicitly describe Stepper/Slider as using submit validation. Regenerate the sample. Add a prompt assertion for that qualification.

## Verification and coverage

- `pnpm install && pnpm -r build && pnpm -r test` passed with Node 24.16.0 and pnpm 11.5.0: four test files, 46 tests.
- `pnpm -r check-types` passed.
- A separate temporary copy with no `node_modules` or `dist` passed `pnpm install --frozen-lockfile && pnpm -r build && pnpm -r test`. Its bridge bundle was byte-identical to the workspace build, SHA-256 `9f806636ddc46aaa4e6952e47820d669247b50c17485255c72afcd61b0d0d4c2`.
- The existing bare `node:vm` bridge suite passed. An additional Apple JavaScriptCore smoke test, run with `xcrun swift` and `JSContext`, loaded the IIFE and called version, system prompt, JSON schema, and compiler creation/finish without host shims. The context had no fetch, structuredClone, or URL. No JSC incompatibility was found in the exercised API paths.
- Independently recomputed all committed parity expectations against installed core: 58 expression cases, 56 visibility cases, and 94 validation cases. All 208 matched after the generator's documented JSON normalization. Finding 5 describes the information that normalization loses.
- Verified compiler handles become unknown after finish, including when flushing a trailing failing `test` patch throws. A failing push can still be cleaned up with finish. No handle-release defect was found in those paths; callers still need to finish cancelled streams.
- Existing tests cover normal streaming splits, seed isolation, prompt/sample synchronization, and preservation of supported runtime fields in the sample specs. They do not cover the malformed field shapes, expression shapes, ignored-field behavior, or watch actions described above.

The system prompt provides concrete state seeding, binding, submit, and visibility guidance, and its complete JSONL example compiles and validates. Aside from finding 6, no verified contradiction was found in those instructions. The supported `state`, `on`, `visible`, and `watch` fields are declared in the schema; the field-stripping issue noted in the upstream RN research is not reproduced here.

## Minimal bridge reproduction

Run from the repository root after building. This uses the built IIFE in a bare VM and does not edit files.

```sh
node --input-type=module <<'JS'
import fs from 'node:fs';
import vm from 'node:vm';
const context = vm.createContext({});
vm.runInContext(
  fs.readFileSync('packages/swiftui/dist/json-render-bridge.js', 'utf8'),
  context,
);
const bridge = context.JSONRenderBridge;
const spec = (props = { label: 'Name' }, extra = {}) => ({
  root: 'a',
  elements: {
    a: { type: 'TextField', props, children: [], ...extra },
  },
});
for (const [name, input] of Object.entries({
  malformedChildren: spec(undefined, { children: 7 }),
  malformedExpression: spec({ label: 'Name', value: { $bindState: 42 } }),
  ignoredSlots: spec(undefined, { slots: { default: ['missing'] } }),
  invalidWatch: spec(undefined, {
    watch: { '/form/a': { action: 'setState', params: { value: 1 } } },
  }),
})) {
  console.log(name, bridge.invoke('validateSpec', JSON.stringify([input])));
}
JS
```
