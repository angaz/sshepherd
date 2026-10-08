import AppUI
import Crypto
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SecurityCore

public enum SSHTransportError: Error, Equatable, Sendable {
    case invalidEndpoint
    case noTrustedAddress
    case endpointMismatch
    case unknownHostRejected
    case changedHostKey
    case authenticationUnavailable
    case requestRejected
    case timedOut
    case closed
    case queueFull
}

/// Bounded diagnostic metadata only; never includes Error.description, NSError.userInfo, or SSH/terminal payloads.
public struct SSHConnectionDiagnostic: Codable, Equatable, Sendable {
    public let category: String
    public let posixErrno: Int32?
    public let nsErrorDomain: String?
    public let nsErrorCode: Int?
    public let address: String?
    public let port: Int?
    public let addressFamily: String?
    public let underlyingCount: Int
    public let underlying: [SSHConnectionDiagnostic]

    public static func capture(_ error: Error, address: SocketAddress? = nil) -> Self {
        capture(error, address: address, depth: 0)
    }

    private static func capture(_ error: Error, address: SocketAddress?, depth: Int) -> Self {
        var category = "other"
        var errno: Int32?
        var domain: String?
        var code: Int?
        var count = 0
        var children: [Self] = []
        if let failure = error as? IOError {
            category = "posixIOError"; errno = failure.errnoCode
        } else if let failure = error as? NIOConnectionError {
            category = "nioConnectionError"
            count = failure.connectionErrors.count + (failure.dnsAError == nil ? 0 : 1) + (failure.dnsAAAAError == nil ? 0 : 1)
            if depth < 1 {
                children = failure.connectionErrors.prefix(2).map { capture($0.error, address: $0.target, depth: depth + 1) }
                for dnsError in [failure.dnsAError, failure.dnsAAAAError].compactMap({ $0 }) {
                    children.append(capture(dnsError, address: nil, depth: depth + 1))
                }
            }
        } else if let failure = error as? ChannelError {
            switch failure {
            case .connectTimeout: category = "tcpConnectTimeout"
            case .connectPending: category = "tcpConnectPending"
            case .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed: category = "channelClosed"
            case .eof: category = "channelEOF"
            default: category = "nioChannelError"
            }
        } else if let failure = error as? SSHTransportError {
            category = "sshTransport." + String(describing: failure) // Payload-free enum only.
        } else if let failure = error as? KeychainError {
            switch failure {
            case .unavailable: category = "keychainUnavailable"
            case .notFound: category = "keychainNotFound"
            case .invalidData: category = "keychainInvalidData"
            case .accessDenied: category = "keychainAccessDenied"
            case .failure(let status): category = "keychainOSStatus"; domain = NSOSStatusErrorDomain; code = Int(status.value)
            }
        } else if error is CancellationError {
            category = "cancelled"
        } else {
            let failure = error as NSError
            // Unknown domains may be arbitrary caller strings; never persist them verbatim.
            let approved = [NSPOSIXErrorDomain, NSCocoaErrorDomain, NSURLErrorDomain, NSOSStatusErrorDomain]
            domain = approved.contains(failure.domain) ? failure.domain : "other"
            code = failure.code
            category = "nsError"
            if failure.domain == NSPOSIXErrorDomain { errno = Int32(exactly: failure.code) }
        }
        let family: String?
        switch address {
        case .v4?: family = "ipv4"
        case .v6?: family = "ipv6"
        case .unixDomainSocket?: family = "unix"
        case nil: family = nil
        }
        return Self(category: category, posixErrno: errno, nsErrorDomain: domain, nsErrorCode: code,
                    address: address?.ipAddress, port: address?.port, addressFamily: family,
                    underlyingCount: count, underlying: children)
    }
}

public enum SSHAuthenticationMode: String, Codable, Sendable { case password, ed25519 }

public struct SSHTransportConfiguration: Sendable {
    public let serverID: UUID
    public let host: String
    public let port: UInt16
    public let username: String
    public let authentication: SSHAuthenticationMode
    public let knownHosts: any KnownHostStore
    public let secrets: any SecretStore
    public let confirmUnknownFingerprint: @Sendable (HostIdentity) async -> Bool
    /// Test/diagnostic hook. Values never contain credentials or terminal bytes.
    public let lifecycleEvent: @Sendable (String) -> Void
    public let diagnosticFailure: @Sendable (SSHConnectionDiagnostic) -> Void

