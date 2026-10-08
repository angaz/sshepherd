#if os(iOS)
import UIKit

/// A system toolbar for frequent actions and an expandable four-column terminal keypad.
@MainActor final class TerminalControlsView: UIView, UIToolbarDelegate {
    var onKey: ((TerminalKeyEvent) -> Void)?
    var onKeyboard: (() -> Void)?
    var onControl: (() -> Void)?
    var onHerdrAction: ((Character) -> Void)?
    var heightChanged: (() -> Void)?
    var onExpand: ((Bool) -> Void)?
    var bottomGestureInset: CGFloat = 0 { didSet { if oldValue != bottomGestureInset { setNeedsLayout() } } }
    static let primaryHeight: CGFloat = 44
    private let toolbar = UIToolbar()
    private let scroll = UIScrollView()
    private let grid = UIStackView()
    private let control = UIButton(type: .system)
    private var tab: UIBarButtonItem!
    private var clearLine: UIBarButtonItem!
    private var interrupt: UIBarButtonItem!
    private var more: UIBarButtonItem!
    private var keyboard: UIBarButtonItem!
    private var expanded = false
    private var actions: [Int: TerminalKeyEvent] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        toolbar.accessibilityIdentifier = "Terminal actions"
        toolbar.delegate = self
        tab = barIcon("arrow.right.to.line", label: "Tab", action: #selector(sendTab))
        clearLine = barIcon("eraser", label: "Clear line", action: #selector(sendClearLine))
        interrupt = barIcon("stop.circle", label: "Ctrl-C", action: #selector(sendInterrupt))
        more = barIcon("ellipsis", label: "Show extra keys", action: #selector(toggleExtra))
        keyboard = barIcon("keyboard", label: "Show keyboard", action: #selector(toggleKeyboard))
        toolbar.items = [tab, interrupt, clearLine, more, keyboard]
        addSubview(toolbar)

        grid.axis = .vertical; grid.spacing = 2; grid.distribution = .fillEqually
        configure(control, title: "Ctrl", description: "Control modifier off")
        control.addTarget(self, action: #selector(toggleControl), for: .touchUpInside)
        let extra: [UIView] = [control, key("↑", .init(.up)), key("Enter", .init(.enter)), key("⌫", .init(.backspace)),
            key("←", .init(.left)), key("↓", .init(.down)), key("→", .init(.right)), key("Del", .init(.delete)),
            key("Home", .init(.home)), key("End", .init(.end)), key("PgUp", .init(.pageUp)), key("PgDn", .init(.pageDown)),
            key("Ctrl-D", .init(.character("d"), modifiers: .control)), key("Ctrl-Z", .init(.character("z"), modifiers: .control)),
            key("Ctrl-L", .init(.character("l"), modifiers: .control)), key("Ctrl-W", .init(.character("w"), modifiers: .control)),
            key("Esc", .init(.escape)), key("Prefix", .init(.character("b"), modifiers: .control)),
            herdrAction("Prev tab", key: "p"), herdrAction("Next tab", key: "n")]
        for offset in stride(from: 0, to: extra.count, by: 4) {
            let row = UIStackView(arrangedSubviews: Array(extra[offset..<offset + 4]))
            row.axis = .horizontal; row.spacing = 2; row.distribution = .fillEqually
            grid.addArrangedSubview(row)
        }
        scroll.addSubview(grid); addSubview(scroll); scroll.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func position(for bar: any UIBarPositioning) -> UIBarPosition { .bottom }
    func preferredHeight(available: CGFloat) -> CGFloat {
        let gridHeight = CGFloat(grid.arrangedSubviews.count) * 48
        let extra = expanded ? min(gridHeight, max(0, available - Self.primaryHeight - 120)) : 0
        return min(available, Self.primaryHeight + extra)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rowHeight = min(Self.primaryHeight + bottomGestureInset, bounds.height)
        toolbar.frame = CGRect(x: 0, y: bounds.height - rowHeight, width: bounds.width, height: rowHeight)
        scroll.frame = CGRect(x: 2, y: 0, width: max(0, bounds.width - 4), height: max(0, bounds.height - rowHeight))
        grid.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: CGFloat(grid.arrangedSubviews.count) * 48)
        scroll.contentSize = grid.bounds.size
    }
    func setConnected(_ connected: Bool) {
        tab.isEnabled = connected
        clearLine.isEnabled = connected
        interrupt.isEnabled = connected
        keyboard.isEnabled = connected
        // Extra controls remain reachable while disconnected; navigation lives in the top bar.
        setExtraKeysEnabled(in: grid, enabled: connected)
    }
    private func setExtraKeysEnabled(in view: UIView, enabled: Bool) {
        if let button = view as? UIButton { button.isEnabled = enabled }
        else { view.subviews.forEach { setExtraKeysEnabled(in: $0, enabled: enabled) } }
    }
    func setKeyboardVisible(_ visible: Bool) {
        keyboard.image = UIImage(systemName: visible ? "keyboard.chevron.compact.down" : "keyboard")
        keyboard.accessibilityLabel = visible ? "Hide keyboard" : "Show keyboard"
        if visible && expanded { toggleExtra() }
    }
    func setControlLatched(_ latched: Bool) {
        control.isSelected = latched
        control.accessibilityLabel = latched ? "Control modifier on" : "Control modifier off"
        control.backgroundColor = latched ? .systemBlue : .tertiarySystemBackground
        control.setTitleColor(latched ? .white : tintColor, for: .normal)
    }
    private func barIcon(_ symbol: String, label: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.accessibilityLabel = label
        return item
    }
    private func configure(_ button: UIButton, title: String, description: String? = nil) {
        button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.accessibilityLabel = description ?? title
        button.backgroundColor = .tertiarySystemBackground; button.layer.cornerRadius = 6
    }
    private func key(_ title: String, _ event: TerminalKeyEvent) -> UIButton {
        let button = UIButton(type: .system); configure(button, title: title)
        button.tag = actions.count; actions[button.tag] = event
        button.addTarget(self, action: #selector(sendKey(_:)), for: .touchUpInside)
        return button
    }
    private func herdrAction(_ title: String, key: Character, description: String? = nil) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, title: title, description: description)
        button.addAction(UIAction { [weak self] _ in self?.onHerdrAction?(key) }, for: .touchUpInside)
        return button
    }
    @objc private func sendTab() { onKey?(.init(.tab)) }
    @objc private func sendClearLine() { onKey?(.init(.character("u"), modifiers: .control)) }
    @objc private func sendInterrupt() { onKey?(.init(.character("c"), modifiers: .control)) }
    @objc private func sendKey(_ button: UIButton) { if let event = actions[button.tag] { onKey?(event) } }
    @objc private func toggleExtra() {
        expanded.toggle(); scroll.isHidden = !expanded
        more.image = UIImage(systemName: expanded ? "chevron.down" : "ellipsis")
        more.accessibilityLabel = expanded ? "Hide extra keys" : "Show extra keys"
        onExpand?(expanded)
        heightChanged?()
    }
    @objc private func toggleKeyboard() { onKeyboard?() }
    @objc private func toggleControl() { onControl?() }
}
#endif
