# Research: fillable PDF forms

Date: 2026-10-25. This is a local API and output probe, not a source change.

## Summary

The native route is plausible, but `PDFDocument.dataRepresentation()` alone did not produce a complete AcroForm on the macOS host I tested. PDFKit wrote widget annotations with `/FT`, values, `/AP` appearances, and `/DA`, but its catalog had no `/AcroForm`, `/Fields`, `/DR`, or `/NeedAppearances`. A viewer may draw these annotations, but the file is missing the form root and field tree that make a portable fillable form. Use PDFKit for annotation objects and rendering only after confirming its behavior on the deployment SDK, or add/repair the catalog form dictionary and parent/child field structure at a lower level. Validate the final output with Acrobat/Preview and `qpdf --check`.

The `@react-pdf/renderer` probe did produce a catalog `/AcroForm`, `/Fields`, `/NeedAppearances true`, a `/DR` Helvetica font and checkbox ZapfDingbats resource, field values/options, and a `FieldSet` parent with `/Kids`. It emits explicit checkbox appearance streams; text and choice fields in my sample had no `/AP`.

## 1. React PDF and PDFKit reference

Local versions: `@react-pdf/renderer` 4.9.0, its nested `pdfkit` 0.20.1, `@react-pdf/render` 4.7.0. Types are in `node_modules/.pnpm/@react-pdf+renderer@4.9.0_react@19.3.1/node_modules/@react-pdf/renderer/index.d.ts`; implementation is in the nested `@react-pdf/render/lib/index.js` and `pdfkit` package.

React PDF exports `FieldSet`, `TextInput`, `Checkbox`, `Select`, and `List`. It does not export a radio group or a React push-button form component in this version, even though PDFKit has a lower-level `formPushButton`. In the types, all form widgets extend layout `NodeProps`, so normal layout style/bounds apply.

| Component | Props |
| --- | --- |
| `FieldSet` | `name: string`; children are form widgets. |
| Common widget props | `name?`, `required?`, `noExport?`, `readOnly?`, `value?: number \| string`, `defaultValue?: number \| string` |
| `TextInput` | Common props; `align?: 'left' \| 'center' \| 'right'`, `multiline?`, `password?`, `noSpell?`, `format?`, `fontSize?`, `maxLength?`. `format.type` is `date`, `time`, `percent`, `number`, `zip`, `zipPlus4`, `phone`, or `ssn`; `param?`, `nDec?`, `sepComma?`, `negStyle?` (`MinusBlack`, `Red`, `ParensBlack`, `ParensRed`), `currency?`, and `currencyPrepend?` are formatting options. |
| `Checkbox` | Common props; `backgroundColor?`, `borderColor?`, `checked?`, `onState?`, `offState?`, `xMark?`. Defaults for appearance names are `Yes` and `Off`. `checked` determines `/V`, `/DV`, `/AS`, and the normal/down appearance state. |
| `Select`, `List` | Common props; `sort?`, `edit?`, `multiSelect?`, `noSpell?`, `select?: string[]`. The list of choices is strings, with no distinct label/export-value pair API. `Select` calls PDFKit `formCombo`; `List` calls `formList`. |

Rendering details observed in source and the reference file:

- The first form widget calls `initForm()`. PDFKit requires a font before `initForm`; React PDF's default page text setup supplies Helvetica. React PDF's form dictionary has `/DR /Font /Helv` (Helvetica) and a ZapfDingbats font resource used for the checkbox glyph.
- A `FieldSet` creates a field parent `/T (person)` and attaches descendant text/checkbox widget dictionaries with `/Parent` and `/Kids`. In this renderer, `Select` and `List` do not receive the active field-set parent, so choice controls remain top-level fields.
- `TextInput` is `/FT /Tx`; `multiline` sets bit 4096, `password` sets bit 8192, `required` bit 2, `readOnly` bit 1, and `maxLength` becomes `/MaxLen`. `value` is written as `/V`; `defaultValue` as `/DV`. Text appearance is viewer-generated in the sample, with `/NeedAppearances true` and no widget `/AP`.
- Checkbox fields are `/FT /Btn`; React PDF builds `/AP /N` and `/AP /D` state dictionaries itself, including `onState` and `offState`, and stores `/V`, `/DV`, and `/AS`. The sample's checkbox `/AP` uses ZapfDingbats drawing. Checkbox `required` was not reflected in `/Ff` in the probe, even though the same prop did affect `TextInput`; treat this as an upstream quirk to test if matching behavior matters.
- Choice widgets are `/FT /Ch`, with `/Opt` from `select`, `/V` from the selected value. `Select` used `/Ff 131072` in this sample (combo + edit flags); `List` used `/Ff 2097152` (multi-select). They had no `/AP` and relied on viewer appearance generation.
- The common parser uses `value || undefined` and `defaultValue || undefined`; an empty string and numeric zero are dropped. The API accepts numbers in types, but the emitted field values are PDF strings/names. This favors JSON-render choosing and normalizing strings deliberately.

