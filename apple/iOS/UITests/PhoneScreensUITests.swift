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
    /// Devices › Link a device: Copy says it copied, and the code stays the same when Devices opens again or the
    /// app comes back from the background, so a link copied before still links.
    func testLinkCodeStaysTheSameAndCopySaysSo() {
        // Showing the code asks for the Local Network once: allowed, as a person would.
        addUIInterruptionMonitor(withDescription: "Local Network") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        let app = launch(["-openDevices"])
        let show = app.buttons["Show code"]
        if show.waitForExistence(timeout: 6) { show.tap() }
        app.tap()                                              // lets the interruption monitor see the prompt
        let code = element(app, "link.code")
        XCTAssertTrue(code.waitForExistence(timeout: 30), "the code shows")
        let first = Self.invite(code)
        XCTAssertFalse(first.isEmpty, "the code's link is its value (Debug)")
        let copy = app.buttons["Copy"]
        copy.tap()
        XCTAssertEqual(copy.value as? String, "Done", "Copy shows it copied")
        shot(app, "Devices code copied")

        // Devices closed and opened again: no Show code to tap, and the same code.
        if app.buttons["Close"].firstMatch.exists { app.buttons["Close"].firstMatch.tap() }
        app.terminate()
        let again = launch(["-openDevices"])
        let shown = element(again, "link.code")
        XCTAssertTrue(shown.waitForExistence(timeout: 30), "a code asked for once shows at once")
        XCTAssertEqual(Self.invite(shown), first, "the same code after Devices opened again")

        // To the background and back, as when the link is pasted in Safari.
        XCUIDevice.shared.press(.home)
        sleep(3)
        again.activate()
        XCTAssertTrue(shown.waitForExistence(timeout: 30))
        XCTAssertEqual(Self.invite(shown), first, "the same code after the app was in the background")
        shot(again, "Devices code after background")
    }

    /// The invite key in a code's link (its routes may change: the key is what a copied link needs).
    private static func invite(_ code: XCUIElement) -> String {
        guard let link = code.value as? String, let parts = URLComponents(string: link) else { return "" }
        return parts.queryItems?.first { $0.name == "inv" }?.value ?? ""
    }

    /// Opt-in (`TEST_RUNNER_IMP_TEST_WEB=1`), with the web page on the Mac: the link copied here joins a web page
    /// named ImpTest while Imp is in the background, as when it is pasted in Safari. The test prints the link
    /// (`IMP_LINK_CODE`) for the Mac's script, which joins with it and forgets the iPhone again afterwards.
    func testCopiedCodeLinksAWebPageWhileInTheBackground() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IMP_TEST_WEB"] == "1", "needs the web page on the Mac")
        addUIInterruptionMonitor(withDescription: "Local Network") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        let app = launch(["-openDevices"])
        let show = app.buttons["Show code"]
        if show.waitForExistence(timeout: 6) { show.tap() }
        let code = element(app, "link.code")
        XCTAssertTrue(code.waitForExistence(timeout: 30), "the code shows")
        let link = code.value as? String ?? ""
        XCTAssertTrue(link.contains("hop="), "the code carries a Hop, which a web page needs: set one in Devices")
        app.buttons["Copy"].tap()
        print("IMP_LINK_CODE \(link)")
        // Pasted elsewhere while Imp is in the background.
        XCUIDevice.shared.press(.home)
        sleep(25)
        app.activate()
        XCTAssertTrue(app.staticTexts["ImpTest"].waitForExistence(timeout: 90), "the web page linked")
        shot(app, "Linked with the web page")
        sleep(5)
    }

    /// The + menu in a chat, a recorded sound as a chip with a remove button, and Send turned on by the file alone.
    /// The Imp's Brain is pretend: nothing is sent.
    func testChatAttachmentsRecordASound() {
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let app = launch(["-openPocketChat"], reset: true)
        let add = element(app, "chat.add")
        XCTAssertTrue(add.waitForExistence(timeout: 20), "the + button in the chat")
        let send = element(app, "chat.send")
        XCTAssertFalse(send.isEnabled, "Send waits for words or files")
        sleep(2)  // The sheet settles.
        add.tap()
        for _ in 0..<3 where !app.buttons["Photo or video"].waitForExistence(timeout: 3) {
            allowMicrophone()
            add.tap()
        }
        XCTAssertTrue(app.buttons["Photo or video"].waitForExistence(timeout: 4), "Photo or video in the menu")
        XCTAssertTrue(app.buttons["Record a sound"].exists, "Record a sound in the menu")
        XCTAssertTrue(app.buttons["Choose a file"].exists, "Choose a file in the menu")
        shot(app, "chat-add-menu")
        app.buttons["Record a sound"].tap()
        let done = element(app, "chat.recording.done")
        // An interaction lets the microphone prompt, if one comes, reach the interruption monitor.
        for _ in 0..<4 where !done.waitForExistence(timeout: 2) {
            allowMicrophone()
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
        }
        shot(app, "chat-after-record")
        XCTAssertTrue(done.exists, "the recording row")
        sleep(2)
        shot(app, "chat-recording")
        done.tap()
        let chip = element(app, "chat.chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 6), "the sound is a chip above the box")
        XCTAssertTrue(send.isEnabled, "a file alone is a message")
        shot(app, "chat-sound-chip")
        element(app, "chat.chip.remove").tap()
        XCTAssertFalse(chip.waitForExistence(timeout: 2), "the chip's remove button takes it out")
    }

    /// Answers the system's microphone prompt, when it is up.
    private func allowMicrophone() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap() }
    }

    /// The playful camera: the Imps peek in from the edges, one is dragged to the middle, the shot, Retake, then Send.
    func testPlayfulCamera() {
        addUIInterruptionMonitor(withDescription: "Camera") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let app = launch(["-hatchThree", "-openCamera"], reset: true)
        let shutter = element(app, "camera.shutter")
        for _ in 0..<4 where !shutter.waitForExistence(timeout: 4) {
            app.tap()
            allowSystemPrompt()
        }
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), "the shutter")
        sleep(2)  // The Imps spring in.
        shot(app, "camera-edges")
        let imps = app.descendants(matching: .any).matching(identifier: "camera.imp")
        XCTAssertGreaterThan(imps.count, 0, "Imps in the camera")
        // Grab the Imp that shows most, by the middle of its visible part (not off the screen's edge, where the system listens).
        let window = app.windows.firstMatch.frame
        var best: (CGRect, CGFloat)?
        for i in 0..<imps.count {
            let visible = imps.element(boundBy: i).frame.intersection(window)
            if !visible.isNull, best == nil || visible.width * visible.height > best!.1 { best = (visible, visible.width * visible.height) }
        }
        let grab = best!.0
        let from = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: grab.midX < 40 ? 40 : min(grab.midX, window.width - 40), dy: grab.midY))
        from.press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        sleep(1)
        shot(app, "camera-dragged")
        shutter.tap()
        XCTAssertTrue(element(app, "camera.retake").waitForExistence(timeout: 10), "Retake")
        XCTAssertTrue(element(app, "camera.save").exists, "Save")
        XCTAssertTrue(element(app, "camera.send").exists, "Send")
        shot(app, "camera-preview")
        tap(app, "camera.retake")
        XCTAssertTrue(shutter.waitForExistence(timeout: 6), "back to the camera")
        shutter.tap()
        tap(app, "camera.send")
        XCTAssertTrue(shutter.waitForNonExistence(timeout: 6), "Send closes the camera")
    }

    /// + menu -> Take a photo opens the playful camera, not the system one, and Send brings the photo back as a chip.
    func testChatTakeAPhotoOpensTheImpCamera() {
        addUIInterruptionMonitor(withDescription: "Camera") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let app = launch(["-openPocketChat"], reset: true)
        let add = element(app, "chat.add")
        XCTAssertTrue(add.waitForExistence(timeout: 20), "the + button in the chat")
        sleep(2)
        add.tap()
        tap(app, "chat.add.camera")
        let shutter = element(app, "camera.shutter")
        for _ in 0..<4 where !shutter.waitForExistence(timeout: 4) {
            app.tap()
            allowSystemPrompt()
        }
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), "the Imp camera, not the system one")
        sleep(2)
        shot(app, "camera-from-chat")
        shutter.tap()
        tap(app, "camera.send")
        XCTAssertTrue(element(app, "chat.chip").waitForExistence(timeout: 8), "the photo is a chip in the draft")
        shot(app, "camera-chat-chip")
    }

    private func allowSystemPrompt() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap() }
    }

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

    /// A page an Imp drew behind the room (moving, far larger than the screen) leaves the room the screen's size: the
    /// status pill stays at the top, and in Embers the close (X) is in the top-trailing corner and closes the round.
    func testBackgroundKeepsTheRoomOnScreen() {
        let app = launch(["-hatchThree", "-uiTestBackground"], reset: true)
        let screen = app.windows.firstMatch.frame
        let play = app.buttons["Play Embers"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "the way into Embers")
        sleep(4)  // The page loads and is looked at.
        shot(app, "background-room")
        XCTAssertTrue(screen.contains(play.frame), "Play Embers on screen: \(play.frame) in \(screen)")
        play.tap()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 4) { skip.tap() }
        sleep(5)
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4), "the close (X)")
        shot(app, "background-embers")
        XCTAssertTrue(screen.contains(close.frame), "the close on screen: \(close.frame) in \(screen)")
        XCTAssertGreaterThan(close.frame.midX, screen.midX, "in the trailing half")
        XCTAssertLessThan(close.frame.midY, screen.height / 4, "near the top")
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 6), "closing ends the round")
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
