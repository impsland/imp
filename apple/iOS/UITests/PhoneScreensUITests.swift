import XCTest

/// Walks the iPhone's Imp settings and app settings on a real device, end to end, and keeps a screenshot of each
/// screen in the result bundle (`xcrun xcresulttool export attachments`). Runs in English.
///
/// The Brain is a model server on the developer's Mac (`IMP_TEST_BRAIN`, for example `http://Mac.local:8799/v1`):
/// any OpenAI-compatible server that lists a model and answers. Without it the Brain steps are skipped.
///
/// The app runs in a sandbox of Imps of its own (`-uiTestSandbox`): the phone owner's Imps are never shown, changed
/// or deleted. Each test starts from an empty sandbox (`-uiTestReset` on its first launch).
@MainActor
final class PhoneScreensUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var brainAddress: String? { ProcessInfo.processInfo.environment["IMP_TEST_BRAIN"].flatMap { $0.isEmpty ? nil : $0 } }

    private func launch(_ arguments: [String] = [], reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-uiTestSandbox"] + (reset ? ["-uiTestReset"] : [])
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = element(app, id)
        XCTAssertTrue(found.waitForExistence(timeout: 6), "no \(id)", file: file, line: line)
        found.tap()
    }

    /// Replaces what a field holds: the caret goes to the end, and everything before it is deleted.
    private func retype(_ field: XCUIElement, _ text: String) {
        // Past the end of the text but inside the field, so the caret lands at the end.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        field.typeText(text)
    }

    /// The first screen, with no Imp and nothing linked (it runs first, before the other tests hatch any).
    func testAStartScreen() {
        let app = launch(reset: true)
        let wake = element(app, "start.wake")
        guard wake.waitForExistence(timeout: 8) else { return }  // Not a fresh phone: there is a room instead.
        sleep(1)
        XCTAssertTrue(app.staticTexts["Meet Imp"].exists)
        XCTAssertFalse(app.buttons["Hatch"].exists, "waking makes the first Imp, there is no second way")
        shot(app, "00-start")
        tap(app, "start.link")
        XCTAssertTrue(element(app, "sheet.close").waitForExistence(timeout: 4), "Link a device opens its sheet")
        shot(app, "00-start-link")
        tap(app, "sheet.close")
    }

    func testImpSettingsEndToEnd() throws {
        // The first Imp: no Brain anywhere yet, so its Brain comes up at once.
        let first = launch(["-hatch"], reset: true)
        XCTAssertTrue(element(first, "brain.go").waitForExistence(timeout: 8), "a first Imp opens its Brain")
        XCTAssertFalse(first.staticTexts["Step 1 of 2"].exists)
        shot(first, "01-brain-asleep")

        if let address = brainAddress {
            retype(element(first, "brain.address"), address)
            // The model is a choice, not a field: blank until picked, and the button wakes with the first that chats.
            tap(first, "brain.model")
            let search = element(first, "models.search")
            XCTAssertTrue(search.waitForExistence(timeout: 4), "the models open with a search")
            XCTAssertTrue(first.buttons["mock-chat"].waitForExistence(timeout: 10), "the service's models are listed")
            shot(first, "02-models")
            search.tap()
            search.typeText("my-model")
            XCTAssertTrue(first.buttons["Use “my-model”"].waitForExistence(timeout: 3), "a name the service doesn't list can be used")
            shot(first, "02-models-search")
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "chat")
            first.buttons["mock-chat"].tap()
            XCTAssertFalse(search.waitForExistence(timeout: 1) && search.isHittable, "a pick closes the list")
            shot(first, "02-brain-picked")
            tap(first, "brain.go")
            // It worked: the sheet goes by itself, and the Imp that just woke comes up in its chat.
            let gone = NSPredicate(format: "exists == false")
            expectation(for: gone, evaluatedWith: element(first, "brain.go"))
            waitForExpectations(timeout: 20)
            sleep(1)
            shot(first, "03-woke-chat")
            first.terminate()
        }

        // Its settings again, from the start.
        let app = launch(["-editImp"])
        XCTAssertTrue(element(app, "imp.look").waitForExistence(timeout: 8))
        shot(app, "04-hub")

        tap(app, "imp.personality")
        XCTAssertTrue(element(app, "personality.name").waitForExistence(timeout: 4), "the name is in Personality")
        shot(app, "05-personality")
        tap(app, "sheet.back")

        tap(app, "imp.look")
        let size = app.sliders["look.size"]
        XCTAssertTrue(size.waitForExistence(timeout: 4))
        // The preview takes a new colour and a new character at once.
        let preview = element(app, "look.preview")
        XCTAssertTrue(preview.exists)
        for pick in ["look.swatch.5", "emoji.wide", "look.swatch.2", "emoji.sweet"] {
            let before = preview.screenshot().image
            sleep(1)
            let still = preview.screenshot().image
            tap(app, pick)
            sleep(1)
            let after = preview.screenshot().image
            let idle = Self.changed(before, still), picked = Self.changed(still, after)
            XCTAssertGreaterThan(picked, idle * 3 + 200, "the preview shows \(pick) (changed \(picked) px, \(idle) px at rest)")
        }
        shot(app, "06-look-picked")
        size.adjust(toNormalizedSliderPosition: 0)
        shot(app, "06-look-small")
        app.swipeUp()
        shot(app, "07-look-character")
        tap(app, "sheet.back")
        // Kept at once: the hub shows the new size.
        XCTAssertTrue(app.staticTexts["75%"].waitForExistence(timeout: 4), "the size was kept")

        // The built-in tool is behind the wand in Personality. Tools holds only MCP servers.
        tap(app, "imp.personality")
        tap(app, "agent.tools")
        let message = element(app, "tools.imp_message")
        XCTAssertTrue(message.waitForExistence(timeout: 4), "Message Imps has a switch")
        XCTAssertFalse(element(app, "tools.imp_play_animations").exists, "a pocket Imp plays no animations")
        shot(app, "08-agent-tools")
        tap(app, "agent.done")
        tap(app, "sheet.back")
        tap(app, "imp.tools")
        XCTAssertFalse(element(app, "tools.imp_message").exists, "Tools lists no built-in tools")
        shot(app, "08-tools")
        tap(app, "sheet.back")

        // Closing keeps everything: there is no Save.
        tap(app, "sheet.close")
        sleep(1)
        shot(app, "09-room-small-imp")

        // + hatches the next Imp at once. With a Brain to share, no sheet comes up.
        tap(app, "stage.new")
        sleep(2)
        if brainAddress != nil {
            XCTAssertFalse(element(app, "brain.go").exists, "a second Imp starts with the Brain")
        }
        shot(app, "10-room-two-imps")
        if element(app, "sheet.close").exists { tap(app, "sheet.close") }

        tap(app, "stage.settings")
        XCTAssertTrue(element(app, "section.brains").waitForExistence(timeout: 4))
        XCTAssertFalse(element(app, "section.sharing").exists, "the phone has no Sharing")
        shot(app, "11-settings-brains")
        tap(app, "section.devices")
        sleep(1)
        shot(app, "12-settings-devices")
        tap(app, "section.app")
        sleep(1)
        shot(app, "13-settings-app")
        app.swipeUp()
        XCTAssertTrue(element(app, "app.haptics").waitForExistence(timeout: 3), "haptics can be switched off")
        shot(app, "14-settings-app-2")
        // Nothing of the test stays behind, not even in its sandbox.
        launch(reset: true).terminate()
    }

    /// Picking several Imps: touch and hold opens the menu, Select starts it with that Imp picked, a tap on another
    /// picks it, and the bars show the count and what can be done.
    func testPickingSeveralImps() {
        let app = launch(["-hatchThree"], reset: true)
        // The room's Imps are elements with the Imp's name as the label and the button trait.
        let imps = app.buttons.matching(NSPredicate(format: "identifier == '' AND label != ''"))
        let room = app.windows.firstMatch
        XCTAssertTrue(element(app, "stage.settings").waitForExistence(timeout: 10), "the room is up")
        sleep(2)
        shot(app, "pick-0-room")

        // Imps float, so find one by its place on the screen: the first element that is an Imp (not a bar button).
        let candidates = (0..<imps.count).map { imps.element(boundBy: $0) }
            .filter { $0.frame.width > 40 && $0.frame.minY > 120 && $0.frame.height > 40 }
        XCTAssertGreaterThanOrEqual(candidates.count, 2, "two Imps to pick from")
        let first = candidates[0], second = candidates[1]
        first.press(forDuration: 0.8)
        // A confirmation dialog can list a button twice in the tree (the popover and its copy): take the first.
        let select = app.buttons.matching(identifier: "imp.select").firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 4), "the menu offers Select")
        shot(app, "pick-1-menu")
        select.tap()

        XCTAssertTrue(element(app, "pick.cancel").waitForExistence(timeout: 4), "Cancel is in the top bar")
        XCTAssertEqual(element(app, "pick.title").label, "1 selected")
        XCTAssertTrue(element(app, "pick.hide").exists, "Hide is in the bottom bar")
        XCTAssertTrue(element(app, "pick.goodbye").exists, "Goodbye is offered for Imps hatched here")
        XCTAssertFalse(element(app, "pick.home").exists, "no visitor is picked, so no Send home")

        // A tap now picks, it does not open a chat.
        second.tap()
        XCTAssertTrue(NSPredicate(format: "label == '2 selected'").evaluate(with: element(app, "pick.title")), "a tap picks a second Imp")
        XCTAssertFalse(element(app, "sheet.close").exists, "a tap while picking opens no chat")
        shot(app, "pick-2-two")

        tap(app, "pick.all")
        XCTAssertTrue(NSPredicate(format: "label == '3 selected'").evaluate(with: element(app, "pick.title")), "Select All picks all three")

        tap(app, "pick.goodbye")
        XCTAssertTrue(app.staticTexts["Say goodbye to 3 Imps?"].waitForExistence(timeout: 4), "Goodbye asks once for all")
        shot(app, "pick-3-goodbye")
        // Newer iPhones show this dialog as a popover with no Cancel button: a tap outside it keeps them.
        let keep = app.buttons["Keep them"]
        if keep.exists { keep.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
        XCTAssertFalse(app.staticTexts["Say goodbye to 3 Imps?"].waitForExistence(timeout: 2), "the Imps are kept")

        tap(app, "pick.cancel")
        XCTAssertFalse(element(app, "pick.cancel").waitForExistence(timeout: 2), "Cancel leaves picking")
        XCTAssertTrue(element(app, "stage.settings").exists, "the room's own top bar is back")
        _ = room
    }

    /// Embers to its results card: play a few seconds, close the round (which ends it with what it scored), and
    /// check the card's three actions sit in one row, then play again and back out with Done.
    func testEmbersResultsCard() {
        let app = launch(["-hatchThree"], reset: true)
        let play = app.buttons["Play Embers"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "the way into Embers")
        play.tap()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 4) { skip.tap() }
        sleep(4)  // The countdown.
        sleep(3)  // A few seconds of play.
        app.buttons["Close"].tap()
        let again = app.buttons["Again"], done = app.buttons["Done"], howTo = app.buttons["How to play"]
        XCTAssertTrue(again.waitForExistence(timeout: 6), "the results card is up")
        sleep(1)
        shot(app, "embers-results")
        XCTAssertEqual(again.frame.minY, done.frame.minY, accuracy: 1, "Done and Again share a row")
        XCTAssertEqual(again.frame.minY, howTo.frame.minY, accuracy: 1, "How to play shares it too")
        XCTAssertEqual(again.frame.width, done.frame.width, accuracy: 1, "equal widths")
        XCTAssertEqual(again.frame.width, howTo.frame.width, accuracy: 1, "equal widths")
        done.tap()
        XCTAssertFalse(again.waitForExistence(timeout: 2), "Done leaves the game")
    }
}


extension PhoneScreensUITests {
    /// How many pixels of two same-sized pictures differ clearly (by more than a quarter in a channel).
    static func changed(_ a: UIImage, _ b: UIImage) -> Int {
        guard let x = pixels(a), let y = pixels(b), x.count == y.count else { return Int.max }
        var n = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            if abs(Int(x[i]) - Int(y[i])) > 64 || abs(Int(x[i + 1]) - Int(y[i + 1])) > 64 || abs(Int(x[i + 2]) - Int(y[i + 2])) > 64 { n += 1 }
        }
        return n
    }

    private static func pixels(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                          bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? data : nil
    }
}

private extension XCUIElement {
    func tapIfThere() { if exists { tap() } }
}
