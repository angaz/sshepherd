#if os(iOS)
import UIKit

/// UIKit owns the refresh clock, text responder and ordered input. SwiftUI never drives a frame loop.
@MainActor public final class TerminalView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    public var session: (any TerminalSession)?
    public var frameProvider: (any TerminalFrameProvider)?
    public var stateChanged: ((ConnectionState) -> Void)?
    public var keyboardVisibilityChanged: ((Bool) -> Void)?
    public var controlsExpansionChanged: ((Bool) -> Void)?
    public var pasteRequested: (() -> Void)?
    public private(set) var presentedFrames = 0
    public private(set) var keyboardVisible = false
    private var controlLatched = false
    private let emptyKeyboard = UIView(frame: .zero)
    private let controls = TerminalControlsView(frame: .zero)
    private let controlsBackground = UIView(frame: .zero)
    private var terminalFrame: TerminalFrame?
    private var lastBytes: Data?
    private let input = TerminalTextInput(frame: .zero)
    private let anchor = "\u{200B}"
    private var inputModel = TerminalInputModel()
    private var active = false
    private var generation = 0
    private var refreshing = false
    private var clock: CADisplayLink?
    private var clockTarget: TerminalClock?
    private var lastState: ConnectionState?
    private var resizeTask: Task<Void, Never>?
    private var pendingSize: (Int, Int)?
    private var lastSize: (Int, Int)?
    private var inputTail: Task<Void, Never>?
    private var pendingInput = 0
    private var inputSequence = 0
    private let cellWidth: CGFloat = 8
    private let cellHeight: CGFloat = 16
    private let regularFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let boldFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private struct Style: Hashable { let flags: UInt32; let color: UInt32 }
    private var styles: [Style: [NSAttributedString.Key: Any]] = [:]
    private var panOffset: CGFloat = 0
    private lazy var terminalAccessibility = UIAccessibilityElement(accessibilityContainer: self)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        accessibilityIdentifier = "Terminal surface"
        input.terminal = self
        input.delegate = self
        input.backgroundColor = .clear
        input.textColor = .clear
        input.tintColor = .clear
        input.isAccessibilityElement = true
        input.accessibilityLabel = "Terminal input"
        input.accessibilityIdentifier = "Terminal input"
        input.autocorrectionType = .no
        input.autocapitalizationType = .none
        input.spellCheckingType = .no
        input.smartQuotesType = .no
        input.smartDashesType = .no
        input.smartInsertDeleteType = .no
        input.inputView = emptyKeyboard
        resetTextInput()
        addSubview(input)
        controlsBackground.backgroundColor = .secondarySystemBackground
        controlsBackground.isUserInteractionEnabled = false
        controlsBackground.accessibilityIdentifier = "Terminal controls background"
        addSubview(controlsBackground)
        addSubview(controls)
        controls.setConnected(false)
        controls.onKey = { [weak self] event in self?.sendKey(event) }
        controls.onHerdrAction = { [weak self] key in
            guard let self, self.isConnected else { return }
            self.setControlLatched(false)
            self.enqueue { session in
                await session.sendKey(.init(.character("b"), modifiers: .control))
                await session.sendKey(.init(.character(String(key))))
            }
        }
        controls.onKeyboard = { [weak self] in guard let self else { return }; self.setKeyboardVisible(!self.keyboardVisible) }
        controls.onControl = { [weak self] in guard let self else { return }; self.setControlLatched(!self.controlLatched) }
        controls.onExpand = { [weak self] expanded in
            if expanded { self?.setKeyboardVisible(false) }
            self?.controlsExpansionChanged?(expanded)
        }
        controls.heightChanged = { [weak self] in self?.setNeedsLayout(); self?.layoutIfNeeded() }
        terminalAccessibility.accessibilityIdentifier = "Terminal contents"
        terminalAccessibility.accessibilityLabel = "SSH terminal"
        terminalAccessibility.accessibilityTraits = [.staticText, .allowsDirectInteraction]
        accessibilityElements = [terminalAccessibility, input, controls]
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        tap.delegate = self; pan.delegate = self
        addGestureRecognizer(tap); addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        clock?.invalidate(); clock = nil
        guard window != nil else { pauseInput(); return }
        let target = TerminalClock(); target.view = self; clockTarget = target
        let link = CADisplayLink(target: target, selector: #selector(TerminalClock.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        clock = link
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // A real attached text responder, not a hidden zero-sized UITextView.
        input.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let content = bounds.inset(by: safeAreaInsets)
        let height = controls.preferredHeight(available: content.height)
        controls.bottomGestureInset = safeAreaInsets.bottom
        controls.frame = CGRect(x: content.minX, y: content.maxY - height, width: content.width,
                                height: height + safeAreaInsets.bottom)
        // The toolbar fills the bottom edge; UIKit keeps its content above the home gesture.
        controlsBackground.frame = CGRect(x: 0, y: controls.frame.minY, width: bounds.width,
                                          height: bounds.maxY - controls.frame.minY)
        updateAccessibility()
        queueResize()
        setNeedsDisplay()
    }

    fileprivate func tick() {
        guard window?.windowScene?.activationState == .foregroundActive else {
            if active { pauseInput() }
            return
        }
        let state = session?.state ?? .disconnected
        if state != lastState { lastState = state; stateChanged?(state) }
        if state == .connected { startInput() }
        else if active { pauseInput() }
        guard !refreshing, isConnected else { return }
        Task { [weak self] in await self?.refresh() }
    }

    public func startInput() {
        guard session?.state == .connected else { if active { pauseInput() }; return }
        guard !active else { return }
        active = true
        lastSize = nil
        controls.setConnected(true)
        input.becomeFirstResponder()
        queueResize()
    }

    public func setKeyboardVisible(_ visible: Bool) {
        guard visible != keyboardVisible else { return }
        keyboardVisible = visible
        input.inputView = visible ? nil : emptyKeyboard
        if active { input.reloadInputViews(); input.becomeFirstResponder() }
        controls.setKeyboardVisible(visible)
        keyboardVisibilityChanged?(visible)
    }

    public func pauseInput() {
        generation &+= 1
        active = false
        controls.setConnected(false)
        setControlLatched(false)
        resizeTask?.cancel(); resizeTask = nil; pendingSize = nil; lastSize = nil
        inputTail?.cancel(); inputTail = nil; pendingInput = 0
        input.resignFirstResponder()
        resetTextInput()
    }

    /// Single flight; unchanged snapshots do not decode, allocate glyph attributes, or redraw.
    public func refresh() async {
        guard !refreshing, isConnected, let provider = frameProvider else { return }
        refreshing = true
        defer { refreshing = false }
        let expected = generation
        guard let bytes = try? await provider.frameSnapshot(), expected == generation,
              isConnected, bytes != lastBytes, let next = try? TerminalFrame.decode(bytes) else { return }
        let old = terminalFrame
        lastBytes = bytes; terminalFrame = next; presentedFrames += 1
        updateAccessibility()
        if let old, old.columns == next.columns, old.rows == next.rows, old.background == next.background {
            var dirty = CGRect.null
            for index in next.cells.indices where old.cells[index] != next.cells[index] {
                dirty = dirty.union(cellRect(column: index % next.columns, row: index / next.columns, width: 2))
            }
            dirty = dirty.union(cellRect(column: old.cursorX, row: old.cursorY, width: 1))
            dirty = dirty.union(cellRect(column: next.cursorX, row: next.cursorY, width: 1))
            if !dirty.isNull { setNeedsDisplay(dirty) }
        } else { setNeedsDisplay() }
    }

    public override func draw(_ rect: CGRect) {
        guard let frame = terminalFrame else { return }
        guard !terminalBounds.isEmpty else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: terminalBounds)
        UIColor(argb: frame.background).setFill(); UIRectFill(rect)
        let firstRow = max(0, Int(floor((rect.minY - terminalBounds.minY) / cellHeight)))
        let lastRow = min(frame.rows, Int(ceil((rect.maxY - terminalBounds.minY) / cellHeight)))
        guard firstRow < lastRow else { return }
        if styles.count > 512 { styles.removeAll(keepingCapacity: true) }
        for row in firstRow..<lastRow {
            for column in 0..<frame.columns {
                let cell = frame.cells[row * frame.columns + column]
                let area = cellRect(column: column, row: row, width: max(1, Int(cell.width)))
                guard area.intersects(rect) else { continue }
                if cell.background != frame.background { UIColor(argb: cell.background).setFill(); UIRectFill(area) }
                // Native ABI: invisible=16, faint=32. Continuation cells and blank glyphs need no shaping.
                guard cell.width != 0, !cell.text.isEmpty, cell.text != " ", cell.flags & 16 == 0 else { continue }
                let style = Style(flags: cell.flags, color: cell.foreground)
                let attributes: [NSAttributedString.Key: Any]
                if let cached = styles[style] { attributes = cached }
                else {
                    var value: [NSAttributedString.Key: Any] = [
                        .font: cell.flags & 1 != 0 ? boldFont : regularFont,
                        .foregroundColor: UIColor(argb: cell.foreground).withAlphaComponent(cell.flags & 32 != 0 ? 0.5 : 1)
                    ]
                    if cell.flags & 2 != 0 { value[.obliqueness] = 0.2 }
                    if cell.flags & 4 != 0 { value[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if cell.flags & 8 != 0 { value[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    styles[style] = value; attributes = value
                }
                NSString(string: cell.text).draw(in: area, withAttributes: attributes)
            }
        }
        guard frame.cursorFlags & 1 != 0 else { return }
        var cursor = cellRect(column: frame.cursorX, row: frame.cursorY, width: 1)
        switch frame.cursorStyle {
        case 1: cursor.size.width = 2
        case 2: cursor.origin.y += cellHeight - 2; cursor.size.height = 2
        case 3:
            UIColor(argb: frame.cursorColor).setStroke(); UIBezierPath(rect: cursor.insetBy(dx: 1, dy: 1)).stroke(); return
        default: break
        }
        UIColor(argb: frame.cursorColor).withAlphaComponent(0.65).setFill()
        UIRectFillUsingBlendMode(cursor, .difference)
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard isConnected else { resetTextInput(); return }
        guard textView.markedTextRange == nil else { return }
        do {
            if let bytes = try inputModel.synchronize(text: textView.text, hasMarkedText: false), !bytes.isEmpty {
                if bytes == Data([0x7f]) { sendKey(.init(.backspace)) }
                else if controlLatched, let text = String(data: bytes, encoding: .utf8), let first = text.first {
                    sendKey(.init(.character(String(first))))
                    let rest = Data(text.dropFirst().utf8)
                    if !rest.isEmpty { send(rest) }
                } else { send(bytes) }
            }
        } catch { /* Oversized/control-character edits are refused, never replayed. */ }
        resetTextInput()
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard isConnected else { return false }
        if text == "\n", textView.markedTextRange == nil { sendKey(TerminalKeyEvent(.enter)); return false }
        return true
    }

    private func resetTextInput() {
        if input.text != anchor {
            input.textStorage.replaceCharacters(in: NSRange(location: 0, length: input.textStorage.length), with: anchor)
        }
        let caret = NSRange(location: anchor.utf16.count, length: 0)
        if input.selectedRange != caret { input.selectedRange = caret }
        inputModel.reset(text: anchor)
    }

    fileprivate var canRequestPaste: Bool { isConnected && pasteRequested != nil }
    fileprivate func requestPaste() { if canRequestPaste { pasteRequested?() } }

    fileprivate func handleHardwareKey(_ key: UIKey) -> Bool {
        guard isConnected else { return false }
        if key.modifierFlags.contains(.command), key.keyCode == .keyboardV { requestPaste(); return true }
        let special: TerminalKey?
        switch key.keyCode {
        case .keyboardEscape: special = .escape
        case .keyboardTab: special = .tab
        case .keyboardReturnOrEnter: special = .enter
        case .keyboardDeleteOrBackspace: special = .backspace
        case .keyboardDeleteForward: special = .delete
        case .keyboardHome: special = .home
        case .keyboardEnd: special = .end
        case .keyboardPageUp: special = .pageUp
        case .keyboardPageDown: special = .pageDown
        case .keyboardUpArrow: special = .up
        case .keyboardDownArrow: special = .down
        case .keyboardLeftArrow: special = .left
        case .keyboardRightArrow: special = .right
        default: special = nil
        }
        var modifiers: TerminalKeyModifiers = []
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if let special { sendKey(TerminalKeyEvent(special, modifiers: modifiers)); return true }
        // Ordinary characters and IME belong to UITextView, avoiding duplicate hardware input.
        if !modifiers.intersection([.control, .option]).isEmpty, !key.charactersIgnoringModifiers.isEmpty {
            sendKey(TerminalKeyEvent(.character(key.charactersIgnoringModifiers), modifiers: modifiers)); return true
        }
        return false
    }

    public func sendKey(_ event: TerminalKeyEvent) {
        guard isConnected else { return }
        var modifiers = event.modifiers
        if controlLatched { modifiers.insert(.control); setControlLatched(false) }
        let event = TerminalKeyEvent(event.key, modifiers: modifiers)
        enqueue { await $0.sendKey(event) }
    }
    private func setControlLatched(_ latched: Bool) {
        controlLatched = latched
        controls.setControlLatched(latched)
    }
    public func confirmPaste(_ text: String, confirmed: Bool) {
        guard confirmed, let bytes = try? PasteInput.utf8(text) else { return }; send(bytes)
    }
    private func send(_ bytes: Data) { enqueue { await $0.send(bytes) } }

    private func enqueue(_ operation: @escaping @Sendable (any TerminalSession) async -> Void) {
        guard isConnected, pendingInput < 256, let session else { return }
        let expected = generation, previous = inputTail
        pendingInput += 1; inputSequence &+= 1
        let sequence = inputSequence
        inputTail = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == expected, self.isConnected, !Task.isCancelled else { return }
            await operation(session)
            guard self.generation == expected else { return }
            self.pendingInput -= 1
            if sequence == self.inputSequence { self.inputTail = nil }
        }
    }

    /// Both halves of a click, in cell coordinates. The native adapter converts cells to pixels.
    public func tapTerminal(at point: CGPoint) {
        guard let frame = terminalFrame, terminalBounds.contains(point), isConnected else { return }
        let column = min(frame.columns - 1, Int((point.x - terminalBounds.minX) / cellWidth))
        let row = min(frame.rows - 1, Int((point.y - terminalBounds.minY) / cellHeight))
        enqueue { session in
            await session.sendMouse(TerminalMouseEvent(column: column, row: row, button: 1, action: .press))
            await session.sendMouse(TerminalMouseEvent(column: column, row: row, button: 1, action: .release))
        }
    }
    public override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        // Terminal gestures must never swallow key-button taps or keypad scrolling.
        terminalBounds.contains(recognizer.location(in: self))
    }
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        tapTerminal(at: recognizer.location(in: self))
        if keyboardVisible { input.becomeFirstResponder() }
    }
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard isConnected, let frame = terminalFrame else { return }
        if recognizer.state == .began { panOffset = 0 }
        guard recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: self).y
        let steps = min(8, Int(abs(translation - panOffset) / cellHeight))
        guard steps > 0 else { return }
        let up = translation > panOffset
        panOffset += CGFloat(steps) * cellHeight * (up ? 1 : -1)
        let point = recognizer.location(in: self)
        let column = max(0, min(frame.columns - 1, Int((point.x - terminalBounds.minX) / cellWidth)))
        let row = max(0, min(frame.rows - 1, Int((point.y - terminalBounds.minY) / cellHeight)))
        enqueue { session in
            for _ in 0..<steps { await session.sendMouse(TerminalMouseEvent(column: column, row: row, button: up ? 4 : 5, action: .scroll)) }
        }
    }

    private var isConnected: Bool { active && session?.state == .connected }
    private var terminalBounds: CGRect {
        var content = bounds.inset(by: safeAreaInsets)
        content.size.height = max(0, content.height - controls.preferredHeight(available: content.height))
        return content
    }
    private func updateAccessibility() {
        terminalAccessibility.accessibilityFrameInContainerSpace = terminalBounds
        guard let frame = terminalFrame else { return }
        let rows = min(frame.rows, max(0, Int(terminalBounds.height / cellHeight)))
        let columns = min(frame.columns, max(0, Int(terminalBounds.width / cellWidth)))
        var lines: [String] = []
        for row in 0..<rows {
            let cells = frame.cells[(row * frame.columns)..<(row * frame.columns + columns)]
            let line = cells.filter { $0.width != 0 }.map { cell in
                cell.flags & 16 == 0 ? cell.text : String(repeating: " ", count: Int(cell.width))
            }.joined()
            lines.append(line)
        }
        // Only displayed cells are exposed; concealed glyphs never enter the accessibility tree.
        terminalAccessibility.accessibilityValue = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func cellRect(column: Int, row: Int, width: Int) -> CGRect {
        CGRect(x: terminalBounds.minX + CGFloat(column) * cellWidth, y: terminalBounds.minY + CGFloat(row) * cellHeight,
               width: CGFloat(width) * cellWidth, height: cellHeight)
    }
    private func queueResize() {
        guard isConnected, terminalBounds.width >= cellWidth, terminalBounds.height >= cellHeight else { return }
        let size = (max(2, Int(terminalBounds.width / cellWidth)), max(2, Int(terminalBounds.height / cellHeight)))
        if let lastSize, lastSize == size { return }
        lastSize = size; pendingSize = size
        guard resizeTask == nil else { return }
        let expected = generation
        resizeTask = Task { [weak self] in
            while !Task.isCancelled, let self, let size = self.pendingSize {
                self.pendingSize = nil
                guard self.generation == expected, self.isConnected, let session = self.session else { break }
                await session.resize(columns: size.0, rows: size.1)
            }
            guard let self, self.generation == expected else { return }
            self.resizeTask = nil
        }
    }
}

@MainActor private final class TerminalClock: NSObject {
    weak var view: TerminalView?
    @objc func tick(_ sender: CADisplayLink) {
        guard let view else { sender.invalidate(); return }
        view.tick()
    }
}
@MainActor private final class TerminalTextInput: UITextView {
    weak var terminal: TerminalView?
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, terminal?.handleHardwareKey(key) == true else { unhandled.insert(press); continue }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // All paste must go through the app's explicit confirmation sheet.
        if action == #selector(paste(_:)) { return terminal?.canRequestPaste == true }
        return super.canPerformAction(action, withSender: sender)
    }
    override func paste(_ sender: Any?) { terminal?.requestPaste() }
}
private extension UIColor {
    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255,
                  blue: CGFloat(argb & 255) / 255, alpha: CGFloat((argb >> 24) & 255) / 255)
    }
}
#endif
