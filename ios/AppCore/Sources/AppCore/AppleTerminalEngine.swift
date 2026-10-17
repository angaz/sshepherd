import AppUI
import Foundation

#if canImport(SSHepherdTerminal)
import SSHepherdTerminal

/// Serialized owner of the native Ghostty-backed terminal handle. Every C-owned buffer is copied and freed before returning.
public actor AppleTerminalEngine: NativeTerminalEngine {
    private var handle: SSAppleTerminal = 0
    private var isClosed = false
    private var size = TerminalSize(columns: 80, rows: 24)
    private var cachedFrame: Data?
    private var frameDirty = true

    public init(columns: Int = 80, rows: Int = 24) throws {
        var created: SSAppleTerminal = 0
        guard ss_apple_create(UInt32(columns), UInt32(rows), &created) == 0, created != 0 else {
            throw NativeEngineError.unavailable
        }
        handle = created
        size = TerminalSize(columns: columns, rows: rows)
    }

    deinit {
        if handle != 0 { _ = ss_apple_destroy(handle) }
    }

    public func write(_ bytes: Data) async throws {
        try ensureOpen()
        let result = bytes.withUnsafeBytes { raw in
            ss_apple_write(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard result == 0 else { throw NativeEngineError.operationFailed(result) }
        frameDirty = true
    }

    public func resize(_ size: TerminalSize) async throws {
        try ensureOpen()
        guard size != self.size else { return }
        guard ss_apple_resize(handle, UInt32(size.columns), UInt32(size.rows), size.cellWidth, size.cellHeight) == 0 else {
            throw NativeEngineError.operationFailed(-1)
        }
        self.size = size
        frameDirty = true
    }

    public func frame() async throws -> Data {
        try ensureOpen()
        if !frameDirty, let cachedFrame { return cachedFrame }
        let next = try ownedBuffer { ss_apple_frame(handle, $0) }
        cachedFrame = next
        frameDirty = false
        return next
    }
    public func replies() async throws -> Data { try ownedBuffer { ss_apple_replies(handle, $0) } }

    public func key(_ event: TerminalKeyEvent) async throws -> Data {
        let mapped: Int32
        let text: Data
        switch event.key {
        case .character(let value): mapped = 0; text = Data(value.utf8)
        case .escape: mapped = 1; text = Data()
        case .tab: mapped = 2; text = Data()
        case .enter: mapped = 3; text = Data()
        case .backspace: mapped = 4; text = Data()
        case .delete: mapped = 5; text = Data()
        case .up: mapped = 6; text = Data()
        case .down: mapped = 7; text = Data()
        case .left: mapped = 8; text = Data()
        case .right: mapped = 9; text = Data()
        case .home: mapped = 10; text = Data()
        case .end: mapped = 11; text = Data()
        case .pageUp: mapped = 12; text = Data()
        case .pageDown: mapped = 13; text = Data()
        }
        return try text.withUnsafeBytes { raw in
            try ownedBuffer { output in
                ss_apple_semantic_key(handle, SSAppleKey(rawValue: UInt32(mapped)), event.modifiers.cValue,
                                      SSAppleKeyAction(rawValue: 0), raw.bindMemory(to: UInt8.self).baseAddress,
                                      raw.count, output)
            }
        }
    }

    public func mouse(_ event: TerminalMouseEvent) async throws -> Data {
        let action: Int32
        switch event.action { case .press, .scroll: action = 0; case .release: action = 1; case .move: action = 2 }
        return try ownedBuffer {
            ss_apple_mouse(handle, action, Int32(event.button),
                           Double(event.column * Int(size.cellWidth)) + Double(size.cellWidth) / 2,
                           Double(event.row * Int(size.cellHeight)) + Double(size.cellHeight) / 2,
                           Int32(event.modifiers.rawValue), $0)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if handle != 0 { _ = ss_apple_destroy(handle); handle = 0 }
    }

    private func ensureOpen() throws {
        guard !isClosed, handle != 0 else { throw NativeEngineError.closed }
    }

    private func ownedBuffer(_ operation: (UnsafeMutablePointer<SSAppleBuffer>) -> Int32) throws -> Data {
        try ensureOpen()
        var buffer = SSAppleBuffer(data: nil, len: 0)
        let result = operation(&buffer)
        defer { ss_apple_free(&buffer) }
        guard result == 0 else { throw NativeEngineError.operationFailed(result) }
        guard buffer.len == 0 || buffer.data != nil else { throw NativeEngineError.invalidBuffer }
        return buffer.len == 0 ? Data() : Data(bytes: buffer.data!, count: buffer.len)
    }
}

private extension TerminalKeyModifiers {
    var cValue: Int32 { Int32(rawValue & 0x0f) }
}
#endif
