import XCTest
@testable import SecurityCore

final class SecurityCoreTests: XCTestCase {
    func testPrivateAddressRulesMappedIPv6AndMalformedInputs() throws {
        XCTAssertTrue(try PrivateAddressValidator.validate("10.1.2.3"))
        XCTAssertTrue(try PrivateAddressValidator.validate("fd00::1"))
        XCTAssertTrue(try PrivateAddressValidator.validate("::ffff:10.1.2.3"))
        XCTAssertFalse(try PrivateAddressValidator.validate("::ffff:8.8.8.8"))
        XCTAssertFalse(try PrivateAddressValidator.validate("999999999999999999999999.1.1.1"))
        XCTAssertFalse(try PrivateAddressValidator.validate("[fd00::1]suffix"))
        XCTAssertFalse(try PrivateAddressValidator.validate("fd00::1\npassword"))
        XCTAssertFalse(try PrivateAddressValidator.validate("example.com"))
    }

    func testIPv4OctetsMustBeCanonicalASCIIDecimal() throws {
        for address in ["010.0.0.1", "10.001.2.3", "10.1.2.003", "::ffff:010.0.0.1", "10.1.2.٣"] {
            XCTAssertFalse(try PrivateAddressValidator.validate(address), address)
            XCTAssertThrowsError(try Server(name: "Ambiguous", hostname: address, username: "u"))
        }
        XCTAssertTrue(try PrivateAddressValidator.validate("10.0.0.1"))
        XCTAssertTrue(try PrivateAddressValidator.validate("::ffff:10.0.0.1"))
    }

