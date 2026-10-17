import Foundation

public enum HerdrBrowserError: Error, LocalizedError, Sendable {
    case unavailable, expired, disconnected, timedOut, refused(String), malformedStream
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This server does not provide the native Herdr browser."
        case .expired: return "This selection no longer exists. Refresh the list."
        case .disconnected: return "The terminal is disconnected."
        case .timedOut: return "The server did not confirm the selection."
        case .refused(let message): return message
        case .malformedStream: return "The server sent an invalid browser message."
        }
    }
}

struct HerdrBridgeMessage: Decodable, Sendable {
    let type: String
    let catalog: HerdrCatalog?
    let id: String?
    let error: String?
}

/// An incremental private OSC lane multiplexed by the host bridge beside stock
/// Herdr's unchanged terminal output. Never feed these messages into Ghostty.
struct HerdrBridgeStream: Sendable {
    static let prefix = Data("\u{1b}]777;sshepherd;".utf8)
    private var pending = Data()
    private let limit = 4 * 1024 * 1024

    mutating func feed(_ bytes: Data) throws -> (Data, [HerdrBridgeMessage]) {
        pending.append(bytes)
        var terminal = Data()
        var messages: [HerdrBridgeMessage] = []
        while !pending.isEmpty {
            guard let range = pending.range(of: Self.prefix) else {
                let keep = (1..<Self.prefix.count).reversed().first {
                    pending.suffix($0).elementsEqual(Self.prefix.prefix($0))
                } ?? 0
                terminal.append(pending.prefix(pending.count - keep))
                pending = Data(pending.suffix(keep))
                break
            }
            terminal.append(pending[..<range.lowerBound])
            pending = Data(pending[range.lowerBound...])
            guard let end = pending.dropFirst(Self.prefix.count).firstIndex(of: 7) else {
                guard pending.count <= limit else { throw HerdrBrowserError.malformedStream }
                break
            }
            guard end <= limit else { throw HerdrBrowserError.malformedStream }
            let encoded = pending[Self.prefix.count..<end]
            pending = Data(pending.dropFirst(end + 1))
            guard let decoded = Data(base64Encoded: encoded),
                  let message = try? JSONDecoder().decode(HerdrBridgeMessage.self, from: decoded) else {
                throw HerdrBrowserError.malformedStream
            }
            messages.append(message)
        }
        return (terminal, messages)
    }

    static func focus(id: String, bootID: String, kind: String, target: String) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "focus", "id": id, "boot_id": bootID, "kind": kind, "target": target
        ], options: [.sortedKeys])
        var bytes = prefix
        bytes.append(json.base64EncodedData())
        bytes.append(7)
        return bytes
    }
}
