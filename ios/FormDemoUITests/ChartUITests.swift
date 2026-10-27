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
    func testBarTapAndDrag() throws {
        let app = launch("chart-interactions")
        let title = app.staticTexts["Sales by region"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        screenshot("horizontal-bars")
        let plotCenter = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.69, dy: title.frame.maxY + 134))
        plotCenter.press(forDuration: 0.1, thenDragTo: plotCenter.withOffset(CGVector(dx: 15, dy: 0)))
        XCTAssertTrue(app.staticTexts["Tapped datum: Tap a mark, value 0"].exists)
        plotCenter.tap()
        XCTAssertTrue(app.staticTexts["Tapped datum: Eastern region and metropolitan districts, value 8"].waitForExistence(timeout: 3))
        screenshot("tapped-datum")
    }

    @MainActor
    func testLiveOrientationAndEmptyData() throws {
        let app = launch("chart-live")
        XCTAssertTrue(app.staticTexts["No data available"].exists)
        app.buttons["Load mixed data"].tap()
        XCTAssertTrue(app.staticTexts["Live sales"].waitForExistence(timeout: 3))
        app.switches["Horizontal bars"].tap()
        screenshot("live-horizontal")
        app.switches["Horizontal bars"].tap()
        app.buttons["Clear data"].tap()
        XCTAssertTrue(app.staticTexts["No data available"].waitForExistence(timeout: 3))
        app.buttons["Load mixed data"].tap()
        XCTAssertTrue(app.staticTexts["Live sales"].waitForExistence(timeout: 3))
        screenshot("live-vertical")
    }

    @MainActor
    func testVoiceOverReadsMarkLabelAndValue() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        let app = launch("chart-interactions")
        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }
        var found = false
        var markSpeech = ""
        for _ in 0..<30 {
            let speech = try voiceOver.moveForward().utterance
            print("VOICEOVER: \(speech)")
            if speech.contains("Western region and coastal communities") {
                found = true
                markSpeech = speech
                break
            }
        }
        XCTAssertTrue(found)
        XCTAssertTrue(markSpeech.contains("12"))
        XCTAssertTrue(markSpeech.contains("Button"))
        // XCTest synthesizes touch events directly, even with VoiceOver enabled. Its
        // doubleTap() therefore cannot verify activation of the focused AX element.
        screenshot("voiceover-mark")
    }

    @MainActor
    func testCompositionExample() throws {
        let app = launch("chart-composition")
        XCTAssertTrue(app.staticTexts["Sales mix"].waitForExistence(timeout: 3))
        screenshot("composition")
        let title = app.staticTexts["Sales mix"]
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: title.frame.maxY + 108))
        center.tap()
        XCTAssertTrue(app.staticTexts["Tapped datum: Tap a mark, value 0"].exists)
        center.withOffset(CGVector(dx: 75, dy: 0)).tap()
        XCTAssertTrue(app.staticTexts["Tapped datum: Western region and coastal communities, value 12"].waitForExistence(timeout: 3))
        screenshot("pie-tapped-datum")
    }
}