    public init(serverID: UUID, host: String, port: UInt16, username: String,
                authentication: SSHAuthenticationMode, knownHosts: any KnownHostStore,
                secrets: any SecretStore,
                confirmUnknownFingerprint: @escaping @Sendable (HostIdentity) async -> Bool,
                lifecycleEvent: @escaping @Sendable (String) -> Void = { _ in },
                diagnosticFailure: @escaping @Sendable (SSHConnectionDiagnostic) -> Void = { _ in }) {
        self.serverID = serverID; self.host = host; self.port = port; self.username = username
        self.authentication = authentication; self.knownHosts = knownHosts; self.secrets = secrets
        self.confirmUnknownFingerprint = confirmUnknownFingerprint; self.lifecycleEvent = lifecycleEvent
        self.diagnosticFailure = diagnosticFailure
    }
}

// A revoker acknowledges enqueueing before another caller may start event-loop shutdown.
private final class RevocationDelivery: @unchecked Sendable {
    private let condition = NSCondition()
    private var delivered = false
    func acknowledge() { condition.lock(); delivered = true; condition.broadcast(); condition.unlock() }
    func wait() { condition.lock(); while !delivered { condition.wait() }; condition.unlock() }
}

// Claim before enqueueing, and enqueue before releasing the lock. Late consent never touches the loop.
final class HostValidationCompletion: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var pending = true
    private let promise: EventLoopPromise<Void>
    private let didDeliver: @Sendable (UUID) -> Void
    init(promise: EventLoopPromise<Void>, didDeliver: @escaping @Sendable (UUID) -> Void) {
        self.promise = promise; self.didDeliver = didDeliver
    }
    func isPending() -> Bool { lock.lock(); defer { lock.unlock() }; return pending }
    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard pending else { lock.unlock(); return }
        pending = false
        promise.futureResult.eventLoop.execute {
            // Barrier: never run promise callbacks while the completion-owner lock is held.
            self.lock.lock(); self.lock.unlock()
            self.didDeliver(self.id)
            self.promise.completeWith(result)
        }
        lock.unlock()
    }
}

// Retirement and enqueue are one atomic handoff. A retired producer never even reads the event loop.
final class EventLoopEnqueueOwner: @unchecked Sendable {
    let id = UUID()
    private let didRetire: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var active = true
    private let eventLoop: EventLoop
    init(eventLoop: EventLoop, didRetire: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.eventLoop = eventLoop; self.didRetire = didRetire
    }
    @discardableResult func enqueue(_ operation: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        eventLoop.execute {
            self.lock.lock(); self.lock.unlock()
            operation()
        }
        lock.unlock()
        return true
    }
    func retire() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false; lock.unlock()
        didRetire(id)
    }
}