Reference generation ran from `/tmp/react-pdf-form-probe.mjs`, producing `/tmp/react-pdf-form.pdf`; `qpdf --qdf --object-streams=disable` output is `/tmp/react-pdf-form-qdf.pdf`. `qpdf --check` reported no syntax or stream encoding errors. The probe includes a field set, text, multiline, checkbox, dropdown, and multiselect list. It does not exercise every `format` option.

## 2. PDFKit on the Apple platform

Apple's PDFKit API exposes the needed widget family. Create `PDFAnnotation(bounds:forType:.widget,withProperties:)`, then set `widgetFieldType` to `.text`, `.button`, or `.choice`. Buttons use `widgetControlType` `.checkBoxControl`, `.radioButtonControl`, or `.pushButtonControl`. Text supports `isMultiline`, `maximumLength`, alignment, font/color and read-only. Choice supports `choices`, `values` (export values), and `isListChoice`. Fields have `fieldName`, `widgetStringValue`, `widgetDefaultStringValue`, and widgets have background, `color`/`border`, font, `fontColor`, and `isReadOnly`. The state enum names are `.onState`, `.offState`, and `.mixedState`.

Two API caveats from compiling/running the probe:

- `isPasswordField` is get-only in the Swift API. PDF field flag bit 8192 (`/Ff`) must be set through the annotation dictionary if password widgets are required. `hasComb` also represents a field flag and is a separate feature from multiline.
- The public API has `values` to distinguish choice export values from labels. The React PDF form API does not expose this distinction.

The actual probe ran with `xcrun swift` on macOS 27.0.1, build 26A434, using macOS SDK 27.0. This checks the installed PDFKit behavior on that host; it does not establish behavior on iOS 26 or macOS 26.

Probe script: `/tmp/pdfkit-form-probe.swift`. It created a blank page, text and multiline text, checkbox, two same-name radio widgets with different state strings, dropdown, and list; wrote `PDFDocument.dataRepresentation()` to `/tmp/pdfkit-form.pdf`; reloaded it; and read annotation values back. Reload preserved all 7 annotations, values, text flags, max lengths, check state, radio states, and choice values. `qpdf --check` found no syntax or stream encoding errors.

The QDF dictionary dump (`/tmp/pdfkit-form-qdf.pdf`) showed:

- Each widget had `/Subtype /Widget`, `/FT`, `/T`, `/Rect`, and `/V`. Text/multiline/checkbox/radio/choice widgets also had `/AP` appearance streams.
- Text wrote `/DA (/.AppleSystemUIFont 12 Tf 0 g)` and `/MaxLen`; multiline wrote `/Ff 4096`. `/DA` refers to `/.AppleSystemUIFont`, but there was no catalog `/AcroForm /DR` font resource mapping it.
- Checkbox wrote `/V /Accepted`, `/AS /Accepted`, and `/AP` states. Radio widgets wrote `/FT /Btn`, radio flags `/Ff 49152`, and different `/AS` and `/V` names (`/One` and `/Off`). They were separate widget dictionaries with identical `/T (person.choice)`, no `/Parent`, and no shared field dictionary `/Kids` array. The saved values did not normalize to a single selected group value. Do not assume same `fieldName` alone yields a portable radio group.
- Choice fields wrote `/FT /Ch`, `/Opt`, `/V`, and `/AP`. The `isListChoice` setting did not result in a visible list-choice field flag in the emitted `/Ff` in this probe; recheck on exact deployment OS and inspect the dictionary. `values` was not tested.
- **The catalog had no `/AcroForm` entry at all.** It had no `/Fields`, `/NeedAppearances`, or `/DR`. The page `/Annots` array listed widgets, but there was no document form root or field tree. This is the main portability blocker in the raw PDFKit result.

