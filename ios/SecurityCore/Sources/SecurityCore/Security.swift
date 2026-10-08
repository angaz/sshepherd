import Foundation
import CryptoKit

/// A normalized SSH host key identity, bound to a host and TCP port.
public struct HostIdentity: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let algorithm: String
    public let blob: Data
    /// The conventional OpenSSH SHA-256 fingerprint (`SHA256:` followed by unpadded Base64).
    public let fingerprint: String

    public init(host: String, port: UInt16, algorithm: String, blob: Data) throws {
        guard port > 0, !algorithm.isEmpty, algorithm.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }), !blob.isEmpty else {
            throw KnownHostError.invalid
        }
        self.host = try Self.canonicalHost(host)
        self.port = port
        self.algorithm = algorithm
        self.blob = blob
        self.fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try Self(host: values.decode(String.self, forKey: .host), port: values.decode(UInt16.self, forKey: .port), algorithm: values.decode(String.self, forKey: .algorithm), blob: values.decode(Data.self, forKey: .blob))
        guard try values.decode(String.self, forKey: .fingerprint) == decoded.fingerprint else { throw KnownHostError.invalid }
        self = decoded
    }

    /// Removes exactly one surrounding IPv6 bracket pair and rejects control or suffix injection.
    public static func canonicalHost(_ raw: String) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.count <= 255,
              !host.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !host.contains(where: { $0.isWhitespace || "/\\@#".contains($0) }) else { throw KnownHostError.invalid }
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]"), host.dropFirst().dropLast().contains(":"), !host.dropFirst().dropLast().isEmpty else { throw KnownHostError.invalid }
            return String(host.dropFirst().dropLast())
        }
        guard !host.contains("[") && !host.contains("]") else { throw KnownHostError.invalid }
        return host
    }
}

public enum KnownHostError: Error, Equatable { case invalid, unknown, changed, corruptData, storageFailure }

/// A synchronous, thread-safe known-host store. Replacing a key requires the exact old identity.
public protocol KnownHostStore: Sendable {
    func identity(for host: String, port: UInt16) throws -> HostIdentity?
    func trust(_ identity: HostIdentity, replacing expected: HostIdentity?) throws
}
public extension KnownHostStore {
    /// Records a first-use identity; it never replaces a different saved identity.
    func trust(_ identity: HostIdentity) throws { try trust(identity, replacing: nil) }
}

public final class InMemoryKnownHosts: KnownHostStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: HostIdentity] = [:]
    public init() {}
    private func key(_ host: String, _ port: UInt16) throws -> String { "\(try HostIdentity.canonicalHost(host)):\(port)" }
    public func identity(for host: String, port: UInt16) throws -> HostIdentity? {
        lock.lock(); defer { lock.unlock() }
        return values[try key(host, port)]
    }
    public func trust(_ identity: HostIdentity, replacing expected: HostIdentity? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let key = try key(identity.host, identity.port)
        if let existing = values[key], existing != identity && existing != expected { throw KnownHostError.changed }
        if values[key] == nil && expected != nil { throw KnownHostError.unknown }
        values[key] = identity
    }
}

/// A bounded JSON-backed known-host store. Its data store must implement atomic replacement.
public final class PersistentKnownHostStore: KnownHostStore, @unchecked Sendable {
    public static let maxEntries = 256
    private let storage: AtomicDataStore
    private let lock = NSLock()
    private var values: [String: HostIdentity]

    public init(storage: AtomicDataStore) throws {
        self.storage = storage
        guard let data = try storage.read() else { values = [:]; return }
        guard data.count <= 512 * 1024, let identities = try? JSONDecoder().decode([HostIdentity].self, from: data), identities.count <= Self.maxEntries else { throw KnownHostError.corruptData }
        var loaded: [String: HostIdentity] = [:]
        for identity in identities {
            let key = try Self.key(identity.host, identity.port)
            guard loaded[key] == nil else { throw KnownHostError.corruptData }
            loaded[key] = identity
        }
        values = loaded
    }
    private static func key(_ host: String, _ port: UInt16) throws -> String { "\(try HostIdentity.canonicalHost(host)):\(port)" }
    public func identity(for host: String, port: UInt16) throws -> HostIdentity? {
        lock.lock(); defer { lock.unlock() }
        return values[try Self.key(host, port)]
    }
    public func trust(_ identity: HostIdentity, replacing expected: HostIdentity? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let key = try Self.key(identity.host, identity.port)
        if let existing = values[key], existing != identity && existing != expected { throw KnownHostError.changed }
        if values[key] == nil && expected != nil { throw KnownHostError.unknown }
        var replacement = values; replacement[key] = identity
        guard replacement.count <= Self.maxEntries else { throw KnownHostError.corruptData }
        let encoded = try JSONEncoder().encode(replacement.values.sorted { Self.sortKey($0) < Self.sortKey($1) })
        guard encoded.count <= 512 * 1024 else { throw KnownHostError.corruptData }
        do { try storage.replace(with: encoded) } catch { throw KnownHostError.storageFailure }
        values = replacement
    }
    private static func sortKey(_ identity: HostIdentity) -> String { "\(identity.host):\(identity.port)" }
}