// Shared with cancellation handlers: revocation is synchronous, not an actor hop.
final class TrustGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var trusted = false
    private var confirmationWindow = false
    private var waitingForConsent = false
    private var storedFailure: SSHTransportError?
    private var channels: [Channel] = []
    private var abort: (@Sendable () -> Void)?
    private var consentTasks: [UUID: Task<Void, Never>] = [:]
    private var validations: [UUID: HostValidationCompletion] = [:]
    private var producers: [UUID: EventLoopEnqueueOwner] = [:]
    private var ioCompletions: [UUID: IOCompletion] = [:]
    private var delivery: RevocationDelivery?
    func beginConfirmationWindow() { lock.lock(); if storedFailure == nil { confirmationWindow = true }; lock.unlock() }
    func open() throws {
        lock.lock(); defer { lock.unlock() }
        if let storedFailure { throw storedFailure }
        trusted = true; confirmationWindow = false; waitingForConsent = false
    }
    func register(_ channel: Channel) throws {
        lock.lock()
        if let storedFailure {
            lock.unlock(); channel.close(promise: nil); throw storedFailure
        }
        channels.append(channel)
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in self?.fail(.closed) }
    }
    func installAbort(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); abort = callback; let failed = storedFailure != nil; lock.unlock()
        if failed { callback() }
    }
    func registerProducer(_ producer: EventLoopEnqueueOwner) {
        lock.lock()
        let failed = storedFailure != nil
        if !failed { producers[producer.id] = producer }
        lock.unlock()
        if failed { producer.retire() }
    }
    func finishProducer(_ id: UUID) { lock.lock(); producers[id] = nil; lock.unlock() }
    func registerIO(_ completion: IOCompletion) {
        lock.lock()
        if let storedFailure {
            lock.unlock(); completion.complete(.failure(storedFailure)); return
        }
        ioCompletions[completion.id] = completion
        lock.unlock()
    }
    func finishIO(_ id: UUID) { lock.lock(); ioCompletions[id] = nil; lock.unlock() }
    func registerValidation(_ completion: HostValidationCompletion) {
        lock.lock()
        if let storedFailure {
            lock.unlock()
            completion.complete(.failure(storedFailure))
            return
        }
        validations[completion.id] = completion
        lock.unlock()
    }
    func finishValidation(_ id: UUID) { lock.lock(); validations[id] = nil; lock.unlock() }
    func installConsent(_ task: Task<Void, Never>, id: UUID) {
        lock.lock()
        let rejected = storedFailure != nil || validations[id]?.isPending() != true
        if !rejected { consentTasks[id] = task }
        lock.unlock()
        if rejected { task.cancel() }
    }
    func finishConsent(_ id: UUID) { lock.lock(); consentTasks[id] = nil; lock.unlock() }
    func fail(_ error: SSHTransportError) {
        lock.lock()
        if let delivery {
            lock.unlock()
            delivery.wait() // No gate lock or event-loop completion wait is held here.
            return
        }
        let acknowledgement = RevocationDelivery()
        delivery = acknowledgement
        storedFailure = error
        trusted = false; confirmationWindow = false; waitingForConsent = false
        let callback = abort, tasks = Array(consentTasks.values), closing = channels
        let cancelling = Array(validations.values), stoppingIO = Array(ioCompletions.values), retiring = Array(producers.values)
        abort = nil; consentTasks = [:]; channels = []; validations = [:]; ioCompletions = [:]; producers = [:]
        lock.unlock()
        // These operations only retire or claim/enqueue. They cannot run promise callbacks synchronously.
        for producer in retiring { producer.retire() }
        for completion in stoppingIO { completion.complete(.failure(error)) }
        for completion in cancelling { completion.complete(.failure(error)) }
        callback?()
        for channel in closing {
            channel.eventLoop.execute { channel.close(promise: nil) }
        }
        acknowledgement.acknowledge()
        // Late consent has already lost completion ownership; Swift cancellation cannot touch the loop.
        for task in tasks { task.cancel() }
    }
    func beginConsent() { lock.lock(); waitingForConsent = confirmationWindow && storedFailure == nil; lock.unlock() }
    func isWaitingForConsent() -> Bool { lock.lock(); defer { lock.unlock() }; return waitingForConsent }
    func failure() -> SSHTransportError? { lock.lock(); defer { lock.unlock() }; return storedFailure }
    func approve(_ persist: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if let storedFailure { throw storedFailure }
        if !confirmationWindow { throw SSHTransportError.closed }
        try persist()
        trusted = true; confirmationWindow = false; waitingForConsent = false
    }
    // Serialize trust revocation with credential/PTY/exec side effects, not only the preceding check.
    func withOpen<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if let storedFailure { throw storedFailure }
        guard trusted else { throw SSHTransportError.authenticationUnavailable }
        return try operation()
    }
}

final class VerifyingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let configuration: SSHTransportConfiguration
    private let gate: TrustGate
    init(configuration: SSHTransportConfiguration, gate: TrustGate) { self.configuration = configuration; self.gate = gate }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let completion = HostValidationCompletion(promise: validationCompletePromise) { [gate, configuration] id in
            gate.finishValidation(id)
            configuration.lifecycleEvent("host-key-validation-completed")
        }
        gate.registerValidation(completion)
        guard completion.isPending(), gate.failure() == nil else { return }
        let fields = String(openSSHPublicKey: hostKey).split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])),
              let identity = try? HostIdentity(host: configuration.host, port: configuration.port,
                                               algorithm: String(fields[0]), blob: blob) else {
            gate.fail(.changedHostKey)
            completion.complete(.failure(SSHTransportError.changedHostKey)); return
        }
        do {
            switch try verifyHostKey(identity, using: configuration.knownHosts) {
            case .accepted:
                configuration.lifecycleEvent("host-key-accepted")
                try gate.open(); completion.complete(.success(()))
            case .rejectedChanged:
                configuration.lifecycleEvent("host-key-changed")
                gate.fail(.changedHostKey)
                completion.complete(.failure(SSHTransportError.changedHostKey))
            case .needsConfirmation:
                gate.beginConsent()
                configuration.lifecycleEvent("host-key-confirmation-requested")
                let consent = Task {
                    defer { self.gate.finishConsent(completion.id); configuration.lifecycleEvent("host-key-confirmation-finished") }
                    let accepted = await configuration.confirmUnknownFingerprint(identity)
                    // Revocation has already claimed validation completion. Never persist or touch a stopped loop.
                    guard !Task.isCancelled, completion.isPending(), self.gate.failure() == nil else { return }
                    guard accepted else { self.gate.fail(.unknownHostRejected); return }
                    do {
                        try self.gate.approve { try configuration.knownHosts.trust(identity) }
                        configuration.lifecycleEvent("host-key-confirmed")
                        completion.complete(.success(()))
                    } catch { completion.complete(.failure(error)) }
                }
                gate.installConsent(consent, id: completion.id)
            }
        } catch { completion.complete(.failure(error)) }
    }
}

