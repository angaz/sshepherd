import Foundation

public enum HostAuthentication: String, Codable, CaseIterable, Sendable { case ed25519, password }

public struct Host: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public var port: UInt16
    public var username: String
    public var authentication: HostAuthentication
    public init(id: UUID = UUID(), name: String, address: String, port: UInt16 = 22, username: String,
                authentication: HostAuthentication = .ed25519) {
        self.id = id; self.name = name; self.address = address; self.port = port; self.username = username
        self.authentication = authentication
    }
}

public enum ConnectionState: Equatable, Sendable { case disconnected, connecting, connected, suspended, failed(String) }

public protocol HostStore: Sendable {
    func hosts() async throws -> [Host]
    func save(_ hosts: [Host]) async throws
}

/// Implementations must confirm a new host fingerprint and refuse a changed fingerprint before authentication.
public protocol CredentialActions: Sendable {
    func authenticate(host: Host) async throws
    func confirmFingerprint(_ fingerprint: String, for host: Host) async throws -> Bool
}

public struct TerminalKeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
}

public enum TerminalKey: Sendable, Equatable {
    case character(String), escape, tab, enter, backspace, delete, up, down, left, right, home, end, pageUp, pageDown
}

public struct TerminalKeyEvent: Sendable, Equatable {
    public let key: TerminalKey
    public let modifiers: TerminalKeyModifiers
    public init(_ key: TerminalKey, modifiers: TerminalKeyModifiers = []) { self.key = key; self.modifiers = modifiers }
}

public enum TerminalMouseAction: Sendable, Equatable { case press, release, move, scroll }
public struct TerminalMouseEvent: Sendable, Equatable {
    public let column: Int, row: Int, button: Int, action: TerminalMouseAction
    public let modifiers: TerminalKeyModifiers
    public init(column: Int, row: Int, button: Int = 1, action: TerminalMouseAction = .press, modifiers: TerminalKeyModifiers = []) {
        self.column = column; self.row = row; self.button = button; self.action = action; self.modifiers = modifiers
    }
}

/// The final native-engine adapter receives key and mouse events rather than UIKit synthesizing terminal escape sequences.
public protocol TerminalSession: AnyObject, Sendable {
    var state: ConnectionState { get }
    func connect() async throws
    func detach() async
    func send(_ bytes: Data) async
    func sendKey(_ event: TerminalKeyEvent) async
    func sendMouse(_ event: TerminalMouseEvent) async
    func resize(columns: Int, rows: Int) async
}

public protocol TerminalFrameProvider: Sendable {
    func frameSnapshot() async throws -> Data
}

public enum PasteError: Error, Equatable { case tooLarge, unsupportedControl, invalidUTF8 }

public enum PasteInput {
    /// Validates explicit user-confirmed text only. It deliberately does not implement a file/image protocol.
    public static func utf8(_ text: String) throws -> Data {
        let data = Data(text.utf8)
        guard data.count <= 60_000 else { throw PasteError.tooLarge }
        for scalar in text.unicodeScalars {
            if (scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t") || scalar.value == 0x7f {
                throw PasteError.unsupportedControl
            }
        }
        guard String(data: data, encoding: .utf8) != nil else { throw PasteError.invalidUTF8 }
        return data
    }
}

/// Retains UIKit's text state while marked text is active and emits only committed terminal edits.
public struct TerminalInputModel: Sendable {
    private var committed = ""
    public init() {}

    public mutating func reset(text: String = "") { committed = text }

    /// Call after UIKit has applied an edit. Marked text is retained locally; cancellation/replacement emits nothing.
    public mutating func synchronize(text: String, hasMarkedText: Bool) throws -> Data? {
        guard !hasMarkedText else { return nil }
        let before = Array(committed)
        let after = Array(text)
        var prefix = 0
        while prefix < before.count && prefix < after.count && before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix && suffix < after.count - prefix && before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let deleted = before.count - prefix - suffix
        let inserted = String(after[prefix..<(after.count - suffix)])
        let insertedBytes = try PasteInput.utf8(inserted)
        committed = text
        guard deleted > 0 || !insertedBytes.isEmpty else { return nil }
        return Data(repeating: 0x7f, count: deleted) + insertedBytes
    }
}
