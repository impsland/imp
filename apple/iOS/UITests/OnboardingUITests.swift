import XCTest

/// Walks the first run on a real device: three steps, Next each time, then the Imp's chat holds the prompt.
/// The app runs in the sandbox of Imps of its own (`-uiTestSandbox`) with a model service that already issued
/// its key (`-uiTestReseller`), so no network is needed. Runs in English.
@MainActor
final class OnboardingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func next(_ app: XCUIApplication) {
        let button = element(app, "onboarding.next")
        XCTAssertTrue(button.waitForExistence(timeout: 6), "no Next")
        XCTAssertTrue(button.isEnabled, "Next is ready")
        button.tap()
    }

    private func expectTitle(_ app: XCUIApplication, _ title: String) {
        let found = element(app, "onboarding.title")
        XCTAssertTrue(found.waitForExistence(timeout: 8), "no title for \(title)")
        XCTAssertEqual(found.label, title)
    }

    func testThreeStepsMakeAnImpThatHoldsThePrompt() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestSandbox", "-uiTestReset", "-uiTestReseller", "https://models.example/v1",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let wake = element(app, "start.wake")
        XCTAssertTrue(wake.waitForExistence(timeout: 8), "a fresh sandbox starts on the first screen")
        wake.tap()

        expectTitle(app, "Your Imp has a brain")
        XCTAssertTrue(app.staticTexts["Step 1 of 3"].exists)
        sleep(1)
        shot(app, "01-model")
        next(app)

        expectTitle(app, "Send your Imp to another screen")
        sleep(2)
        shot(app, "02-move")
        next(app)

        expectTitle(app, "Let your Imp set itself up")
        sleep(5)
        shot(app, "03-setup")
        next(app)

        let prompt = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Make 5 animations'")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 12), "the chat of the new Imp holds the prompt")
        XCTAssertFalse(element(app, "onboarding.next").exists, "the first run is over")
        shot(app, "04-chat")
    }
}
