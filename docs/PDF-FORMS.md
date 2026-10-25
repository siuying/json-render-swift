# Fillable PDF forms — contract

Extends `docs/PDF.md`. Research: `docs/research-pdf-forms.md` (probes in /tmp: react-pdf-form-probe.mjs,
pdfkit-form-probe.swift). Goal: json-render PDF specs can contain **real AcroForm fields** that Preview (iOS/macOS)
and Acrobat can fill, and filled PDFs can be read back into JSON state.

## Catalog additions (PDF catalog only)

Names follow `@react-pdf/renderer` 4.9 (`FieldSet`, `TextInput`, `Checkbox`, `Select`, `List`) plus `RadioGroup`
(react-pdf has none). All are leaf widgets except `FieldSet` (default slot).

| Component | Props |
|---|---|
| `FieldSet` | `name` (req), `label?` — layout container + field-name scope |
| `TextInput` | `name` (req), `label?`, `value?`, `placeholder?`, `required?`, `readOnly?`, `maxLength?`, `multiline?`, `lines?` (visible lines, multiline height), `password?`, `align?`, `fontSize?`, `width?` |
| `Checkbox` | `name` (req), `label` (req), `checked?`, `required?`, `readOnly?`, `exportValue?` (default `"Yes"`) |
| `RadioGroup` | `name` (req), `label?`, `options` (req: `[{label, value}]`), `value?`, `direction?` (`vertical`/`horizontal`), `required?`, `readOnly?` |
| `Select` | `name` (req), `label?`, `options` (req: `[{label, value}]`), `value?`, `editable?`, `required?`, `readOnly?`, `width?` |
| `List` (name clash!) | upstream PDF catalog already has a static `List` (bullets). Use **`ListBox`** for the choice list: `name`, `label?`, `options`, `value?` (string or string[]), `multiSelect?`, `rows?` (visible rows), `required?`, `readOnly?` |

Values may be expressions (`$state`, `$item`, `$template`, `$cond`), resolved before layout like any prop.
Labels are drawn as static text outside the widget rect. Fixed geometry: text 22 pt high (multiline: lines × 14 + 8),
checkbox/radio box 12 pt, select 22 pt, list rows × 14 + 6. Widgets never split across pages; label + widget move together.

Field naming: fully qualified name = `FieldSet` names joined with `.` + `name`. Names must be unique per document
(validator error on duplicates; renderer appends `#2`, `#3` defensively). Repeat scopes are allowed. Core's
`$template` cannot interpolate `$index`, so per-item names come from `$item`, `$bindItem`, a bare `${field}` in
`$template` (e.g. `{ "$template": "reference${id}" }`), or an enclosing FieldSet whose name varies per item.

## PDF output requirements (portable AcroForm)

- Catalog `/AcroForm` with `/Fields` (top-level field dicts), `/NeedAppearances true`, `/DR` with Helvetica (`/Helv`)
  and ZapfDingbats (`/ZaDb`), `/DA (/Helv 0 Tf 0 g)`.
- Every widget: `/FT`, `/T` (partial name), `/Rect`, `/F 4` (print), `/P` page ref, `/DA` referencing `/Helv`,
  `/V`/`/DV` when valued, `/Ff` flags (ReadOnly 1, Required 2, Multiline 4096, Password 8192, Radio 32768,
  NoToggleToOff 16384, Combo 131072, Edit 262144, MultiSelect 2097152), `/MaxLen`, `/Q` alignment, `/Opt` as
  `[[export label] …]` pairs for choices, `/MK` border/background.
- Appearance streams `/AP` for checkboxes and radios (on/off states, ZapfDingbats check / circle); text and
  choice rely on `/NeedAppearances` but SHOULD also get a normal appearance with the current value so
  non-regenerating viewers show it.
- Radio group: ONE parent field dict (`/FT /Btn`, `/Ff` radio|noToggleToOff, `/T`, `/V /<selected>`, `/Kids`)
  with one widget kid per option, each with `/AS` and `/AP /N << /<export> … /Off … >>`.
- FieldSet: non-terminal field dict with `/T` and `/Kids`.
- Implementation approach is the Swift agent's choice, but PDFKit's raw `dataRepresentation()` is known to omit
  `/AcroForm` and the field tree (macOS 27 probe). Recommended: keep the existing CG drawing pipeline and append the
  form via a **PDF incremental update** written by our own small writer (new objects for fields/widgets/fonts/
  appearances + updated catalog + updated page `/Annots` + new xref section/trailer with `/Prev`). This needs the
  object numbers of the catalog and pages of the CG-produced file: parse its (classic) xref/trailer, or produce the
  base PDF in a way where those numbers are known. Alternatively use PDFKit widgets + incremental repair. Must pass
  `qpdf --check` (qpdf is installed) with no errors.

## Reading back

`PDFFormReader` (Swift): load a filled PDF (PDFKit), enumerate widgets / field tree, return
`[fullyQualifiedName: JSONValue]` (text → string, checkbox → bool, radio/select → selected export value,
multi-select list → [string]), and a helper that maps values back to JSON Pointers using a mapping the renderer
returns (`PDFRenderResult.formFields: [PDFFormFieldInfo(name, type, pointer?, options)]`, pointer = the `$state`
/ `$bindState` path of `value`/`checked` when bound). Treat input as untrusted (validate types/option tokens).

## Verification

- Unit tests: dictionary-level assertions (parse output with CGPDFDocument: catalog /AcroForm, /Fields count,
  radio parent+kids, flags, /Opt, /MaxLen, /DA, /AP states), `qpdf --check` in a macOS test (skip if qpdf missing),
  round-trip: render → PDFDocument → set values programmatically via PDFKit → save → PDFFormReader returns them.
- Run on iOS 26.2 simulator and iOS 27 simulator + macOS (probe only covered macOS 27).
- Visual: render first page PNG; also open the PDF in macOS Preview via `qlmanage` thumbnail to confirm fields draw.
- Reference: react-pdf render of an equivalent form (`fixtures/pdf/reference/application-form.pdf`) for side-by-side
  comparison of the supported components (react-pdf has no RadioGroup).

## Demo

Document mode: offline example `application-form`; preview is fillable in-app (PDFView supports widget editing);
"Read filled values" button shows extracted JSON. Form mode: "Export as fillable PDF" maps the SwiftUI form spec
to a PDF form spec (TextField/SecureField → TextInput, Toggle → Checkbox, Picker segmented/inline → RadioGroup,
Picker menu → Select, DatePicker → TextInput with format hint, Stepper/Slider → TextInput) seeded with current values.
