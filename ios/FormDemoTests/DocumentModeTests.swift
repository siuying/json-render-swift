@testable import FormDemo
import Foundation
import JSONRenderPDF
import JSONRenderSwiftUI
import PDFKit
import Testing

@MainActor
@Suite("Document mode")
struct DocumentModeTests {
    private func makeController(_ generator: MockGenerator) -> GenerationController {
        GenerationController(kind: .document, generator: generator) {
            GenerationOptions(model: "test-model", reasoningEffort: nil)
        }
    }

    @Test func streamsStatementIntoTheExpectedSpec() async throws {
        let jsonl = try ExampleSpec.replayStream(for: .document)
        let generator = MockGenerator(.chunks(ReplayStream.chunks(of: jsonl)))
        let controller = makeController(generator)

        await controller.generate("Monthly bank statement").value

        let expected = try #require(ExampleSpec.named("statement", kind: .document)).load()
        #expect(controller.spec?.json == expected.json)
        #expect(controller.rawJSONL == jsonl)
        #expect(controller.patchCount == jsonl.split(separator: "\n").count)
        #expect(controller.errorMessage == nil)
        #expect(controller.issues.filter(\.isError).isEmpty)

        let request = try #require(generator.requests.first)
        #expect(request.instructions.contains("PageNumber"), "uses the PDF catalog's system prompt")
        #expect(!request.instructions.contains("SecureField"))
        #expect(!request.instructions.contains(#"custom action "log""#))
        #expect(request.input.contains("Monthly bank statement"))

        // The streamed spec renders to a multi-page PDF.
        let spec = try #require(controller.spec)
        let document = try await PDFRenderer(options: .init(imageLoader: .placeholders)).document(for: spec)
        #expect(document.pageCount >= 2)
        #expect(document.string?.contains("Northwind Bank") == true)
    }

