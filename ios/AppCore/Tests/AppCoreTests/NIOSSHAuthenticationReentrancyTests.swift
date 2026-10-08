@testable import AppCore
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SecurityCore
import Testing

private final class ReentrantAuthenticationSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let raw: Data
    private let onRead: @Sendable () -> Void
    init(mode: SSHAuthenticationMode, onRead: @escaping @Sendable () -> Void = {}) {
        raw = mode == .password ? Data("synthetic-fixture-password".utf8) : Curve25519.Signing.PrivateKey().rawRepresentation
        self.onRead = onRead
    }
    func read(serverID: UUID, kind: CredentialKind) throws -> Data {
        lock.lock(); reads += 1; lock.unlock()
        onRead()
        return raw
    }
    func save(_ data: Data, serverID: UUID, kind: CredentialKind) throws { throw KeychainError.accessDenied }
    func delete(serverID: UUID, kind: CredentialKind) throws { throw KeychainError.accessDenied }
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
}
private final class AuthenticationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    func record(_ value: String) { lock.lock(); labels.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return labels }
}
private final class AuthenticationDelegateReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var delegate: KeychainAuthenticationDelegate?
    func set(_ value: KeychainAuthenticationDelegate) { lock.lock(); delegate = value; lock.unlock() }
    func get() -> KeychainAuthenticationDelegate? { lock.lock(); defer { lock.unlock() }; return delegate }
}
private func authenticationConfiguration(mode: SSHAuthenticationMode, secrets: ReentrantAuthenticationSecrets,
                                         hook: @escaping @Sendable (String) -> Void) -> SSHTransportConfiguration {
    .init(serverID: UUID(), host: "127.0.0.1", port: 22, username: "synthetic-fixture", authentication: mode,
          knownHosts: InMemoryKnownHosts(), secrets: secrets, confirmUnknownFingerprint: { _ in false }, lifecycleEvent: hook)
}
private func availableAuthentication(_ mode: SSHAuthenticationMode) -> NIOSSHAvailableUserAuthenticationMethods {
    mode == .password ? .password : .publicKey
}
private func invokeAuthentication(on loop: EventLoop, delegate: KeychainAuthenticationDelegate,
                                  methods: NIOSSHAvailableUserAuthenticationMethods,
                                  results: AuthenticationResults) async throws -> SSHTransportError? {
    let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    promise.futureResult.whenComplete {
        switch $0 {
        case .success(let offer): results.record(offer == nil ? "nil-offer" : "offer")
        case .failure: results.record("rejected")
        }
    }
    // Real synchronous delegate invocation on the original NIO event loop, not an async fake transport.
    try await loop.submit { delegate.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise) }.get()
    do { _ = try await promise.futureResult.get(); return nil }
    catch { return error as? SSHTransportError }
}

@Test(arguments: [SSHAuthenticationMode.password, .ed25519])
func nioSSHAuthenticationCredentialReadHookRevocationPreventsAllStoreReads(mode: SSHAuthenticationMode) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), results = AuthenticationResults()
    let secrets = ReentrantAuthenticationSecrets(mode: mode)
    try gate.open()
    let delegate = KeychainAuthenticationDelegate(configuration: authenticationConfiguration(mode: mode, secrets: secrets) { label in
        results.record(label)
        if label == "credential-read" { gate.fail(.closed) }
    }, gate: gate)
    #expect(try await invokeAuthentication(on: group.next(), delegate: delegate, methods: availableAuthentication(mode), results: results) == .closed)
    #expect(secrets.readCount() == 0)
    #expect(results.snapshot() == ["credential-read", "rejected"])
    try await group.shutdownGracefully()
}

@Test(arguments: [SSHAuthenticationMode.password, .ed25519])
func nioSSHAuthenticationOfferedHookRevocationPreventsSuccessfulPromiseOffer(mode: SSHAuthenticationMode) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), results = AuthenticationResults()
    let secrets = ReentrantAuthenticationSecrets(mode: mode)
    try gate.open()
    let delegate = KeychainAuthenticationDelegate(configuration: authenticationConfiguration(mode: mode, secrets: secrets) { label in
        results.record(label)
        if label == "authentication-offered" { gate.fail(.closed) }
    }, gate: gate)
    #expect(try await invokeAuthentication(on: group.next(), delegate: delegate, methods: availableAuthentication(mode), results: results) == .closed)
    #expect(secrets.readCount() == 1)
    #expect(results.snapshot() == ["credential-read", "authentication-offered", "rejected"])
    try await group.shutdownGracefully()
}

