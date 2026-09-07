import XCTest

/// Manual release evidence for the complete iOS runtime path. Run this scheme on
/// a provisioned physical device; it downloads a pinned model, exercises the
/// bundled worker and native addons, verifies streamed output, and unloads cleanly.
@MainActor
final class QVACChatPhysicalDeviceTests: XCTestCase {
    private let app = XCUIApplication()

    @MainActor
    func testLoadStreamAndUnloadOnPhysicalDevice() async throws {
        XCTAssertNil(
            ProcessInfo.processInfo.environment["SIMULATOR_UDID"],
            "This release test must run on a physical iOS device"
        )

        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "QVACChat did not reach the foreground on the physical device"
        )
        attachScreenshot(named: "01-launched")

        let loadButton = app.buttons["Load"]
        XCTAssertTrue(loadButton.waitForExistence(timeout: 30), "Load button is missing")
        XCTAssertTrue(scrollToHittable(loadButton, direction: .down), "Load button is not hittable")
        loadButton.tap()

        let loadOutcome = app.staticTexts
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
                "Loaded:",
                "Error:"
            ))
            .firstMatch
        XCTAssertTrue(
            loadOutcome.waitForExistence(timeout: 600),
            "Model load produced no terminal UI state. Visible labels: \(visibleLabels())"
        )
        attachScreenshot(named: "02-model-load-outcome")
        XCTAssertTrue(
            loadOutcome.label.hasPrefix("Loaded:"),
            "Model failed to load: \(loadOutcome.label)"
        )

        let runButton = app.buttons["Run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 30), "Run button is missing")
        XCTAssertTrue(scrollToHittable(runButton, direction: .up), "Run button is not hittable")
        runButton.tap()

        let completionOutcome = app.staticTexts
            .matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "Done",
                "Error:"
            ))
            .firstMatch
        XCTAssertTrue(
            completionOutcome.waitForExistence(timeout: 180),
            "Completion produced no terminal UI state. Visible labels: \(visibleLabels())"
        )
        attachScreenshot(named: "03-completion-outcome")
        XCTAssertEqual(
            completionOutcome.label,
            "Done",
            "Streaming completion failed: \(completionOutcome.label)"
        )
        XCTAssertFalse(
            app.staticTexts["(no output yet)"].exists,
            "Completion finished without observable streamed output"
        )

        let unloadButton = app.buttons["Unload"]
        XCTAssertTrue(unloadButton.waitForExistence(timeout: 30), "Unload button is missing")
        XCTAssertTrue(
            scrollToHittable(unloadButton, direction: .down),
            "Unload button is not hittable"
        )
        unloadButton.tap()

        let unloadedStatus = app.staticTexts["Unloaded"]
        XCTAssertTrue(
            unloadedStatus.waitForExistence(timeout: 30),
            "Model failed to unload. Visible labels: \(visibleLabels())"
        )
        attachScreenshot(named: "04-unloaded")
    }

    private enum ScrollDirection {
        case up
        case down
    }

    @discardableResult
    @MainActor
    private func scrollToHittable(
        _ element: XCUIElement,
        direction: ScrollDirection
    ) -> Bool {
        for _ in 0..<8 {
            if element.isHittable { return true }
            switch direction {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
        }
        return element.isHittable
    }

    @MainActor
    private func visibleLabels() -> [String] {
        app.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .filter { !$0.isEmpty }
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
