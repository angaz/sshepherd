import XCTest

/// Actual OS-dispatched taps and typing through the app, native Ghostty and an isolated stock sshd.
final class TerminalEndToEndTests: XCTestCase {
    @MainActor func testRealServerTapFingerprintTypingInterruptAndReconnect() throws {
        let app = XCUIApplication(bundleIdentifier: "io.angaz.sshepherd.ios")
        app.launchArguments = ["--show-servers"]
        app.launch()
        defer { app.terminate() }
        let server = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated UI fixture")).firstMatch
        guard server.waitForExistence(timeout: 10) else { XCTFail("Isolated server card is missing"); return }
        // The fixture writes its independently generated public fingerprint into this test-only card.
        let fingerprintRange = try XCTUnwrap(server.label.range(of: "SHA256:[A-Za-z0-9+/]+", options: .regularExpression))
        let fingerprint = String(server.label[fingerprintRange])
        server.tap()
        let consent = app.alerts["Verify server fingerprint"]
        guard consent.waitForExistence(timeout: 8) else { XCTFail("Host consent dialog never appeared"); return }
        guard consent.staticTexts.allElementsBoundByIndex.contains(where: { $0.label.contains(fingerprint) }) else {
            XCTFail("Never approve an unexpected host key"); return
        }
        // A human needs time to compare the fingerprint; this must not hit the network's ten-second timeout.
        Thread.sleep(forTimeInterval: 12)
        consent.buttons["Trust and authenticate"].tap()
        XCTAssertTrue(app.navigationBars["Agents & Workspaces"].waitForExistence(timeout: 12),
                      "No remembered Herdr view must open the native picker, not invent a session")
        app.buttons["Done"].tap()
        let keyboard = app.buttons["Show keyboard"].firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        expectEnabled(keyboard)
        keyboard.tap()
        let terminal = app.descendants(matching: .any).matching(identifier: "Terminal contents").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        expectText("UI_FIXTURE_READY", in: terminal)
        XCTAssertFalse(app.buttons["Close"].exists, "Terminal must not be presented as a dismissible sheet")
        XCTAssertFalse(app.buttons["SSH key"].exists, "Sign-in management belongs in the terminal menu")
        XCTAssertEqual(app.buttons.matching(identifier: "Hide keyboard").count, 1, "Only the bottom keyboard control should remain")
        let navigation = app.navigationBars.firstMatch
        let browser = navigation.buttons["Agents | Workspaces"]
        let menu = navigation.buttons["Terminal menu"]
        XCTAssertTrue(browser.exists, "The single native browser button belongs in the top bar")
        XCTAssertTrue(browser.isEnabled)
        XCTAssertTrue(menu.exists, "Server switching must remain reachable from the top menu")
        XCTAssertFalse(app.toolbars["Terminal actions"].buttons["Servers"].exists)
        XCTAssertFalse(app.toolbars["Terminal actions"].buttons["Workspaces"].exists)
        let beforeBrowse = terminal.value as? String
        browser.tap()
        XCTAssertTrue(app.navigationBars["Agents & Workspaces"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertEqual(terminal.value as? String, beforeBrowse, "Opening the browser must not send terminal navigation keys")
        app.buttons["Show keyboard"].tap()
        // The fixture disables PTY echo: seeing this marker proves remote execution, not local echo.
        app.typeText("printf 'UI_REMOTE_PROOF\\n'\n")
        expectText("UI_REMOTE_PROOF", in: terminal)
        XCTAssertTrue(app.buttons["Tab"].exists)
        app.typeText("THIS_LINE_MUST_BE_ERASED")
        app.buttons["Clear line"].tap()
        app.typeText("printf 'UI_CLEAR_LINE_PROOF\\n'\n")
        expectText("UI_CLEAR_LINE_PROOF", in: terminal)
        app.typeText("sleep 30\n")
        app.buttons["Ctrl-C"].tap()
        app.typeText("printf 'UI_INTERRUPT_PROOF\\n'\n")
        expectText("UI_INTERRUPT_PROOF", in: terminal)
        app.buttons["Show extra keys"].tap()
        XCTAssertTrue(app.buttons["←"].waitForExistence(timeout: 3))
        XCTAssertTrue(menu.exists)
        app.buttons["Hide extra keys"].tap()
        XCTAssertTrue(menu.exists)
        let toolbar = app.toolbars["Terminal actions"]
        XCTAssertTrue(toolbar.exists, "Primary actions must use a native toolbar")
        XCTAssertEqual(toolbar.frame.maxY, app.frame.maxY, accuracy: 1,
                       "Toolbar must fill the bottom edge without an extra empty band")
        XCTAssertLessThanOrEqual(toolbar.frame.height, 90, "Native styling must not create an oversized action area")
        for label in ["Tab", "Ctrl-C", "Clear line", "Show extra keys", "Show keyboard"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX, "\(label) must not be clipped off the left edge")
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX, "\(label) must not be clipped off the right edge")
        }
        XCTAssertGreaterThan(terminal.frame.height, app.frame.height * 0.75,
                             "Collapsed chrome must leave most of the display for terminal content")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Native top navigation and compact terminal actions"
        attachment.lifetime = .keepAlways
        add(attachment)
        menu.tap()
        app.buttons["Detach"].tap()
        app.buttons["Terminal menu"].tap()
        let reconnect = app.buttons["Reconnect"].firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        XCTAssertTrue(app.navigationBars["Agents & Workspaces"].waitForExistence(timeout: 12))
        app.buttons["Done"].tap()
        let showKeyboard = app.buttons["Show keyboard"].firstMatch
        XCTAssertTrue(showKeyboard.waitForExistence(timeout: 3))
        expectEnabled(showKeyboard)
        showKeyboard.tap()
        app.typeText("printf 'UI_REATTACH_PROOF\\n'\n")
        expectText("UI_REATTACH_PROOF", in: terminal)
        XCTAssertFalse(app.alerts["Verify server fingerprint"].exists, "Saved host trust must survive reconnect")
        menu.tap()
        app.buttons["Switch server"].tap()
        XCTAssertTrue(server.waitForExistence(timeout: 5), "Switch server in the native top menu must return to inventory")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.navigationBars["Agents & Workspaces"].waitForExistence(timeout: 12),
                      "A cold launch must automatically reconnect the remembered server and fall back when no Herdr view exists")
        XCTAssertFalse(app.alerts["Verify server fingerprint"].exists, "Automatic reconnect must retain host trust")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.buttons["Agents | Workspaces"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Isolated UI fixture")).firstMatch.exists,
                       "Cold launch must not ask the user to choose the server again")
        let resumeKeyboard = app.buttons["Show keyboard"].firstMatch
        expectEnabled(resumeKeyboard)
        resumeKeyboard.tap()
        app.typeText("printf 'UI_AUTO_RESUME_PROOF\\n'\n")
        expectText("UI_AUTO_RESUME_PROOF", in: app.descendants(matching: .any).matching(identifier: "Terminal contents").firstMatch)
    }
    @MainActor private func expectEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "Connection never became interactive")
    }
    @MainActor private func expectText(_ marker: String, in element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", marker), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "Remote marker did not reach the actual terminal renderer: \(marker)")
    }
}