final class KeychainAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let configuration: SSHTransportConfiguration
    private let gate: TrustGate
    private let lock = NSLock()
    private var attempted = false
    init(configuration: SSHTransportConfiguration, gate: TrustGate) { self.configuration = configuration; self.gate = gate }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        lock.lock()
        let firstAttempt = !attempted
        attempted = true
        lock.unlock()
        guard firstAttempt else { nextChallengePromise.fail(SSHTransportError.authenticationUnavailable); return }
        do {
            try gate.withOpen {}
            let kind: CredentialKind
            switch configuration.authentication {
            case .password:
                guard availableMethods.contains(.password) else { throw SSHTransportError.authenticationUnavailable }
                kind = .password
            case .ed25519:
                guard availableMethods.contains(.publicKey) else { throw SSHTransportError.authenticationUnavailable }
                kind = .privateKey
            }
            // Caller hooks may synchronously revoke trust or reenter this delegate. Hold neither lock here.
            configuration.lifecycleEvent("credential-read")
            let raw = try gate.withOpen { try configuration.secrets.read(serverID: configuration.serverID, kind: kind) }
            // The store itself is an external operation and may have revoked the recursive gate.
            try gate.withOpen {}
            let offer: NIOSSHUserAuthenticationOffer
            switch configuration.authentication {
            case .password:
                guard let password = String(data: raw, encoding: .utf8), !password.isEmpty else {
                    throw SSHTransportError.authenticationUnavailable
                }
                offer = .init(username: configuration.username, serviceName: "ssh-connection", offer: .password(.init(password: password)))
            case .ed25519:
                let key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
                offer = .init(username: configuration.username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key)))
            }
            configuration.lifecycleEvent("authentication-offered")
            try gate.withOpen { nextChallengePromise.succeed(offer) }
        } catch { nextChallengePromise.fail(error) }
    }
}

private final class ParentSetupReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Error) -> Void)?
    private var pending: Error?
    func install(_ callback: @escaping (Error) -> Void) {
        lock.lock(); self.callback = callback; let pending = self.pending; self.pending = nil; lock.unlock()
        if let pending { callback(pending) }
    }
    func report(_ error: Error) {
        lock.lock(); let callback = self.callback
        if callback == nil { pending = error }
        lock.unlock()
        callback?(error)
    }
}

private final class ParentTransportErrorHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let reporter: ParentSetupReporter
    private let gate: TrustGate
    init(reporter: ParentSetupReporter, gate: TrustGate) { self.reporter = reporter; self.gate = gate }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        gate.fail((error as? SSHTransportError) ?? .closed)
        reporter.report(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        gate.fail(.closed)
        context.fireChannelInactive()
    }
}

final class SetupCompletion: @unchecked Sendable {
    let promise: EventLoopPromise<Channel>
    private let eventLoop: EventLoop
    private let lock = NSLock()
    private var finished = false
    init(eventLoop: EventLoop) { self.eventLoop = eventLoop; promise = eventLoop.makePromise() }
    func succeed(_ channel: Channel) { finish(.success(channel)) }
    func fail(_ error: SSHTransportError) { finish(.failure(error)) }
    func failError(_ error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<Channel, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            if case .success(let channel) = result { channel.close(promise: nil) }
            return
        }
        finished = true
        eventLoop.execute {
            self.lock.lock(); self.lock.unlock()
            self.promise.completeWith(result)
        }
        lock.unlock()
    }
}

final class ResolverCompletion: @unchecked Sendable {
    let promise: EventLoopPromise<[SocketAddress]>
    private let eventLoop: EventLoop
    private let lock = NSLock()
    private var finished = false
    init(eventLoop: EventLoop) { self.eventLoop = eventLoop; promise = eventLoop.makePromise() }
    func fail(_ error: SSHTransportError) { complete(.failure(error)) }
    func complete(_ result: Result<[SocketAddress], Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        eventLoop.execute {
            self.lock.lock(); self.lock.unlock()
            self.promise.completeWith(result)
        }
        lock.unlock()
    }
}