public enum HostKeyDecision: Equatable { case accepted, needsConfirmation, rejectedChanged }
public func verifyHostKey(_ presented: HostIdentity, using store: KnownHostStore) throws -> HostKeyDecision {
    guard let saved = try store.identity(for: presented.host, port: presented.port) else { return .needsConfirmation }
    return saved.algorithm == presented.algorithm && saved.blob == presented.blob ? .accepted : .rejectedChanged
}

public enum CredentialKind: String, Codable, Sendable { case password, privateKey }
public enum KeychainError: Error, Equatable { case unavailable, notFound, invalidData, accessDenied, failure(OSStatusCode) }
public struct OSStatusCode: Equatable, Sendable { public let value: Int32; public init(_ value: Int32) { self.value = value } }
public enum KeychainAccessibility: Sendable { case whenUnlockedThisDeviceOnly }

/// Secret storage segregated by server and credential kind.
public protocol SecretStore: Sendable {
    func read(serverID: UUID, kind: CredentialKind) throws -> Data
    func save(_ data: Data, serverID: UUID, kind: CredentialKind) throws
    func delete(serverID: UUID, kind: CredentialKind) throws
}
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: Data] = [:]
    public init() {}
    public func read(serverID: UUID, kind: CredentialKind) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = values[CredentialKey(serverID, kind)] else { throw KeychainError.notFound }; return data
    }
    public func save(_ data: Data, serverID: UUID, kind: CredentialKind) throws {
        guard !data.isEmpty else { throw KeychainError.invalidData }
        lock.lock(); defer { lock.unlock() }; values[CredentialKey(serverID, kind)] = data
    }
    public func delete(serverID: UUID, kind: CredentialKind) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: CredentialKey(serverID, kind)) }
}
private struct CredentialKey: Hashable { let serverID: UUID; let kind: CredentialKind; init(_ serverID: UUID, _ kind: CredentialKind) { self.serverID = serverID; self.kind = kind } }

#if canImport(Security)
import Security
/// Keychain storage configured for non-synchronizing, device-only secrets.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String; private let accessibility: CFString
    public init(service: String = "io.angaz.sshepherd.ios.security", accessibility: KeychainAccessibility = .whenUnlockedThisDeviceOnly) { self.service = service; self.accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
    private func query(_ id: UUID, _ kind: CredentialKind) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "server.\(id.uuidString).\(kind.rawValue)", kSecAttrSynchronizable as String: false] }
    public func read(serverID: UUID, kind: CredentialKind) throws -> Data {
        var query = query(serverID, kind); query[kSecReturnData as String] = true
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.failure(OSStatusCode(status)) }; return data
    }
    public func save(_ data: Data, serverID: UUID, kind: CredentialKind) throws {
        guard !data.isEmpty else { throw KeychainError.invalidData }
        let query = query(serverID, kind)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.failure(OSStatusCode(status)) }
        var add = query; add.merge(update) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.failure(OSStatusCode(addStatus)) }
    }
    public func delete(serverID: UUID, kind: CredentialKind) throws { let status = SecItemDelete(query(serverID, kind) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.failure(OSStatusCode(status)) } }
}
#endif

public struct SSHKey: Sendable {
    private let key: Curve25519.Signing.PrivateKey
    public init() { key = .init() }
    public init(rawRepresentation: Data) throws { key = try .init(rawRepresentation: rawRepresentation) }
    public var privateKey: Data { key.rawRepresentation }
    public var authorizedKeysLine: String { "ssh-ed25519 \(publicKeyBlob.base64EncodedString())" }
    public var publicKeyBlob: Data { SSHWire.string(Data("ssh-ed25519".utf8)) + SSHWire.string(key.publicKey.rawRepresentation) }
    public func signature(for data: Data) throws -> Data { try key.signature(for: data) }
    public func save(to store: SecretStore, serverID: UUID) throws { try store.save(privateKey, serverID: serverID, kind: .privateKey) }
    public static func load(from store: SecretStore, serverID: UUID) throws -> SSHKey { try SSHKey(rawRepresentation: store.read(serverID: serverID, kind: .privateKey)) }
    public static func verify(signature: Data, for data: Data, authorizedKeysLine: String) throws -> Bool {
        let fields = authorizedKeysLine.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0] == "ssh-ed25519", let blob = Data(base64Encoded: String(fields[1])) else { throw KnownHostError.invalid }
        let (algorithm, offset) = try SSHWire.readString(blob, at: 0)
        let (publicKey, end) = try SSHWire.readString(blob, at: offset)
        guard algorithm == Data("ssh-ed25519".utf8), end == blob.count, publicKey.count == 32 else { throw KnownHostError.invalid }
        return try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: data)
    }
}
private enum SSHWire {
    static func string(_ data: Data) -> Data { var count = UInt32(data.count).bigEndian; return Data(bytes: &count, count: 4) + data }
    static func readString(_ data: Data, at offset: Int) throws -> (Data, Int) {
        guard offset >= 0, data.count - offset >= 4 else { throw KnownHostError.invalid }
        let count = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard count <= UInt32(data.count - offset - 4) else { throw KnownHostError.invalid }
        let end = offset + 4 + Int(count); return (data[offset + 4..<end], end)
    }
}