@Test(arguments: [SSHAuthenticationMode.password, .ed25519])
func nioSSHAuthenticationStoreReadRevocationPreventsOffer(mode: SSHAuthenticationMode) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), results = AuthenticationResults()
    let secrets = ReentrantAuthenticationSecrets(mode: mode, onRead: { gate.fail(.closed) })
    try gate.open()
    let delegate = KeychainAuthenticationDelegate(configuration: authenticationConfiguration(mode: mode, secrets: secrets) { results.record($0) }, gate: gate)
    #expect(try await invokeAuthentication(on: group.next(), delegate: delegate, methods: availableAuthentication(mode), results: results) == .closed)
    #expect(secrets.readCount() == 1)
    #expect(results.snapshot() == ["credential-read", "rejected"])
    try await group.shutdownGracefully()
}

@Test(arguments: [SSHAuthenticationMode.password, .ed25519])
func nioSSHAuthenticationMethodMismatchConsumesOneAttemptWithoutReadingSecrets(mode: SSHAuthenticationMode) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), results = AuthenticationResults()
    let secrets = ReentrantAuthenticationSecrets(mode: mode)
    try gate.open()
    let delegate = KeychainAuthenticationDelegate(configuration: authenticationConfiguration(mode: mode, secrets: secrets) { results.record($0) }, gate: gate)
    #expect(try await invokeAuthentication(on: group.next(), delegate: delegate,
        methods: mode == .password ? .publicKey : .password, results: results) == .authenticationUnavailable)
    #expect(try await invokeAuthentication(on: group.next(), delegate: delegate,
        methods: availableAuthentication(mode), results: results) == .authenticationUnavailable)
    #expect(secrets.readCount() == 0)
    #expect(results.snapshot() == ["rejected", "rejected"])
    try await group.shutdownGracefully()
}

@Test(arguments: [SSHAuthenticationMode.password, .ed25519])
func nioSSHAuthenticationLiveAttemptOffersOnceAndRejectsRepeat(mode: SSHAuthenticationMode) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), results = AuthenticationResults()
    let secrets = ReentrantAuthenticationSecrets(mode: mode)
    try gate.open()
    let delegate = KeychainAuthenticationDelegate(configuration: authenticationConfiguration(mode: mode, secrets: secrets) { results.record($0) }, gate: gate)
    #expect(try await invokeAuthentication(on: group.next(), delegate: delegate, methods: availableAuthentication(mode), results: results) == nil)
    #expect(try await invokeAuthentication(on: group.next(), delegate: delegate, methods: availableAuthentication(mode), results: results) == .authenticationUnavailable)
    #expect(secrets.readCount() == 1)
    #expect(results.snapshot() == ["credential-read", "authentication-offered", "offer", "rejected"])
    try await group.shutdownGracefully()
}

@Test(arguments: [SSHAuthenticationMode.password, .ed25519])
func nioSSHAuthenticationHooksCanSynchronouslyReenterDelegateWithoutDeadlock(mode: SSHAuthenticationMode) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), results = AuthenticationResults()
    let loop = group.next(), reference = AuthenticationDelegateReference(), secrets = ReentrantAuthenticationSecrets(mode: mode)
    try gate.open()
    let delegate = KeychainAuthenticationDelegate(configuration: authenticationConfiguration(mode: mode, secrets: secrets) { label in
        results.record(label)
        let nested = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        nested.futureResult.whenComplete {
            switch $0 {
            case .success: Issue.record("Reentrant request offered credentials")
            case .failure(let error):
                #expect(error as? SSHTransportError == .authenticationUnavailable)
                results.record("nested-rejected")
            }
        }
        reference.get()?.nextAuthenticationType(availableMethods: availableAuthentication(mode), nextChallengePromise: nested)
    }, gate: gate)
    reference.set(delegate)
    #expect(try await invokeAuthentication(on: loop, delegate: delegate, methods: availableAuthentication(mode), results: results) == nil)
    #expect(secrets.readCount() == 1)
    #expect(results.snapshot() == ["credential-read", "nested-rejected", "authentication-offered", "nested-rejected", "offer"])
    try await group.shutdownGracefully()
}