    @Test func followUpEditsTheCurrentDocument() async throws {
        let generator = MockGenerator(.chunks([]))
        let controller = makeController(generator)
        controller.load(try #require(ExampleSpec.named("invoice", kind: .document)).load())

        generator.behavior = .chunks([#"{"op":"replace","path":"/elements/doc/props/title","value":"Invoice #2001"}"# + "\n"])
        await controller.generate("Renumber the invoice to 2001").value

        let request = try #require(generator.requests.last)
        #expect(request.input.contains("Invoice #1042"), "edit mode sends the current spec")
        #expect(controller.errorMessage == nil)
        #expect(controller.spec?.elements["doc"]?.props["title"] == .string("Invoice #2001"))
        #expect(controller.spec?.elements["items-table"] != nil)
    }

    @Test func noDocumentIsReported() async {
        let controller = makeController(MockGenerator(.chunks(["Here is your invoice!"])))
        await controller.generate("Invoice").value
        #expect(controller.errorMessage == "The model returned no document. Try rephrasing your request.")
    }

    @Test func stopKeepsThePartialDocument() async throws {
        let lines = try ExampleSpec.replayStream(for: .document).split(separator: "\n").map { $0 + "\n" }
        let generator = MockGenerator(.manual)
        let controller = makeController(generator)
        let task = controller.generate("Statement")
        let continuation = try await generator.waitForContinuation()
        for line in lines.prefix(5) { continuation.yield(.text(String(line))) }
        for _ in 0..<200 where controller.spec?.elements["page"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.stop()
        await task.value
        #expect(!controller.isStreaming)
        #expect(controller.spec?.elements["page"] != nil)
        #expect(controller.errorMessage == nil)
    }

    @Test func everyExampleValidatesAgainstThePDFCatalog() async throws {
        let controller = makeController(MockGenerator(.chunks([])))
        let bridge = try JSONRenderBridge()
        for example in ExampleSpec.documents {
            let spec = try example.load()
            controller.load(spec)
            #expect(controller.spec == spec)
            let report = try await bridge.validateSpec(spec, catalog: .pdf)
            #expect(report.valid, "\(example.id): \(report.issues.map(\.message))")
        }
    }

    @Test func exportUsesTheResolvedDocumentTitle() async throws {
        let statement = try #require(ExampleSpec.named("statement", kind: .document)).load()
        let export = PDFExport(spec: statement)
        #expect(export.title == "Statement - March 1 - March 31, 2025")
        #expect(export.fileName == "Statement - March 1 - March 31, 2025.pdf")

        let url = try await export.render()
        #expect(url.lastPathComponent == export.fileName)
        #expect(PDFDocument(url: url)?.pageCount ?? 0 >= 2)

        #expect(PDFExport(spec: Spec(json: ["root": "doc", "elements": ["doc": ["type": "Document", "props": ["title": "Q3: A/B results"], "children": []]]])).fileName == "Q3- A-B results.pdf")
        #expect(PDFExport(spec: .empty).fileName == "Document.pdf")
    }
}

@MainActor
@Suite("Modes")
struct ModeIsolationTests {
    @Test func eachModeKeepsItsOwnState() async throws {
        let generator = MockGenerator(.chunks([]))
        let model = AppModel(generator: generator) { GenerationOptions(model: "m", reasoningEffort: nil) }
        #expect(model.forms.kind == .form)
        #expect(model.documents.kind == .document)

        let form = try #require(ExampleSpec.named("registration", kind: .form)).load()
        model.forms.load(form)
        model.forms.session.store.set("ada@example.com", at: "/form/email")
        model.mode = .document

        let jsonl = try ExampleSpec.replayStream(for: .document)
        await model.documents.replay(jsonl, delay: .zero).value
        model.documents.errorMessage = "document-only error"
        model.mode = .form

        #expect(model.forms.spec == form)
        #expect(model.forms.session.store.state.value(at: "/form/email") == .string("ada@example.com"))
        #expect(model.forms.rawJSONL.isEmpty)
        #expect(model.forms.errorMessage == nil)
        #expect(model.documents.spec?.root == "doc")
        #expect(model.documents.rawJSONL == jsonl)

        model.forms.clear()
        #expect(model.documents.hasSpec)
    }

    @Test func launchOptions() {
        let options = LaunchOptions(arguments: ["app", "-mode", "document", "-pdf-example", "invoice", "-tab", "json", "-submit-pdf"])
        #expect(options.mode == .document)
        #expect(options.pdfExample == "invoice")
        #expect(options.tab == .json)
        #expect(options.submit && options.submitPDF)
        #expect(LaunchOptions(arguments: ["app"]).mode == .form)
    }
}

@MainActor
@Suite("Submission summary PDF")
struct SubmissionSummaryTests {
    private let date = Date(timeIntervalSince1970: 1_767_268_800)  // 2026-01-01T12:00:00Z

    @Test func rowsFollowVisibleFieldsWithDisplayValues() throws {
        let form = try #require(ExampleSpec.named("registration", kind: .form)).load()
        var state = form.state ?? .object([:])
        state = state.setting(.string("ada@example.com"), at: "/form/email")
        state = state.setting(.string("hunter22"), at: "/form/password")
        state = state.setting(.string("Ada Lovelace"), at: "/form/fullName")
        state = state.setting(.bool(true), at: "/form/acceptTerms")

        let rows = SubmissionSummary.rows(in: form, data: state, dataRoot: "", state: state)
        let byLabel = Dictionary(rows.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(rows.first?.label == "Email")
        #expect(byLabel["Email"] == "ada@example.com")
        #expect(byLabel["Password"] == "••••••••", "secrets are masked")
        #expect(byLabel["Full Name"] == "Ada Lovelace")
        #expect(byLabel["Account Type"] == "Personal", "pickers show the option label")
        #expect(byLabel["I agree to the Terms of Service"] == "Yes")
        #expect(byLabel["Company"] == nil, "hidden fields are skipped")

        let business = state.setting(.string("business"), at: "/form/accountType")
        #expect(SubmissionSummary.rows(in: form, data: business, dataRoot: "", state: business).contains { $0.label == "Company" && $0.value == "—" })
    }

    @Test func valuesComeFromTheSubmittedData() throws {
        let form = try #require(ExampleSpec.named("registration", kind: .form)).load()
        let state = (form.state ?? .object([:])).setting(.string("live@example.com"), at: "/form/email")
        // The submit action sent `{"$state": "/form"}` resolved earlier, without fullName.
        let data: JSONValue = ["email": "sent@example.com", "accountType": "business", "acceptTerms": true]

        let rows = SubmissionSummary.rows(in: form, data: data, dataRoot: "/form", state: state)
        #expect(rows.first == SubmissionSummary.Row(label: "Email", value: "sent@example.com"))
        #expect(!rows.contains { $0.label == "Full Name" }, "fields missing from the data are skipped")
        #expect(rows.contains(SubmissionSummary.Row(label: "Account Type", value: "Business")), "option labels come from the spec")
        #expect(rows.contains(SubmissionSummary.Row(label: "I agree to the Terms of Service", value: "Yes")))

        #expect(SubmissionSummary.submittedValue(at: "/form/email", in: ["form": ["email": "a"]], root: "") == "a")
        #expect(SubmissionSummary.submittedValue(at: "/form/email", in: ["email": "b"], root: "/form") == "b")
        #expect(SubmissionSummary.submittedValue(at: "/form/address/city", in: ["address": ["city": "c"]], root: "/form") == "c")
        #expect(SubmissionSummary.submittedValue(at: "/form", in: ["x": 1], root: "/form") == ["x": 1])
        #expect(SubmissionSummary.submittedValue(at: "/other/email", in: ["email": "b"], root: "/form") == nil, "outside the root")
        #expect(SubmissionSummary.submittedValue(at: "/formal/email", in: ["email": "b"], root: "/form") == nil, "prefix of a segment isn't the root")
        #expect(SubmissionSummary.submittedValue(at: "/form/email", in: "not an object", root: "/form") == nil)
    }

    /// Two fields with the same last segment: only the submitted subtree may supply values.
    @Test func submittedRootIsResolvedExactly() throws {
        let form = Spec(json: [
            "root": "form",
            "elements": [
                "form": ["type": "Form", "props": ["title": "Checkout"], "children": ["section"]],
                "section": ["type": "Section", "props": [:], "children": ["billing", "shipping", "nested", "submit"]],
                "billing": ["type": "TextField", "props": ["label": "Billing email", "value": ["$bindState": "/billing/email"]], "children": []],
                "shipping": ["type": "TextField", "props": ["label": "Shipping email", "value": ["$bindState": "/shipping/email"]], "children": []],
                "nested": ["type": "TextField", "props": ["label": "Shipping contact email", "value": ["$bindState": "/shipping/contact/email"]], "children": []],
                "submit": ["type": "Button", "props": ["label": "Send"], "children": [],
                           "on": ["press": ["action": "submit", "params": ["data": ["$state": "/shipping"]]]]],
            ],
        ])
        let state: JSONValue = [
            "billing": ["email": "billing@example.com"],
            "shipping": ["email": "shipping@example.com"],
        ]
        let data: JSONValue = ["email": "shipping@example.com"]
        #expect(SubmissionSummary.dataRoot(in: form, data: data, state: state) == "/shipping")

        let rows = SubmissionSummary.rows(in: form, data: data, dataRoot: "/shipping", state: state)
        #expect(rows == [SubmissionSummary.Row(label: "Shipping email", value: "shipping@example.com")],
                "billing wasn't submitted, and the absent nested email isn't filled from the top-level one")

        let fillable = FillablePDFMapper.spec(form: form, data: data, dataRoot: "/shipping", state: state)
        #expect(fillable.elements["f-billing"]?.props["value"] == "billing@example.com", "unsubmitted fields use live state")
        #expect(fillable.elements["f-shipping"]?.props["value"] == "shipping@example.com")
        #expect(fillable.elements["f-nested"]?.props["value"] == .null)

        // Through the controller, which detects the root from the submit binding.
        let controller = GenerationController(kind: .form, generator: MockGenerator(.chunks([]))) {
            GenerationOptions(model: "m", reasoningEffort: nil)
        }
        controller.load(Spec(json: form.json.setting(state, at: "/state")))
        controller.showSubmission(data)
        let summaryRows = try #require(controller.submission?.summary?.elements["fields"]?.props["rows"]?.arrayValue)
        #expect(summaryRows == [["Shipping email", "shipping@example.com"]])
    }

    @Test func templateLabelsDropTheTrailingValue() {
        let state: JSONValue = ["form": ["guests": 3, "name": "Ada"]]
        #expect(SubmissionSummary.label(["$template": "Guests (including you): ${/form/guests}"], state: state) == "Guests (including you)")
        #expect(SubmissionSummary.label(["$template": "Guests - ${/form/guests}"], state: state) == "Guests")
        #expect(SubmissionSummary.label(["$template": "${/form/guests} guests"], state: state) == "3 guests")
        #expect(SubmissionSummary.label(["$template": "${/form/guests}"], state: state) == "3")
        #expect(SubmissionSummary.label("Email", state: state) == "Email")
        #expect(SubmissionSummary.label(nil, state: state) == nil)
    }

    @Test func buildsARenderablePDFSpec() async throws {
        let form = try #require(ExampleSpec.named("event-rsvp", kind: .form)).load()
        let state = form.state ?? .object([:])
        let spec = SubmissionSummary.spec(form: form, data: state.value(at: "/form") ?? state, dataRoot: "/form", state: state, submittedAt: date)

        #expect(spec.root == "doc")
        #expect(spec.elements["doc"]?.props["title"] == .string("Summer Party RSVP"))
        #expect(spec.elements["page"]?.children.contains("page-number") == true)
        let rows = try #require(spec.elements["fields"]?.props["rows"]?.arrayValue)
        #expect(rows.count == SubmissionSummary.rows(in: form, data: state, dataRoot: "", state: state).count)
        #expect(rows.first == ["Name", "—"])
        #expect(rows.contains(["Guests (including you)", "1"]))
        #expect(SubmissionSummary.rows(in: form, data: state, dataRoot: "", state: state).first { $0.label == "Arrival Time" }?.value
            == SubmissionSummary.formattedDate("2025-07-12T18:00:00Z"))
        #expect(SubmissionSummary.formattedDate("2025-07-12")?.contains("2025") == true)
        #expect(SubmissionSummary.formattedDate("2025-07-12")?.contains("12") == true)
        #expect(SubmissionSummary.formattedDate("not a date") == nil)

        let bridge = try JSONRenderBridge()
        let report = try await bridge.validateSpec(spec, catalog: .pdf)
        #expect(report.valid, "\(report.issues.map(\.message))")

        let document = try await PDFRenderer().document(for: spec)
        let text = document.string ?? ""
        #expect(text.contains("Summer Party RSVP"))
        #expect(text.contains("Will you attend?"))
        #expect(text.contains("Page 1 of 1"))
        #expect(PDFExport(spec: spec).fileName == "Summer Party RSVP.pdf")
    }

    @Test func controllerAttachesTheSummary() throws {
        let controller = GenerationController(kind: .form, generator: MockGenerator(.chunks([]))) {
            GenerationOptions(model: "m", reasoningEffort: nil)
        }
        controller.load(try #require(ExampleSpec.named("registration", kind: .form)).load())
        controller.showSubmission(["email": "a@b.co"], validated: false)
        let submission = try #require(controller.submission)
        #expect(!submission.validated)
        #expect(submission.summary?.elements["doc"]?.props["title"] == .string("Create Account"))
    }
}
