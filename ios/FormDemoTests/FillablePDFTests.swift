@testable import FormDemo
import Foundation
import JSONRenderPDF
import JSONRenderSwiftUI
import PDFKit
import Testing

@MainActor
@Suite("Fillable PDF")
struct FillablePDFTests {
    /// A SwiftUI form spec using every catalog component.
    private static let kitchenSink: Spec = {
        func element(_ type: String, _ props: [String: JSONValue] = [:], children: [String] = [], visible: JSONValue? = nil) -> JSONValue {
            var json: JSONValue = ["type": .string(type), "props": .object(props), "children": .array(children.map(JSONValue.string))]
            if let visible { json = json.setting(visible, at: "/visible") }
            return json
        }
        func bind(_ path: String) -> JSONValue { ["$bindState": .string("/form/\(path)")] }
        let required: JSONValue = [["type": "required", "message": "Required"]]
        return Spec(json: [
            "root": "form",
            "elements": [
                "form": element("Form", ["title": "Kitchen Sink", "subtitle": "Every component"], children: ["main", "extras", "actions"]),
                "main": element("Section", ["header": "Main", "footer": "Footer note"], children: [
                    "name", "bio", "secret", "agree", "size", "color", "flavor", "country", "city", "plan",
                    "birthday", "meeting", "alarm", "count", "volume",
                ]),
                "name": element("TextField", [
                    "label": "Name", "placeholder": "Jane", "value": bind("name"),
                    "checks": [["type": "required", "message": "Required"], ["type": "maxLength", "args": ["max": 20], "message": "Too long"]],
                ]),
                "bio": element("TextField", ["label": "Bio", "value": bind("bio"), "multiline": true, "lineLimit": 4]),
                "secret": element("SecureField", ["label": "Password", "value": bind("password"), "checks": required]),
                "agree": element("Toggle", [
                    "label": "I agree", "isOn": bind("agree"),
                    "checks": [["type": "matches", "args": ["other": true], "message": "Must agree"]],
                ]),
                "size": element("Picker", ["label": "Size", "selection": bind("size"), "style": "segmented",
                                           "options": [["label": "Small", "value": "s"], ["label": "Large", "value": "l"]]]),
                "color": element("Picker", ["label": "Color", "selection": bind("color"), "style": "inline",
                                            "options": [["label": "Red", "value": "red"], ["label": "Blue", "value": "blue"]]]),
                "flavor": element("Picker", ["label": "Flavor", "selection": bind("flavor"), "style": "wheel",
                                             "options": [["label": "Mint", "value": "mint"]]]),
                "country": element("Picker", ["label": "Country", "selection": bind("country"), "style": "menu",
                                              "options": [["label": "Japan", "value": "jp"], ["label": "Peru", "value": "pe"]]]),
                "city": element("Picker", ["label": "City", "selection": bind("city"), "style": "navigationLink",
                                           "options": [["label": "Lima", "value": "lima"]]]),
                "plan": element("Picker", ["label": "Seats", "selection": bind("seats"),
                                           "options": [["label": "One", "value": 1], ["label": "Two", "value": 2]]]),
                "birthday": element("DatePicker", ["label": "Birthday", "selection": bind("birthday")]),
                "meeting": element("DatePicker", ["label": "Meeting", "selection": bind("meeting"), "components": "dateAndTime"]),
                "alarm": element("DatePicker", ["label": "Alarm", "selection": bind("alarm"), "components": "hourAndMinute"]),
                "count": element("Stepper", ["label": ["$template": "Guests: ${/form/count}"], "value": bind("count"), "minimum": 1, "maximum": 10]),
                "volume": element("Slider", ["label": "Volume", "value": bind("volume"), "minimum": 0, "maximum": 1]),
                "extras": element("VStack", [:], children: ["intro", "summary", "rule", "hidden", "chart", "pie", "row"]),
                "intro": element("Text", ["content": "Hello", "style": "headline"]),
                "summary": element("LabeledContent", ["label": "Total", "value": ["$template": "${/form/count} guests"]]),
                "rule": element("Divider"),
                "hidden": element("TextField", ["label": "Hidden", "value": bind("hidden")], visible: ["$state": "/form/agree", "not": true]),
                "chart": element("BarChart", ["data": ["$state": "/sales"], "xKey": "region", "yKey": "total", "aggregate": "sum"]),
                "pie": element("PieChart", ["data": ["$state": "/sales"], "nameKey": "region", "valueKey": "total", "donut": true]),
                "row": element("HStack", [:], children: ["cancel"]),
                "cancel": element("Button", ["label": "Cancel"]),
                "actions": element("Section", [:], children: ["submit"]),
                "submit": element("Button", ["label": "Send", "style": "borderedProminent"]),
            ],
            "state": ["form": [
                "name": "", "bio": "", "password": "", "agree": false, "size": "s", "color": "red", "flavor": "mint",
                "country": "jp", "city": "lima", "seats": 1, "birthday": "", "meeting": "", "alarm": "", "count": 1, "volume": 0.5,
                "hidden": "",
            ], "sales": [["region": "West", "total": 5], ["region": "East", "total": 3]]],
        ])
    }()

