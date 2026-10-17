#if os(iOS)
import UIKit
import XCTest
@testable import AppUI

@MainActor private final class InteractionSession: TerminalSession {
    nonisolated let state: ConnectionState = .connected
    enum Event: Equatable { case bytes(Data), key(TerminalKeyEvent), mouse(Int, Int, Int, TerminalMouseAction) }
    var events: [Event] = []
    var sizes: [(Int, Int)] = []
    func connect() async throws {}
    func detach() async {}
    func send(_ bytes: Data) async { events.append(.bytes(bytes)) }
    func sendKey(_ event: TerminalKeyEvent) async { events.append(.key(event)) }
    func sendMouse(_ event: TerminalMouseEvent) async { events.append(.mouse(event.column, event.row, event.button, event.action)) }
    func resize(columns: Int, rows: Int) async { sizes.append((columns, rows)) }
}

private actor InteractionFrames: TerminalFrameProvider {
    let data: Data
    var concurrent = 0
    var maximumConcurrent = 0
    init(_ data: Data) { self.data = data }
    func frameSnapshot() async throws -> Data {
        concurrent += 1; maximumConcurrent = max(maximumConcurrent, concurrent)
        try await Task.sleep(for: .milliseconds(5))
        concurrent -= 1
        return data
    }
}

@MainActor private final class MainActorTerminal: Sendable {
    let view: TerminalView
    init(_ view: TerminalView) { self.view = view }
    func refresh() async { await view.refresh() }
}

@MainActor private final class TerminalTapProbe: UITapGestureRecognizer {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
}

final class TerminalInteractionTests: XCTestCase {
    @MainActor func testToolbarTabClearLineAndInterruptSendDistinctKeys() async throws {
        let session = InteractionSession()
        let (window, view, _) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        view.startInput()
        try press(barItem(in: view, label: "Tab"))
        try press(barItem(in: view, label: "Clear line"))
        try press(barItem(in: view, label: "Ctrl-C"))
        try await wait { session.events.count == 3 }
        XCTAssertEqual(session.events, [.key(.init(.tab)),
            .key(.init(.character("u"), modifiers: .control)),
            .key(.init(.character("c"), modifiers: .control))])
    }

    @MainActor func testBottomToolbarContainsOnlyTerminalActions() throws {
        let session = InteractionSession()
        let (window, view, _) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        view.startInput()
        view.setKeyboardVisible(false)
        XCTAssertThrowsError(try barItem(in: view, label: "Workspaces"))
        XCTAssertThrowsError(try barItem(in: view, label: "Servers"))
        for label in ["Tab", "Ctrl-C", "Clear line", "Show extra keys", "Show keyboard"] {
            XCTAssertTrue(try barItem(in: view, label: label).isEnabled)
        }
        view.pauseInput()
        XCTAssertTrue(try barItem(in: view, label: "Show extra keys").isEnabled)
        XCTAssertFalse(try barItem(in: view, label: "Tab").isEnabled)
    }