/// A one-attachment, actor-owned NIOSSH transport. Writes are bounded and never retained for replay.
public actor NIOSSHStreamingTransport: SSHStreamingTransport {
    private let configuration: SSHTransportConfiguration
    private let group: MultiThreadedEventLoopGroup
    private let resolverPool: NIOThreadPool
    private var connection: Channel?
    private var session: Channel?
    private var closing = false
    private var attaching = false
    private var activeGate: TrustGate?
    private var queuedBytes = 0
    private let queueLimit = 256 * 1024
    #if DEBUG
    private let fixtureShutdown = FixtureShutdownCompletion()
    private var loopbackFixture = false
    private var connectFixture: (@Sendable (EventLoop) -> EventLoopFuture<Channel>)?

    // Internal synthetic tests only; no app/API launch switch and no public/LAN address bypass.
    init(loopbackFixture configuration: SSHTransportConfiguration,
         connect: (@Sendable (EventLoop) -> EventLoopFuture<Channel>)? = nil) throws {
        guard configuration.host == "127.0.0.1" else { throw SSHTransportError.invalidEndpoint }
        self.configuration = configuration
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        resolverPool = NIOThreadPool(numberOfThreads: 1)
        resolverPool.start()
        loopbackFixture = true
        connectFixture = connect
    }
    #endif

    public init(configuration: SSHTransportConfiguration) {
        self.configuration = configuration
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        resolverPool = NIOThreadPool(numberOfThreads: 1)
        resolverPool.start()
    }

    public func attach(command: String, pty: TerminalSize,
                       receive: @escaping @Sendable (Data) async -> Void) async throws {
        guard connection == nil, !attaching, !closing, !command.isEmpty else { throw SSHTransportError.closed }
        attaching = true
        defer { attaching = false }
        let gate = TrustGate()
        activeGate = gate
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await attach(command: command, pty: pty, receive: receive, gate: gate)
        } onCancel: { gate.fail(.closed) }
    }

    private func attach(command: String, pty: TerminalSize,
                        receive: @escaping @Sendable (Data) async -> Void, gate: TrustGate) async throws {
        let canonical = try HostIdentity.canonicalHost(configuration.host)
        guard canonical == configuration.host.lowercased(), configuration.port > 0,
              !configuration.username.isEmpty else { throw SSHTransportError.invalidEndpoint }
        configuration.lifecycleEvent("address-resolution-started")
        let addresses: [SocketAddress]
        do { addresses = try await resolvePrivateAddresses(host: canonical, port: configuration.port, gate: gate) }
        catch {
            let diagnostic = SSHConnectionDiagnostic.capture(error)
            configuration.lifecycleEvent("address-resolution-failed." + diagnostic.category)
            configuration.diagnosticFailure(diagnostic)
            throw error
        }
        try Task.checkCancellation()
        guard !closing, gate.failure() == nil else { throw SSHTransportError.closed }
        configuration.lifecycleEvent("address-resolution-completed")
        guard !addresses.isEmpty else { throw SSHTransportError.noTrustedAddress }

        var lastError: Error = SSHTransportError.timedOut
        for address in addresses {
            if Task.isCancelled { throw CancellationError() }
            let attemptGate = TrustGate()
            gate.installAbort { attemptGate.fail(.closed) }
            do {
                try await attach(address: address, command: command, pty: pty, receive: receive, gate: attemptGate)
                return
            } catch {
                lastError = error
                await closeChannelsOnly()
                if Task.isCancelled || closing || gate.failure() != nil { throw error }
                // Trust/authentication rejection is final, not a reason to prompt or offer a password at another address.
                if let error = error as? SSHTransportError,
                   error == .changedHostKey || error == .unknownHostRejected || error == .authenticationUnavailable || error == .requestRejected {
                    throw error
                }
            }
        }
        throw lastError
    }

    private func attach(address: SocketAddress, command: String, pty: TerminalSize,
                        receive: @escaping @Sendable (Data) async -> Void, gate: TrustGate) async throws {
        gate.beginConfirmationWindow()
        let auth = KeychainAuthenticationDelegate(configuration: configuration, gate: gate)
        let host = VerifyingHostKeyDelegate(configuration: configuration, gate: gate)
        let reporter = ParentSetupReporter()
        let initialize: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            do { try gate.register(channel) }
            catch { return channel.eventLoop.makeFailedFuture(error) }
            do {
                try channel.pipeline.syncOperations.addHandlers(
                    NIOSSHHandler(role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: host)),
                                  allocator: channel.allocator, inboundChildChannelInitializer: nil),
                    ParentTransportErrorHandler(reporter: reporter, gate: gate)
                )
                return channel.eventLoop.makeSucceededFuture(())
            } catch { return channel.eventLoop.makeFailedFuture(error) }
        }
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(8))
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer(initialize)
        configuration.lifecycleEvent("tcp-connect-started")
        let parent: Channel
        let tcp = SetupCompletion(eventLoop: group.next())
        gate.installAbort { tcp.fail(.closed) }
        let connecting: EventLoopFuture<Channel>
        #if DEBUG
        if let connectFixture {
            connecting = connectFixture(group.next()).flatMap { channel in initialize(channel).map { channel } }
        } else { connecting = bootstrap.connect(to: address) }
        #else
        connecting = bootstrap.connect(to: address)
        #endif
        connecting.whenComplete { result in
            switch result {
            case .success(let channel): tcp.succeed(channel)
            case .failure(let error): tcp.failError(error)
            }
        }
        do { parent = try await tcp.promise.futureResult.get() }
        catch {
            let diagnostic = SSHConnectionDiagnostic.capture(error, address: address)
            configuration.lifecycleEvent("tcp-connect-failed." + diagnostic.category)
            configuration.diagnosticFailure(diagnostic)
            throw error
        }
        guard !closing, gate.failure() == nil, !Task.isCancelled else {
            parent.close(promise: nil); throw SSHTransportError.closed
        }
        configuration.lifecycleEvent("tcp-connect-succeeded")
        connection = parent
        let setup = SetupCompletion(eventLoop: parent.eventLoop)
        gate.installAbort { setup.fail(.closed) }
        reporter.install { error in setup.fail(gate.failure() ?? (error as? SSHTransportError) ?? .closed) }
        parent.closeFuture.whenComplete { _ in gate.fail(.closed); setup.fail(gate.failure() ?? .closed) }
        let watchdog = SetupWatchdog()
        let deadlineAccess = EventLoopEnqueueOwner(eventLoop: parent.eventLoop) { [weak gate] in gate?.finishProducer($0) }
        gate.registerProducer(deadlineAccess)
        let setupDeadline = parent.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(1), delay: .seconds(1)) { _ in
            let waiting = gate.isWaitingForConsent()
            guard watchdog.expired(waitingForConsent: waiting) else { return }
            let failure: SSHTransportError = waiting ? .unknownHostRejected : .timedOut
            gate.fail(failure)
            setup.fail(failure)
            parent.close(promise: nil)
        }
        defer { deadlineAccess.enqueue { setupDeadline.cancel() }; deadlineAccess.retire() }

        let setupAccess = EventLoopEnqueueOwner(eventLoop: parent.eventLoop) { [weak gate] in gate?.finishProducer($0) }
        gate.registerProducer(setupAccess)
        defer { setupAccess.retire() }
        setupAccess.enqueue {
            do {
                let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                handler.createChannel(promise) { channel, type in
                    guard type == .session else { return channel.eventLoop.makeFailedFuture(SSHTransportError.requestRejected) }
                    do { try gate.register(channel) }
                    catch { return channel.eventLoop.makeFailedFuture(error) }
                    return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        channel.setOption(ChannelOptions.autoRead, value: false)
                    }.flatMap {
                        do {
                            try channel.pipeline.syncOperations.addHandler(StreamingSessionHandler(
                                command: command, size: pty, receive: receive, gate: gate) { result in
                                    switch result {
                                    case .success: setup.succeed(channel)
                                    case .failure(let error): setup.fail((error as? SSHTransportError) ?? .requestRejected)
                                    }
                                })
                            return channel.eventLoop.makeSucceededFuture(())
                        } catch { return channel.eventLoop.makeFailedFuture(error) }
                    }
                }
                promise.futureResult.whenFailure { setup.fail(($0 as? SSHTransportError) ?? .requestRejected) }
            } catch { setup.fail((error as? SSHTransportError) ?? .requestRejected) }
        }

        do {
            let child = try await setup.promise.futureResult.get()
            guard !closing, gate.failure() == nil, !Task.isCancelled else {
                child.close(promise: nil); throw SSHTransportError.closed
            }
            session = child
        } catch {
            gate.fail((error as? SSHTransportError) ?? .closed)
            throw gate.failure() ?? error
        }
        configuration.lifecycleEvent("session-ready")
    }

    public func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        guard bytes.count <= 60_000, queuedBytes <= queueLimit - bytes.count else { throw SSHTransportError.queueFull }
        guard !closing, let session, session.isActive else { throw SSHTransportError.closed }
        queuedBytes += bytes.count
        defer { queuedBytes -= bytes.count }
        var buffer = session.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await boundedIO(session.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), channel: session)
    }

    public func resize(_ size: TerminalSize) async throws {
        guard !closing, let session, session.isActive else { throw SSHTransportError.closed }
        try await boundedIO(session.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: size.pixelWidth, terminalPixelHeight: size.pixelHeight)), channel: session)
    }

    public func close() async {
        guard !closing else { return }
        closing = true
        activeGate?.fail(.closed)
        await closeChannelsOnly()
        // DNS work cannot be force-cancelled. Initiate teardown without trapping the UI in an unbounded await.
        resolverPool.shutdownGracefully { _ in }
        #if DEBUG
        group.shutdownGracefully { [fixtureShutdown] _ in fixtureShutdown.finish() }
        #else
        group.shutdownGracefully { _ in }
        #endif
    }

    #if DEBUG
    func waitForFixtureShutdown() async { await fixtureShutdown.wait() }
    #endif

    private func closeChannelsOnly() async {
        let child = session; let parent = connection
        session = nil; connection = nil
        if let child { try? await boundedIO(child.close(), channel: child) }
        if let parent { try? await boundedIO(parent.close(), channel: parent) }
    }

    private func boundedIO(_ future: EventLoopFuture<Void>, channel: Channel) async throws {
        let gate = activeGate
        let completion = IOCompletion(eventLoop: future.eventLoop) { id in gate?.finishIO(id) }
        gate?.registerIO(completion)
        let deadlineAccess = EventLoopEnqueueOwner(eventLoop: future.eventLoop) { [weak gate] in gate?.finishProducer($0) }
        gate?.registerProducer(deadlineAccess)
        let deadline = future.eventLoop.scheduleTask(in: .seconds(3)) {
            completion.complete(.failure(SSHTransportError.timedOut), closing: channel)
        }
        future.whenComplete { _ = completion.complete($0) }
        defer { deadlineAccess.enqueue { deadline.cancel() }; deadlineAccess.retire() }
        try await withTaskCancellationHandler {
            try await completion.promise.futureResult.get()
        } onCancel: {
            completion.complete(.failure(CancellationError()), closing: channel)
        }
    }

    private func resolvePrivateAddresses(host: String, port: UInt16, gate: TrustGate) async throws -> [SocketAddress] {
        #if DEBUG
        if loopbackFixture { return [try SocketAddress(ipAddress: "127.0.0.1", port: Int(port))] }
        #endif
        let loop = group.next()
        let completion = ResolverCompletion(eventLoop: loop)
        gate.installAbort { completion.fail(.closed) }
        let deadlineAccess = EventLoopEnqueueOwner(eventLoop: loop) { [weak gate] in gate?.finishProducer($0) }
        gate.registerProducer(deadlineAccess)
        let deadline = loop.scheduleTask(in: .seconds(8)) { completion.fail(.timedOut) }
        // Do not let runIfActive's unguarded future schedule a late DNS result on a stopped loop.
        resolverPool.submit { state in
            guard case .active = state else { completion.fail(.closed); return }
            completion.complete(Result { try Self.blockingResolvePrivateAddresses(host: host, port: port) })
        }
        defer { deadlineAccess.enqueue { deadline.cancel() }; deadlineAccess.retire() }
        return try await withTaskCancellationHandler {
            try await completion.promise.futureResult.get()
        } onCancel: { gate.fail(.closed) }
    }

    private nonisolated static func blockingResolvePrivateAddresses(host: String, port: UInt16) throws -> [SocketAddress] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw SSHTransportError.noTrustedAddress
        }
        defer { freeaddrinfo(first) }
        var values: [SocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.ai_addr, entry.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let terminated = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                guard let ip = String(bytes: terminated, encoding: .utf8) else {
                    cursor = entry.ai_next; continue
                }
                if (try? PrivateAddressValidator.validate(ip)) == true,
                   let address = try? SocketAddress(ipAddress: ip, port: Int(port)), !values.contains(address) {
                    values.append(address)
                    if values.count == 8 { break }
                }
            }
            cursor = entry.ai_next
        }
        guard !values.isEmpty else { throw SSHTransportError.noTrustedAddress }
        return values
    }
}