    private static let submitted: JSONValue = [
        "name": "Ada", "bio": "Line one", "password": "hunter22", "agree": true, "size": "l", "color": "blue",
        "flavor": "mint", "country": "pe", "city": "nowhere", "seats": 2, "birthday": "1990-12-10",
        "meeting": "2025-07-12T18:30:00Z", "alarm": "2025-07-12T07:05:00Z", "count": 3, "volume": 0.75,
    ]

    private func mapped() -> Spec {
        let state = (Self.kitchenSink.state ?? .object([:])).setting(.bool(true), at: "/form/agree")
        return FillablePDFMapper.spec(form: Self.kitchenSink, data: Self.submitted, dataRoot: "/form", state: state, timeZone: .gmt)
    }

    private func props(_ spec: Spec, _ key: String) -> [String: JSONValue] {
        spec.elements["f-\(key)"]?.props ?? [:]
    }

    @Test func mapsEveryComponentType() throws {
        let spec = mapped()
        let types = { (key: String) in spec.elements["f-\(key)"]?.type }
        #expect(spec.root == "doc")
        #expect(spec.elements["doc"]?.props["title"] == "Kitchen Sink")
        #expect(spec.elements["title"]?.props["text"] == "Kitchen Sink")
        #expect(spec.elements["subtitle"]?.props["text"] == "Every component")
        #expect(spec.elements["page"]?.children.last == "page-number")

        #expect(types("main") == "FieldSet")
        #expect(props(spec, "main")["name"] == "main")
        #expect(spec.elements["f-main-header"]?.type == "Heading")
        #expect(spec.elements["f-main-header"]?.props["text"] == "Main")
        #expect(spec.elements["f-main-footer"]?.props["text"] == "Footer note")

        #expect(types("name") == "TextInput")
        #expect(props(spec, "name")["value"] == "Ada")
        #expect(props(spec, "name")["required"] == true)
        #expect(props(spec, "name")["maxLength"] == 20)
        #expect(props(spec, "name")["placeholder"] == "Jane")
        #expect(props(spec, "bio")["multiline"] == true)
        #expect(props(spec, "bio")["lines"] == 4)

        #expect(types("secret") == "TextInput")
        #expect(props(spec, "secret")["password"] == true)
        #expect(props(spec, "secret")["value"] == .null, "secrets are never written into the PDF")

        #expect(types("agree") == "Checkbox")
        #expect(props(spec, "agree")["checked"] == true)
        #expect(props(spec, "agree")["required"] == true)

        for key in ["size", "color", "flavor"] { #expect(types(key) == "RadioGroup", "\(key)") }
        #expect(props(spec, "size")["direction"] == "vertical")
        #expect(props(spec, "color")["direction"] == "vertical")
        #expect(props(spec, "size")["value"] == "l")
        for key in ["country", "city", "plan"] { #expect(types(key) == "Select", "\(key)") }
        #expect(props(spec, "country")["value"] == "pe")
        #expect(props(spec, "city")["value"] == .null, "values that aren't options are dropped")
        #expect(props(spec, "plan")["options"] == [["label": "One", "value": "1"], ["label": "Two", "value": "2"]])
        #expect(props(spec, "plan")["value"] == "2")

        #expect(types("birthday") == "TextInput")
        #expect(props(spec, "birthday")["label"] == "Birthday (YYYY-MM-DD)")
        #expect(props(spec, "birthday")["value"] == "1990-12-10")
        #expect(props(spec, "meeting")["value"] == "2025-07-12 18:30")
        #expect(props(spec, "alarm")["value"] == "07:05")
        #expect(props(spec, "alarm")["label"] == "Alarm (HH:MM)")

        #expect(types("count") == "TextInput")
        #expect(props(spec, "count")["label"] == "Guests", "the template's trailing value is dropped")
        #expect(props(spec, "count")["value"] == "3")
        #expect(props(spec, "count")["placeholder"] == "1–10")
        #expect(props(spec, "volume")["value"] == "0.75")

        #expect(types("extras") == "Column")
        #expect(types("intro") == "Text")
        #expect(props(spec, "intro")["fontWeight"] == "bold")
        #expect(types("summary") == "Text")
        #expect(props(spec, "summary")["text"] == "Total: 1 guests")
        #expect(types("rule") == "Divider")
        #expect(types("hidden") == nil, "hidden fields are omitted")
        #expect(types("chart") == "BarChart")
        #expect(props(spec, "chart")["data"] == [["region": "West", "total": 5], ["region": "East", "total": 3]], "data is inlined")
        #expect(props(spec, "chart")["aggregate"] == "sum")
        #expect(props(spec, "chart")["title"] == .null)
        #expect(types("pie") == "PieChart")
        #expect(props(spec, "pie")["data"] == [["region": "West", "total": 5], ["region": "East", "total": 3]], "data is inlined")
        #expect(props(spec, "pie")["donut"] == true)
        #expect(props(spec, "pie")["legend"] == .null)
        #expect(types("row") == nil && types("cancel") == nil && types("submit") == nil, "buttons are omitted")
        #expect(types("actions") == nil, "a section with only buttons is omitted")
    }

    @Test func mappedSpecValidatesAndRenders() async throws {
        let spec = mapped()
        let report = try await JSONRenderBridge().validateSpec(spec, catalog: .pdf)
        #expect(report.valid, "\(report.issues.map(\.message))")

        let result = try await PDFRenderer().renderResult(spec)
        #expect(result.formFields.map(\.name) == [
            "main.name", "main.bio", "main.password", "main.agree", "main.size", "main.color", "main.flavor",
            "main.country", "main.city", "main.seats", "main.birthday", "main.meeting", "main.alarm",
            "main.count", "main.volume",
        ])
        #expect(result.formFields.first { $0.name == "main.size" }?.type == .radioGroup)
        #expect(result.formFields.first { $0.name == "main.country" }?.type == .select)
        #expect(result.formFields.first { $0.name == "main.agree" }?.type == .checkbox)
    }