    @MainActor func testBottomButtonSurfacesReachScreenEdgeAndLabelsAvoidHomeGesture() throws {
        let session = InteractionSession()
        let (window, view, _) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        let controller = try XCTUnwrap(window.rootViewController)
        controller.additionalSafeAreaInsets.bottom = 34
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        view.frame = controller.view.bounds
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(view.safeAreaInsets.bottom, 34)
        let background = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "Terminal controls background" })
        let controls = try XCTUnwrap(view.subviews.first { $0 is TerminalControlsView })
        XCTAssertEqual(background.frame.maxY, view.bounds.maxY)
        XCTAssertEqual(background.frame.minY, controls.frame.minY)
        XCTAssertEqual(controls.frame.maxY, view.bounds.maxY)
        XCTAssertEqual(controls.frame.height, TerminalControlsView.primaryHeight + view.safeAreaInsets.bottom)
        let toolbar = try XCTUnwrap(controls.subviews.compactMap { $0 as? UIToolbar }.first)
        XCTAssertEqual(toolbar.convert(toolbar.bounds, to: view).maxY, view.bounds.maxY)
        XCTAssertEqual(toolbar.accessibilityIdentifier, "Terminal actions")
        XCTAssertEqual(toolbar.items?.filter { $0.action != nil }.count, 5)
        XCTAssertNotNil(try barItem(in: view, label: "Tab").image)
        XCTAssertNotNil(try barItem(in: view, label: "Ctrl-C").image)
        XCTAssertFalse(background.isUserInteractionEnabled)
    }

    @MainActor func testUIKitPasteRequestsConfirmationAndNeverBypassesTextLimits() async throws {
        let session = InteractionSession()
        let (window, view, input) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        var requests = 0
        view.pasteRequested = { requests += 1 }
        view.startInput()
        XCTAssertTrue(input.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        input.paste(nil)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(session.events.isEmpty, "OS paste must open confirmation, never directly send clipboard contents")
        view.confirmPaste("not confirmed", confirmed: false)
        view.confirmPaste(String(repeating: "x", count: 60_001), confirmed: true)
        view.confirmPaste("unsafe\u{1b}[31m", confirmed: true)
        XCTAssertTrue(session.events.isEmpty)
        view.confirmPaste("safe\ntext\t", confirmed: true)
        try await wait { session.events.count == 1 }
        XCTAssertEqual(session.events, [.bytes(Data("safe\ntext\t".utf8))])
        view.pauseInput()
        input.paste(nil)
        XCTAssertEqual(requests, 1, "Disconnected input must not request or replay a paste")
    }

    @MainActor func testPersistentControlsConsumeControlOnceAndAreNotInterceptedByTerminalGestures() async throws {
        let session = InteractionSession()
        let (window, view, input) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        view.startInput()
        var expansions: [Bool] = []
        view.controlsExpansionChanged = { expansions.append($0) }
        let more = try barItem(in: view, label: "Show extra keys")
        let prefix = try XCTUnwrap(buttons(in: view).first { $0.currentTitle == "Prefix" })
        prefix.sendActions(for: .touchUpInside)
        try press(more)
        XCTAssertEqual(expansions, [true])
        let control = try XCTUnwrap(buttons(in: view).first { $0.currentTitle == "Ctrl" })
        control.sendActions(for: .touchUpInside)
        XCTAssertTrue(control.isSelected)
        input.insertText("a")
        XCTAssertFalse(control.isSelected, "Control must be a one-key latch")
        input.insertText("x")
        try await wait { session.events.count == 3 }
        XCTAssertEqual(session.events, [.key(.init(.character("b"), modifiers: .control)),
                                       .key(.init(.character("a"), modifiers: .control)), .bytes(Data("x".utf8))])
        let probe = TerminalTapProbe(target: nil, action: nil)
        probe.point = CGPoint(x: 16, y: view.bounds.height - 10)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(probe), "Terminal recognizers must leave controls alone")
        probe.point = CGPoint(x: 16, y: 16)
        XCTAssertTrue(view.gestureRecognizerShouldBegin(probe))
    }
    @MainActor func testUIKitTypingDeletionReturnAccessoryAndTouchRouteInOrder() async throws {
        let session = InteractionSession()
        let (window, view, input) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        view.frameProvider = InteractionFrames(frame())
        view.startInput(); await view.refresh()
        let began = ContinuousClock().now
        for _ in 0..<200 {
            input.insertText("x")
            XCTAssertEqual(input.text.utf16.count, 1, "Committed input must not accumulate")
        }
        XCTAssertLessThan(began.duration(to: ContinuousClock().now), .seconds(1), "Typing must not block the UI")
        input.deleteBackward()
        XCTAssertFalse(view.textView(input, shouldChangeTextIn: NSRange(location: 1, length: 0), replacementText: "\n"))
        let more = try barItem(in: view, label: "Show extra keys")
        try press(more)
        let left = try XCTUnwrap(buttons(in: view).first { $0.currentTitle == "←" })
        left.sendActions(for: .touchUpInside)
        let area = view.bounds.inset(by: view.safeAreaInsets)
        view.tapTerminal(at: CGPoint(x: area.minX + 25, y: area.minY + 33))
        try await wait { session.events.count == 205 }
        XCTAssertEqual(Array(session.events.prefix(200)), Array(repeating: .bytes(Data("x".utf8)), count: 200))
        XCTAssertEqual(Array(session.events.suffix(5)), [
            .key(.init(.backspace)), .key(.init(.enter)), .key(.init(.left)),
            .mouse(3, 2, 1, .press), .mouse(3, 2, 1, .release)
        ])
        XCTAssertFalse(session.sizes.isEmpty)
        view.setKeyboardVisible(false)
        XCTAssertTrue(input.isFirstResponder, "Hidden software keyboard must still accept hardware keys")
        XCTAssertNotNil(input.inputView)
        view.setKeyboardVisible(true); XCTAssertTrue(input.isFirstResponder)
        XCTAssertNil(input.inputView)
        XCTAssertFalse(input.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    }

    @MainActor func testRealUIKitMarkedTextIsNotSentUntilCommit() async throws {
        let session = InteractionSession()
        let (window, view, input) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        view.startInput()
        input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(input.markedTextRange)
        view.textViewDidChange(input)
        await Task.yield()
        XCTAssertTrue(session.events.isEmpty)
        input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        view.textViewDidChange(input)
        XCTAssertTrue(session.events.isEmpty)
        input.unmarkText(); view.textViewDidChange(input)
        try await wait { !session.events.isEmpty }
        XCTAssertEqual(session.events, [.bytes(Data("日本".utf8))])
        XCTAssertEqual(input.text.utf16.count, 1)
    }

    @MainActor func testRefreshIsSingleFlightAndUnchangedOutputDoesNotRedraw() async throws {
        let session = InteractionSession()
        let (window, view, _) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        let provider = InteractionFrames(frame())
        view.frameProvider = provider; view.startInput()
        let target = MainActorTerminal(view)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { await target.refresh() } }
        }
        for _ in 0..<20 { await view.refresh() }
        let maximumConcurrent = await provider.maximumConcurrent
        XCTAssertEqual(maximumConcurrent, 1)
        XCTAssertEqual(view.presentedFrames, 1)
    }

    @MainActor func testDisplayLinkRendersWithoutManualRefreshAndRestartsAfterWindowReattachment() async throws {
        let session = InteractionSession()
        let (window, view, _) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        view.frameProvider = InteractionFrames(frame())
        // Do not startInput or refresh manually: exercise the production didMoveToWindow/display-link path.
        try await wait { view.presentedFrames > 0 }
        XCTAssertEqual(window.windowScene?.activationState, .foregroundActive)
        let firstCount = view.presentedFrames
        view.removeFromSuperview()
        view.frameProvider = InteractionFrames(frame(styled: true))
        window.rootViewController!.view.addSubview(view)
        try await wait { view.presentedFrames > firstCount }
    }

    @MainActor func testActualRendererHidesInvisibleButDrawsFaintGlyphs() async throws {
        let session = InteractionSession()
        let (window, view, _) = fixture(session: session)
        defer { view.pauseInput(); window.isHidden = true }
        view.frameProvider = InteractionFrames(frame(styled: true)); view.startInput(); await view.refresh()
        let image = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in view.draw(view.bounds) }
        let cg = try XCTUnwrap(image.cgImage)
        let pixels = try XCTUnwrap(cg.dataProvider?.data) as Data
        let scale = Int(image.scale), rowBytes = cg.bytesPerRow, channels = cg.bitsPerPixel / 8
        var invisibleLit = 0, faintLit = 0
        let origin = view.bounds.inset(by: view.safeAreaInsets).origin
        for y in Int(origin.y * image.scale)..<Int((origin.y + 16) * image.scale) {
            for x in Int(origin.x * image.scale)..<Int((origin.x + 16) * image.scale) {
                let i = y * rowBytes + x * channels
                let lit = pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0
                if lit { if x < Int(origin.x * image.scale) + 8 * scale { invisibleLit += 1 } else { faintLit += 1 } }
            }
        }
        XCTAssertEqual(invisibleLit, 0)
        XCTAssertGreaterThan(faintLit, 0)
    }

    @MainActor private func fixture(session: InteractionSession) -> (UIWindow, TerminalView, UITextView) {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let view = TerminalView(frame: CGRect(x: 0, y: 100, width: 320, height: 320))
        view.session = session
        window.rootViewController!.view.addSubview(view)
        view.layoutIfNeeded()
        view.setKeyboardVisible(true)
        let input = view.subviews.compactMap { $0 as? UITextView }.first!
        return (window, view, input)
    }
    @MainActor private func barItem(in view: UIView, label: String) throws -> UIBarButtonItem {
        if let toolbar = view as? UIToolbar,
           let item = toolbar.items?.first(where: { $0.accessibilityLabel == label }) { return item }
        for child in view.subviews {
            if let item = try? barItem(in: child, label: label) { return item }
        }
        throw NSError(domain: "Missing toolbar item: \(label)", code: 1)
    }
    @MainActor private func press(_ item: UIBarButtonItem) throws {
        guard item.isEnabled else { return }
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }
    @MainActor private func buttons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now + .seconds(3)
        while !condition(), ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Interaction did not finish within three seconds")
    }
    private func frame(styled: Bool = false) -> Data {
        var data = Data()
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        [40, 10, 0, 0, 0, 0, 0xffffffff, 0xff000000, 0xffffffff].forEach { word(UInt32($0)) }
        for index in 0..<400 {
            let text = styled && index < 2 ? Data("X".utf8) : Data(" ".utf8)
            word(1); word(styled && index < 2 ? (index == 0 ? 16 : 32) : 0)
            word(0xffffffff); word(0xff000000); word(UInt32(text.count)); data.append(text)
        }
        return data
    }
}
#endif