final class StreamingSessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private enum RequestPhase { case waitingForPTY, waitingForExec, ready }
    private let command: String
    private let size: TerminalSize
    private let gate: TrustGate
    private let inbound: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private let receive: @Sendable (Data) async -> Void
    private var receiver: Task<Void, Never>?
    private var completionProducer: EventLoopEnqueueOwner?
    private var batch = Data()
    private var pendingBatches = 0
    private let setupComplete: (Result<Void, Error>) -> Void
    private var phase = RequestPhase.waitingForPTY
    private var didFinish = false

    init(command: String, size: TerminalSize, receive: @escaping @Sendable (Data) async -> Void, gate: TrustGate,
         setupComplete: @escaping (Result<Void, Error>) -> Void) {
        self.command = command; self.size = size; self.gate = gate; self.setupComplete = setupComplete; self.receive = receive
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(128))
        inbound = stream.continuation
        self.stream = stream.stream
    }
    deinit { completionProducer?.retire(); inbound.finish() }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel, stream = self.stream, receive = self.receive
        let producer = EventLoopEnqueueOwner(eventLoop: channel.eventLoop) { [weak gate] in gate?.finishProducer($0) }
        completionProducer = producer
        gate.registerProducer(producer)
        receiver = Task { [weak self] in
            for await chunk in stream {
                await receive(chunk)
                producer.enqueue { [weak self] in self?.processedBatch(channel: channel) }
            }
            // EOF follows all accepted bytes, never a racing independent task.
            await receive(Data())
        }
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color", terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows, terminalPixelWidth: size.pixelWidth,
            terminalPixelHeight: size.pixelHeight, terminalModes: .init([:]))
        do {
            try gate.withOpen {
                let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
                context.triggerUserOutboundEvent(request).whenFailure { self.fail($0, context: boundContext.value) }
                context.read()
            }
        } catch { fail(error, context: context) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = message.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        guard !didFinish else { return }
        guard bytes.count <= 1 << 20 else { fail(SSHTransportError.queueFull, context: context); return }
        batch.append(contentsOf: bytes)
        if batch.count >= 64 * 1024 { flushBatch(context: context) }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        flushBatch(context: context)
        if pendingBatches == 0 && !didFinish { context.read() }
    }

    private func flushBatch(context: ChannelHandlerContext) {
        guard !batch.isEmpty else { return }
        let chunk = batch; batch = Data()
        pendingBatches += 1
        if case .dropped = inbound.yield(chunk) { fail(SSHTransportError.queueFull, context: context) }
    }

    private func processedBatch(channel: Channel) {
        guard !didFinish else { return }
        assert(pendingBatches > 0)
        guard pendingBatches > 0 else { return }
        pendingBatches -= 1
        // SSH's child-channel receive window now applies real backpressure to the producer.
        if pendingBatches == 0 && !didFinish { channel.read() }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            switch phase {
            case .waitingForPTY:
                phase = .waitingForExec
                do {
                    try gate.withOpen {
                        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
                        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
                            .whenFailure { self.fail($0, context: boundContext.value) }
                    }
                } catch { fail(error, context: context) }
            case .waitingForExec:
                do { try gate.withOpen { phase = .ready; setupComplete(.success(())) } }
                catch { fail(error, context: context) }
            case .ready: break
            }
            return
        }
        if event is ChannelFailureEvent {
            fail(SSHTransportError.requestRejected, context: context)
            return
        }
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            finish(context: context); return
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) { finish(context: context) }
    func handlerRemoved(context: ChannelHandlerContext) { finish(context: context) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error, context: context) }

    private func finish(context: ChannelHandlerContext) {
        completionProducer?.retire()
        guard !didFinish else { return }
        flushBatch(context: context)
        guard !didFinish else { return }; didFinish = true
        gate.fail(.closed)
        if phase != .ready { setupComplete(.failure(SSHTransportError.requestRejected)) }
        inbound.finish()
        context.close(promise: nil)
    }
    private func fail(_ error: Error, context: ChannelHandlerContext) {
        completionProducer?.retire()
        guard !didFinish else { return }
        flushBatch(context: context)
        guard !didFinish else { return }; didFinish = true
        gate.fail((error as? SSHTransportError) ?? .closed)
        if phase != .ready { setupComplete(.failure(error)) }
        inbound.finish()
        context.close(promise: nil)
    }
}