    @Test func registrationAndRSVPFields() async throws {
        let registration = try #require(ExampleSpec.named("registration", kind: .form)).load()
        let registrationState = registration.state ?? .object([:])
        let registrationPDF = FillablePDFMapper.spec(form: registration, data: registrationState.value(at: "/form") ?? .null, dataRoot: "/form", state: registrationState)
        let registrationFields = try await PDFRenderer().renderResult(registrationPDF).formFields
        #expect(registrationFields.map(\.name) == [
            "account.email", "account.password", "account.confirmPassword",
            "profile.fullName", "profile.accountType", "terms-section.acceptTerms",
        ])

        let rsvp = try #require(ExampleSpec.named("event-rsvp", kind: .form)).load()
        var rsvpState = rsvp.state ?? .object([:])
        let rsvpPDF = FillablePDFMapper.spec(form: rsvp, data: rsvpState.value(at: "/form") ?? .null, dataRoot: "/form", state: rsvpState)
        let rsvpFields = try await PDFRenderer().renderResult(rsvpPDF).formFields
        #expect(rsvpFields.map(\.name) == [
            "guest.name", "guest.email", "attendance.attending",
            "details.guests", "details.arrival", "details.meal", "details.hasDietaryNeeds",
        ])
        #expect(rsvpFields.first { $0.name == "attendance.attending" }?.type == .radioGroup)
        #expect(rsvpFields.first { $0.name == "details.meal" }?.type == .select)

        rsvpState = rsvpState.setting(.bool(true), at: "/form/hasDietaryNeeds")
        let shown = FillablePDFMapper.spec(form: rsvp, data: rsvpState.value(at: "/form") ?? .null, dataRoot: "/form", state: rsvpState)
        #expect(try await PDFRenderer().renderResult(shown).formFields.count == 8, "a field revealed by visibility is included")

        for spec in [registrationPDF, rsvpPDF] {
            let report = try await JSONRenderBridge().validateSpec(spec, catalog: .pdf)
            #expect(report.valid, "\(report.issues.map(\.message))")
        }
    }

    @Test func submissionCarriesTheFillableExport() throws {
        let controller = GenerationController(kind: .form, generator: MockGenerator(.chunks([]))) {
            GenerationOptions(model: "m", reasoningEffort: nil)
        }
        controller.load(try #require(ExampleSpec.named("event-rsvp", kind: .form)).load())
        controller.showSubmission(["name": "Ada", "email": "ada@example.com", "attending": "maybe", "guests": 2])
        let fillable = try #require(controller.submission?.fillable)
        #expect(fillable.elements["f-name"]?.props["value"] == "Ada")
        #expect(fillable.elements["f-attending"]?.props["value"] == "maybe")
        #expect(PDFExport(spec: fillable, fileSuffix: " (fillable)").fileName == "Summer Party RSVP (fillable).pdf")
    }

    // MARK: Reading back

    @Test func readerRoundTripThroughThePreview() async throws {
        let application = try #require(ExampleSpec.named("application-form", kind: .document)).load()
        let preview = PDFPreviewModel(options: .init(imageLoader: .placeholders))
        await preview.show(application, isStreaming: false)
        #expect(preview.hasForm)
        let before = try preview.filledValues()
        #expect(before.values["applicant.firstName"] == "Jane")

        // Edit like the user would in the PDFView, then read the edited document.
        preview.fill(["firstName": "Alex", "employer": "Contoso Ltd.", "dateOfBirth": "01/02/1990"])
        let after = try preview.filledValues()
        #expect(after.values["applicant.firstName"] == "Alex")
        #expect(after.values["employment.employer"] == "Contoso Ltd.")
        #expect(after.values["applicant.address.state"] == "OR")
        #expect(after.values["household.hasPets"] == true)
        #expect(after.updates.contains(.init(pointer: "/applicant/firstName", value: "Alex")))
        #expect(after.values["applicant.dateOfBirth"] == "01/02/1990")
        #expect(after.unboundFields.contains("applicant.dateOfBirth"), "filled but not bound to state")
        #expect(!after.unboundFields.contains("applicant.ssnLast4"), "empty unbound fields aren't listed")

        // Showing the same spec again keeps the edits.
        await preview.show(application, isStreaming: false)
        #expect(try preview.filledValues().values["applicant.firstName"] == "Alex")

        // Apply to state: the document's state changes and the next render shows the value.
        let controller = GenerationController(kind: .document, generator: MockGenerator(.chunks([]))) {
            GenerationOptions(model: "m", reasoningEffort: nil)
        }
        controller.load(application)
        controller.applyState(after.updates)
        let updated = try #require(controller.spec)
        #expect(updated.state?.value(at: "/applicant/firstName") == "Alex")
        #expect(updated.state?.value(at: "/employment/employer") == "Contoso Ltd.")
        #expect(updated.state?.value(at: "/property/rent") == "$2,150", "other state is kept")

        let fresh = PDFPreviewModel(options: .init(imageLoader: .placeholders))
        await fresh.show(updated, isStreaming: false)
        #expect(try fresh.filledValues().values["applicant.firstName"] == "Alex")
    }

    // MARK: Preview lifecycle

    private static func imageDocument(_ title: String) -> Spec {
        Spec(json: [
            "root": "doc",
            "elements": [
                "doc": ["type": "Document", "props": ["title": .string(title)], "children": ["page"]],
                "page": ["type": "Page", "props": ["size": "A4"], "children": ["image"]],
                "image": ["type": "Image", "props": ["src": "https://example.com/slow.png", "width": 100, "height": 50], "children": []],
            ],
        ])
    }

    @Test func staleRenderNeverReplacesANewerDocument() async throws {
        let gate = Gate()
        let loader = PDFImageLoader { _ in
            await gate.wait()
            throw URLError(.cancelled)
        }
        let preview = PDFPreviewModel(options: .init(imageLoader: loader))
        let application = try #require(ExampleSpec.named("application-form", kind: .document)).load()

        let old = Task { await preview.show(Self.imageDocument("Old"), revision: 1, isStreaming: false) }
        try await gate.waitUntilEntered()

        await preview.show(application, revision: 2, isStreaming: false)
        preview.fill(["firstName": "Alex"])
        await gate.open()
        await old.value

        #expect(preview.renderedSpec == application)
        #expect(preview.renderedRevision == 2)
        #expect(try preview.filledValues().values["applicant.firstName"] == "Alex", "edits survive the stale render")
    }

    @Test func resetAndNewRevisionsDropCachedEdits() async throws {
        let application = try #require(ExampleSpec.named("application-form", kind: .document)).load()
        let preview = PDFPreviewModel()
        await preview.show(application, revision: 1, isStreaming: false)
        preview.fill(["firstName": "Alex"])

        await preview.show(application, revision: 1, isStreaming: false)
        #expect(try preview.filledValues().values["applicant.firstName"] == "Alex", "same spec and revision keeps edits")

        await preview.show(application, revision: 2, isStreaming: false)
        #expect(try preview.filledValues().values["applicant.firstName"] == "Jane", "a reloaded document starts fresh")

        preview.fill(["firstName": "Alex"])
        preview.reset()
        #expect(preview.document == nil && !preview.hasForm)
        await preview.show(application, revision: 2, isStreaming: false)
        #expect(try preview.filledValues().values["applicant.firstName"] == "Jane", "Clear drops the filled PDF")

        // The controller bumps its revision on every replacement, even with an equal spec.
        let controller = GenerationController(kind: .document, generator: MockGenerator(.chunks([]))) {
            GenerationOptions(model: "m", reasoningEffort: nil)
        }
        controller.load(application)
        let loaded = controller.revision
        controller.clear()
        controller.load(application)
        #expect(controller.revision > loaded + 1)
        controller.applyState([.init(pointer: "/applicant/firstName", value: "Sam")])
        #expect(controller.revision == loaded + 2, "applying values updates the document in place")
    }

    @Test func exportSharesTheEditedDocument() async throws {
        let application = try #require(ExampleSpec.named("application-form", kind: .document)).load()
        let preview = PDFPreviewModel()
        await preview.show(application, revision: 3, isStreaming: false)
        preview.fill(["firstName": "Alex", "dateOfBirth": "01/02/1990"])

        let export = preview.export(for: application, revision: 3)
        #expect(export.live != nil)
        let values = try PDFFormReader(data: Data(contentsOf: try await export.render())).values()
        #expect(values["applicant.firstName"] == "Alex")
        #expect(values["applicant.dateOfBirth"] == "01/02/1990", "unbound edits are exported too")

        #expect(preview.export(for: application, revision: 4).live == nil, "an outdated preview isn't exported")
        let rendered = try PDFFormReader(data: Data(contentsOf: try await preview.export(for: application, revision: 4).render())).values()
        #expect(rendered["applicant.firstName"] == "Jane")

        let invoice = try #require(ExampleSpec.named("invoice", kind: .document)).load()
        await preview.show(invoice, revision: 5, isStreaming: false)
        #expect(preview.export(for: invoice, revision: 5).live == nil, "documents without fields are rendered from the spec")
    }

    @Test func mappedFormRoundTrip() async throws {
        let registration = try #require(ExampleSpec.named("registration", kind: .form)).load()
        let state = registration.state ?? .object([:])
        let spec = FillablePDFMapper.spec(form: registration, data: ["email": "a@example.com", "acceptTerms": true], dataRoot: "/form", state: state)
        let preview = PDFPreviewModel()
        await preview.show(spec, isStreaming: false)
        preview.fill(["email": "edited@example.com"])
        let values = try preview.filledValues()
        #expect(values.values["account.email"] == "edited@example.com")
        #expect(values.values["terms-section.acceptTerms"] == true)
        #expect(values.values["profile.accountType"] == "personal")
        #expect(values.updates.isEmpty, "mapped forms carry literal values, not state bindings")
    }

    @Test func streamedApplicationFormMatchesTheFixture() async throws {
        let jsonl = try ExampleSpec.replayStream(named: "application-form")
        let controller = GenerationController(kind: .document, generator: MockGenerator(.chunks([]))) {
            GenerationOptions(model: "m", reasoningEffort: nil)
        }
        await controller.replay(jsonl, delay: .zero).value
        let expected = try #require(ExampleSpec.named("application-form", kind: .document)).load()
        #expect(controller.spec?.json == expected.json)
        #expect(controller.errorMessage == nil)
    }
}

/// Holds a render at the image loader until opened.
actor Gate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitUntilEntered() async throws {
        for _ in 0..<500 where !entered {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered, "the render reached the image loader")
    }
}
