import Foundation

public enum ServerAuthentication: String, Codable, Sendable { case ed25519, password }

public struct Server: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var authentication: ServerAuthentication

    public init(id: UUID = UUID(), name: String, hostname: String, port: UInt16 = 22, username: String,
                authentication: ServerAuthentication = .ed25519) throws {
        guard !name.isEmpty, name.count <= 128, name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw InventoryError.invalidField }
        guard !username.isEmpty, username.count <= 128, username.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value != 127 }) else { throw InventoryError.invalidField }
        guard port > 0 else { throw InventoryError.invalidPort }
        let normalized = try HostIdentity.canonicalHost(hostname)
        let looksLikeIPAddress = normalized.contains(":") || normalized.allSatisfy { $0.isNumber || $0 == "." }
        let isAllowedAddress = try PrivateAddressValidator.validate(normalized)
        guard !looksLikeIPAddress || isAllowedAddress else { throw InventoryError.notPrivateAddress }
        self.id = id; self.name = name; self.hostname = normalized; self.port = port; self.username = username
        self.authentication = authentication
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: try values.decode(UUID.self, forKey: .id), name: try values.decode(String.self, forKey: .name), hostname: try values.decode(String.self, forKey: .hostname), port: try values.decode(UInt16.self, forKey: .port), username: try values.decode(String.self, forKey: .username), authentication: try values.decodeIfPresent(ServerAuthentication.self, forKey: .authentication) ?? .ed25519)
    }
}
public enum InventoryError: Error, Equatable { case invalidField, invalidPort, notPrivateAddress, tooManyEntries, corruptData, storageFailure }

/// Storage whose replacement is atomic and durable before it returns successfully.
public protocol AtomicDataStore: Sendable { func read() throws -> Data?; func replace(with data: Data) throws }

/// A bounded validated inventory. All entries are revalidated on decode and before persistence.
public struct ServerInventory: Sendable {
    public static let maxEntries = 256
    private let storage: AtomicDataStore
    public init(storage: AtomicDataStore) { self.storage = storage }
    public func load() throws -> [Server] {
        guard let data = try storage.read() else { return [] }
        guard data.count <= 512 * 1024, let result = try? JSONDecoder().decode([Server].self, from: data), result.count <= Self.maxEntries, Self.hasUniqueIdentities(result) else { throw InventoryError.corruptData }
        return result
    }
    public func save(_ servers: [Server]) throws {
        guard servers.count <= Self.maxEntries else { throw InventoryError.tooManyEntries }
        guard Self.hasUniqueIdentities(servers) else { throw InventoryError.corruptData }
        let data = try JSONEncoder().encode(servers)
        guard data.count <= 512 * 1024 else { throw InventoryError.corruptData }
        do { try storage.replace(with: data) } catch { throw InventoryError.storageFailure }
    }
    private static func hasUniqueIdentities(_ servers: [Server]) -> Bool {
        var ids = Set<UUID>(); var endpoints = Set<String>()
        for server in servers {
            guard ids.insert(server.id).inserted, endpoints.insert("\(server.hostname):\(server.port)").inserted else { return false }
        }
        return true
    }
}

public enum PrivateAddressValidator {
    public static func validate(_ input: String) throws -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 255,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !value.contains(where: { $0.isWhitespace || "/\\@#".contains($0) }) else { return false }
        let host: String
        if value.hasPrefix("[") || value.hasSuffix("]") {
            guard value.hasPrefix("["), value.hasSuffix("]"), value.dropFirst().dropLast().contains(":"), !value.dropFirst().dropLast().isEmpty else { return false }
            host = String(value.dropFirst().dropLast())
        } else { host = value }
        if let v4 = IPv4Address(host) { return v4.isPrivate }
        if let v6 = IPv6Address(host) { return v6.isPrivate }
        return false
    }
}
private struct IPv4Address {
    let bytes: [UInt8]
    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.count == 1 || part.first != "0",
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = UInt16(part), number <= 255 else { return nil }
            result.append(UInt8(number))
        }
        bytes = result
    }
    var isPrivate: Bool { bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 100 && (64...127).contains(bytes[1])) }
}
private struct IPv6Address {
    let bytes: [UInt8]
    init?(_ value: String) {
        guard value.contains(":"), !value.contains("%"), let address = IPv6Address.parse(value) else { return nil }
        bytes = address
    }
    private static func parse(_ value: String) -> [UInt8]? {
        var input = value
        if input.contains(".") {
            guard let colon = input.lastIndex(of: ":") else { return nil }
            guard let ipv4 = IPv4Address(String(input[input.index(after: colon)...])) else { return nil }
            let high = UInt16(ipv4.bytes[0]) << 8 | UInt16(ipv4.bytes[1]); let low = UInt16(ipv4.bytes[2]) << 8 | UInt16(ipv4.bytes[3])
            input = String(input[..<colon]) + String(format: ":%x:%x", high, low)
        }
        let halves = input.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let left = halves[0].isEmpty ? [] : halves[0].split(separator: ":").map(String.init)
        let right = halves.count == 1 || halves[1].isEmpty ? [] : halves[1].split(separator: ":").map(String.init)
        let parts: [String]
        if halves.count == 2 {
            guard left.count + right.count < 8 else { return nil }
            parts = left + Array(repeating: "0", count: 8 - left.count - right.count) + right
        } else { guard left.count == 8 else { return nil }; parts = left }
        var output: [UInt8] = []
        for part in parts { guard !part.isEmpty, part.count <= 4, let number = UInt16(part, radix: 16) else { return nil }; output += [UInt8(number >> 8), UInt8(number & 0xff)] }
        return output.count == 16 ? output : nil
    }
    var isPrivate: Bool {
        if bytes[0] & 0xfe == 0xfc { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return IPv4Address(bytes[12...].map(String.init).joined(separator: "."))?.isPrivate ?? false }
        return false
    }
}