/// Event-loop confined: network setup gets ten seconds, explicit human trust gets a separate sixty-second window.
private final class SetupWatchdog: @unchecked Sendable {
    private var networkDeadline = NIODeadline.now() + .seconds(10)
    private var consentDeadline: NIODeadline?
    func expired(waitingForConsent: Bool) -> Bool {
        let now = NIODeadline.now()
        if waitingForConsent {
            if consentDeadline == nil { consentDeadline = now + .seconds(60) }
            networkDeadline = now + .seconds(10)
            return now >= consentDeadline!
        }
        return now >= networkDeadline
    }
}

// Gate revocation and task cancellation claim before enqueueing; late completions never touch the loop.
final class IOCompletion: @unchecked Sendable {
    let id = UUID()
    let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var finished = false
    private let didDeliver: @Sendable (UUID) -> Void
    init(eventLoop: EventLoop, didDeliver: @escaping @Sendable (UUID) -> Void = { _ in }) {
        promise = eventLoop.makePromise(of: Void.self); self.didDeliver = didDeliver
    }
    @discardableResult func complete(_ result: Result<Void, Error>, closing channel: Channel? = nil) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        promise.futureResult.eventLoop.execute {
            self.lock.lock(); self.lock.unlock()
            self.didDeliver(self.id)
            channel?.close(promise: nil)
            self.promise.completeWith(result)
        }
        lock.unlock()
        return true
    }
}

#if DEBUG
private final class FixtureShutdownCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() {
        lock.lock(); finished = true; let pending = waiters; waiters = []; lock.unlock()
        pending.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation {
            lock.lock()
            if finished { lock.unlock(); $0.resume() }
            else { waiters.append($0); lock.unlock() }
        }
    }
}
#endif