    func testInventoryRejectsInvalidDecodedDuplicateAndOversizedData() throws {
        let storage = MemoryDataStore()
        let inventory = ServerInventory(storage: storage)
        XCTAssertEqual(try inventory.load(), [])
        storage.data = Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"bad\",\"hostname\":\"8.8.8.8\",\"port\":22,\"username\":\"u\"}]".utf8)
        XCTAssertThrowsError(try inventory.load()) { XCTAssertEqual($0 as? InventoryError, .corruptData) }
        let server = try Server(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "one", hostname: "192.168.1.4", username: "u")
        let sameEndpoint = try Server(name: "two", hostname: "192.168.1.4", username: "u")
        storage.data = try JSONEncoder().encode([server, server])
        XCTAssertThrowsError(try inventory.load()) { XCTAssertEqual($0 as? InventoryError, .corruptData) }
        storage.data = try JSONEncoder().encode([server, sameEndpoint])
        XCTAssertThrowsError(try inventory.load()) { XCTAssertEqual($0 as? InventoryError, .corruptData) }
        storage.data = Data(repeating: 0, count: 512 * 1024 + 1)
        XCTAssertThrowsError(try inventory.load()) { XCTAssertEqual($0 as? InventoryError, .corruptData) }
    }

    func testInventoryPreservesPriorContentsOnAtomicFailure() throws {
        let storage = MemoryDataStore(); let inventory = ServerInventory(storage: storage)
        let server = try Server(name: "one", hostname: "10.0.0.1", username: "u")
        try inventory.save([server]); let before = storage.data
        storage.shouldFail = true
        XCTAssertThrowsError(try inventory.save([try Server(name: "two", hostname: "10.0.0.2", username: "u")])) { XCTAssertEqual($0 as? InventoryError, .storageFailure) }
        XCTAssertEqual(storage.data, before)
    }

    func testKnownHostFirstTrustDoesNotReplaceChangedKeyAndAlgorithmIsBound() throws {
        let store = InMemoryKnownHosts(); let original = try HostIdentity(host: "[fd00::1]", port: 22, algorithm: "ssh-ed25519", blob: Data([1, 2]))
        try store.trust(original)
        XCTAssertEqual(try verifyHostKey(original, using: store), .accepted)
        let changed = try HostIdentity(host: "fd00::1", port: 22, algorithm: "ssh-ed25519", blob: Data([2]))
        let substituted = try HostIdentity(host: "fd00::1", port: 22, algorithm: "rsa-sha2-512", blob: Data([1, 2]))
        XCTAssertEqual(try verifyHostKey(changed, using: store), .rejectedChanged)
        XCTAssertEqual(try verifyHostKey(substituted, using: store), .rejectedChanged)
        XCTAssertThrowsError(try store.trust(changed)) { XCTAssertEqual($0 as? KnownHostError, .changed) }
        XCTAssertNoThrow(try store.trust(changed, replacing: original))
        XCTAssertEqual(try verifyHostKey(changed, using: store), .accepted)
        XCTAssertThrowsError(try HostIdentity.canonicalHost("[fd00::1]evil"))
    }

    func testPersistentKnownHostsRejectsCorruptionAndDuplicateEntries() throws {
        let storage = MemoryDataStore()
        let key = try HostIdentity(host: "fd00::1", port: 22, algorithm: "ssh-ed25519", blob: Data([1]))
        storage.data = try JSONEncoder().encode([key, key])
        XCTAssertThrowsError(try PersistentKnownHostStore(storage: storage)) { XCTAssertEqual($0 as? KnownHostError, .corruptData) }
        storage.data = nil
        let store = try PersistentKnownHostStore(storage: storage)
        try store.trust(key)
        XCTAssertEqual(try PersistentKnownHostStore(storage: storage).identity(for: "fd00::1", port: 22), key)
    }

    func testPersistentKnownHostsCapacityRejectsWithoutMutationAndAllowsReviewedReplacement() throws {
        let storage = MemoryDataStore(), store = try PersistentKnownHostStore(storage: storage)
        let identities = try (0..<256).map {
            try HostIdentity(host: "fixture-\($0)", port: 22, algorithm: "ssh-ed25519", blob: Data([1]))
        }
        for identity in identities { try store.trust(identity) }
        let before = storage.data
        let extra = try HostIdentity(host: "fixture-extra", port: 22, algorithm: "ssh-ed25519", blob: Data([1]))
        XCTAssertThrowsError(try store.trust(extra)) { XCTAssertEqual($0 as? KnownHostError, .corruptData) }
        XCTAssertEqual(storage.data, before)
        XCTAssertNil(try store.identity(for: extra.host, port: 22))
        let reloaded = try PersistentKnownHostStore(storage: storage)
        for identity in identities { XCTAssertEqual(try reloaded.identity(for: identity.host, port: 22), identity) }
        let changed = try HostIdentity(host: identities[0].host, port: 22, algorithm: "ssh-ed25519", blob: Data([2]))
        try store.trust(changed, replacing: identities[0])
        XCTAssertEqual(try PersistentKnownHostStore(storage: storage).identity(for: changed.host, port: 22), changed)
    }

    func testPersistentKnownHostsAtomicWriteFailurePreservesMemoryAndBytes() throws {
        let storage = MemoryDataStore(), store = try PersistentKnownHostStore(storage: storage)
        let first = try HostIdentity(host: "fd00::1", port: 22, algorithm: "ssh-ed25519", blob: Data([1]))
        let next = try HostIdentity(host: "fd00::1", port: 22, algorithm: "ssh-ed25519", blob: Data([2]))
        try store.trust(first); let before = storage.data
        storage.shouldFail = true
        XCTAssertThrowsError(try store.trust(next, replacing: first)) { XCTAssertEqual($0 as? KnownHostError, .storageFailure) }
        XCTAssertEqual(storage.data, before)
        XCTAssertEqual(try store.identity(for: first.host, port: 22), first)
        XCTAssertEqual(try PersistentKnownHostStore(storage: storage).identity(for: first.host, port: 22), first)
    }

    func testPersistentKnownHostsConcurrentConflictingFirstTrustHasOneWinner() throws {
        let storage = MemoryDataStore(), store = try PersistentKnownHostStore(storage: storage)
        let candidates = try [1, 2].map {
            try HostIdentity(host: "fd00::1", port: 22, algorithm: "ssh-ed25519", blob: Data([UInt8($0)]))
        }
        let results = TrustResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do { try store.trust(candidates[index]); results.record(nil) }
            catch { results.record(error as? KnownHostError) }
        }
        XCTAssertEqual(results.successes, 1)
        XCTAssertEqual(results.errors, [.changed])
        let saved = try XCTUnwrap(store.identity(for: "fd00::1", port: 22))
        XCTAssertTrue(candidates.contains(saved))
        XCTAssertEqual(try PersistentKnownHostStore(storage: storage).identity(for: "fd00::1", port: 22), saved)
    }

    func testCredentialKindsDoNotCollideAndKeyRoundTripsSignature() throws {
        let store = InMemorySecretStore(); let id = UUID()
        try store.save(Data("password".utf8), serverID: id, kind: .password)
        let key = SSHKey(); try key.save(to: store, serverID: id)
        XCTAssertEqual(try store.read(serverID: id, kind: .password), Data("password".utf8))
        let loaded = try SSHKey.load(from: store, serverID: id)
        let message = Data("known vector message".utf8); let signature = try loaded.signature(for: message)
        XCTAssertTrue(try SSHKey.verify(signature: signature, for: message, authorizedKeysLine: key.authorizedKeysLine))
        XCTAssertFalse(try SSHKey.verify(signature: signature, for: Data("other".utf8), authorizedKeysLine: key.authorizedKeysLine))
    }

    func testConventionalKnownFingerprintVector() throws {
        let identity = try HostIdentity(host: "fd00::1", port: 22, algorithm: "ssh-ed25519", blob: Data("abc".utf8))
        XCTAssertEqual(identity.fingerprint, "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }

    func testStoresRemainSafeUnderConcurrentAccess() throws {
        let secrets = InMemorySecretStore(); let hosts = InMemoryKnownHosts(); let id = UUID()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            try? secrets.save(Data("\(index)".utf8), serverID: id, kind: .password)
            _ = try? secrets.read(serverID: id, kind: .password)
            let identity = try! HostIdentity(host: "fd00::\(index % 4)", port: 22, algorithm: "ssh-ed25519", blob: Data([UInt8(index % 4)]))
            try? hosts.trust(identity)
            _ = try? hosts.identity(for: identity.host, port: 22)
        }
        XCTAssertNoThrow(try secrets.read(serverID: id, kind: .password))
    }
}

private final class MemoryDataStore: AtomicDataStore, @unchecked Sendable {
    var data: Data?
    var shouldFail = false
    func read() throws -> Data? { data }
    func replace(with data: Data) throws { if shouldFail { throw InventoryError.storageFailure }; self.data = data }
}

private final class TrustResults: @unchecked Sendable {
    private let lock = NSLock()
    var successes = 0
    var errors: [KnownHostError] = []
    func record(_ error: KnownHostError?) {
        lock.lock(); defer { lock.unlock() }
        if let error { errors.append(error) } else { successes += 1 }
    }
}