Apple documents PDFKit widgets as interactive controls and documents same `fieldName` with unique `buttonWidgetStateString` for radio choices. Its docs also describe iPhone Preview form filling. That does not resolve the missing root/field-tree finding in this probe; test target SDK output in Preview and Acrobat before relying on it. iOS 26 Preview supports filling PDF forms, per [Apple's iPhone Preview guide](https://support.apple.com/guide/iphone/fill-out-and-sign-pdf-forms-iphd7e3c0c74/ios). Apple does not promise that every PDFKit-produced widget combination will render identically in every viewer.

Relevant API references: [Adding widgets to a PDF document](https://developer.apple.com/documentation/pdfkit/adding-widgets-to-a-pdf-document), [PDFAnnotation](https://developer.apple.com/documentation/pdfkit/pdfannotation), [widgetFieldType](https://developer.apple.com/documentation/pdfkit/pdfannotation/widgetfieldtype), [PDFWidgetCellState](https://developer.apple.com/documentation/pdfkit/pdfwidgetcellstate), [choices and export values](https://developer.apple.com/documentation/pdfkit/pdfannotation/choices).

### Read-back mapping

Enumerate `PDFDocument` pages, then each `PDFPage.annotations`, filter `annotation.type == PDFAnnotationSubtype.widget` (or test `widgetFieldType`), and read `fieldName` plus subtype/value:

- Text: `widgetStringValue` gives filled text.
- Checkbox: inspect `buttonWidgetState` or `widgetStringValue`; map `.onState` to `true`, `.offState` to `false`. Preserve `buttonWidgetStateString` as the export token if the JSON value should be a string/enum instead.
- Radio: find widgets sharing the logical field, select the one with `.onState`, and map its `buttonWidgetStateString` to the selected option. With this probe's PDFKit result, the dictionary has duplicate names but no shared parent field, so reader code should not infer a clean group from `fieldName` until the writer emits a valid shared field node.
- Dropdown/list: `widgetStringValue` is the current selection. Use `choices` for visible options and `values` for export values when set. Multi-select may need the raw annotation dictionary because the public string value is singular and PDFKit's behavior should be tested with actual multiple selected values.

For reliable JSON import, persist a mapping of PDF field name to JSON Pointer and logical type alongside the rendering code or in private document metadata. Treat the PDF as an untrusted input; validate field names, option tokens, and types before merging values into JSON state.

## 3. Suggested json-render catalog design

Keep static `TextInput`, `Checkbox`, `Select`, and `List` names close to React PDF. Add `RadioGroup` because the upstream React tree has no radio API, and retain `FieldSet` as a structural grouping component. Do not overload a checkbox to mean a radio option. For export values distinct from labels, use `{label, value}` options in json-render, then emit `/Opt` pairs and button state names. This is a useful improvement over React PDF's string-only `select`.

Suggested props:

- `FieldSet`: `name?`, `label?`; layout children and field-name scope.
- `TextInput`: `name`, `value?`, `defaultValue?`, `required?`, `readOnly?`, `maxLength?`, `multiline?`, `password?`, `align?`, `fontSize?`, `format?`.
- `Checkbox`: `name`, `value?` / `defaultValue?`, `checked?`, `required?`, `readOnly?`, `onState?`, `offState?`, `xMark?`.
- `RadioGroup`: `name`, `value?` / `defaultValue?`, `options: [{label, value}]`, `required?`, `readOnly?`, plus direction/gap for layout.
- `Select` and `List`: `name`, `value?` / `defaultValue?`, `options: [{label, value}]`, `required?`, `readOnly?`, `editable?`, `multiSelect?`, `sort?`.

Bind `value` from resolved state when present; use `defaultValue` for the initial PDF value otherwise. For choice values, preserve option tokens exactly. Static PDF generation cannot keep a live link back to the app's JSON state after a person edits it in Preview or Acrobat; read changed values from the saved PDF and merge them in a separate import step.

Use the binding path as the logical identity. Give each widget a deterministic, collision-safe PDF field name derived from its JSON Pointer (escape each pointer segment before joining, or encode the whole pointer with base64url and a `jr.` prefix). Keep JSON Pointer mapping available for import. Use `FieldSet` only for actual group hierarchy, with names unique within the group. Radio widgets must share one parent field and have distinct export/state names under it.

Layout needs fixed widget geometry. Reserve a known height for every text field; multiline fields need explicit taller heights and should not flow/split across pages. Put labels outside widget rectangles so a tap target stays clear. For checkbox/radio rows, reserve a fixed icon box and separate label space; wrap labels without changing field bounds. Select widgets need enough height for a single line; list widgets need a height that shows the intended number of rows. If pagination moves a field, move its label and widget together. This keeps the printed appearance and clickable rectangle aligned.

## Probe commands and artifacts

```sh
node /tmp/react-pdf-form-probe.mjs
qpdf --qdf --object-streams=disable /tmp/react-pdf-form.pdf /tmp/react-pdf-form-qdf.pdf
xcrun swift /tmp/pdfkit-form-probe.swift
qpdf --qdf --object-streams=disable /tmp/pdfkit-form.pdf /tmp/pdfkit-form-qdf.pdf
qpdf --check /tmp/react-pdf-form.pdf
qpdf --check /tmp/pdfkit-form.pdf
```
