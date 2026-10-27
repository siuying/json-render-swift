import XCTest

final class ChartUITests: XCTestCase {
    @MainActor
    private func launch(_ example: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-example", example]
        app.launch()
        XCTAssertTrue(app.staticTexts["Tapped datum: Tap a mark, value 0"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable && element.frame.midY < app.frame.height * 0.7 { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func assertSelection(_ text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let selection = app.staticTexts[text]
        for _ in 0..<6 where !selection.exists { app.swipeDown() }
        XCTAssertTrue(selection.waitForExistence(timeout: 3), app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "), file: file, line: line)
    }

    @MainActor
    func testBarTapAndDrag() throws {
        let app = launch("chart-interactions")
        let mark = app.buttons["chart-mark-1"]
        XCTAssertTrue(mark.waitForExistence(timeout: 5))
        XCTAssertEqual(mark.label, "Eastern region and metropolitan districts")
        screenshot("horizontal-labels")
        let center = mark.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: mark.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.7)))
        assertSelection("Tapped datum: Tap a mark, value 0", in: app)
        mark.tap()
        XCTAssertTrue(app.staticTexts["Tapped datum: Eastern region and metropolitan districts, value 8"].waitForExistence(timeout: 3))
        screenshot("tapped-datum")
    }

    @MainActor
    func testLiveOrientationAndEmptyData() throws {
        let app = launch("chart-live")
        XCTAssertTrue(app.staticTexts["No data available"].exists)
        app.buttons["Load mixed data"].tap()
        XCTAssertTrue(app.buttons["chart-mark-0"].waitForExistence(timeout: 3))
        app.switches["Horizontal bars"].tap()
        XCTAssertTrue(app.buttons["chart-mark-0"].waitForExistence(timeout: 3))
        screenshot("live-horizontal")
        app.buttons["chart-mark-0"].tap()
        assertSelection("Tapped datum: Western region and coastal communities, value 12", in: app)
        app.switches["Horizontal bars"].tap()
        app.buttons["Clear data"].tap()
        XCTAssertTrue(app.staticTexts["No data available"].waitForExistence(timeout: 3))
        app.buttons["Load mixed data"].tap()
        XCTAssertTrue(app.buttons["chart-mark-0"].waitForExistence(timeout: 3))
        screenshot("live-vertical")
    }

    @MainActor
    func testVoiceOverActivatesAMark() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        let app = launch("chart-interactions")
        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }
        var markSpeech = ""
        for _ in 0..<40 {
            let speech = try voiceOver.moveForward().utterance
            print("VOICEOVER: \(speech)")
            if speech.contains("Western region and coastal communities"), speech.contains("12"), speech.contains("Button") {
                markSpeech = speech
                break
            }
        }
        XCTAssertFalse(markSpeech.isEmpty)
        // Target the focused mark itself for the VoiceOver double tap. The former
        // app-centre gesture could focus and activate another mark. The hosted test
        // also invokes native AX activation directly and checks one dispatch.
        app.buttons["chart-mark-0"].doubleTap()
        assertSelection("Tapped datum: Western region and coastal communities, value 12", in: app)
        screenshot("voiceover-activation")
    }

    @MainActor
    func testCompositionExample() throws {
        let app = launch("chart-composition")
        let pie = app.images["pie-chart"]
        XCTAssertTrue(pie.waitForExistence(timeout: 5))
        screenshot("composition")
        pie.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertSelection("Tapped datum: Tap a mark, value 0", in: app)
        app.buttons["pie-mark-0"].tap()
        assertSelection("Tapped datum: Western region and coastal communities, value 12", in: app)
        screenshot("pie-tapped-datum")
        let line = app.buttons["line-mark-3"]
        reveal(line, in: app)
        line.tap()
        assertSelection("Tapped datum: Southern region, value 4", in: app)
        let area = app.buttons["area-mark-0"]
        reveal(area, in: app)
        area.tap()
        assertSelection("Tapped datum: Western region and coastal communities, value 12", in: app)
    }

    @MainActor
    func testMissingFormattedValuesAndOtherColor() throws {
        let app = launch("chart-data-options")
        let missing = app.buttons["chart-mark-1"]
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        XCTAssertEqual(missing.value as? String, "n/a")
        XCTAssertEqual(app.buttons["chart-mark-0"].value as? String, "HK$12.00")
        screenshot("n-a")
        missing.tap()
        XCTAssertTrue(app.staticTexts["Tapped datum: Unknown amount, value "].waitForExistence(timeout: 3))
        let other = app.buttons["other-mark-2"]
        reveal(other, in: app)
        XCTAssertEqual(other.label, "Other")
        XCTAssertEqual(other.value as? String, "3")
        screenshot("other-color")
        other.tap()
        assertSelection("Tapped datum: Other, value 3", in: app)
    }
}
