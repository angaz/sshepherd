#if DEBUG
@testable import AppCore
import AppUI
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SecurityCore
import Testing

private final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.lock(); fired = true; let next = waiting; waiting = []; lock.unlock()
        next.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired { lock.unlock(); continuation.resume() }
            else { waiting.append(continuation); lock.unlock() }
        }
    }
}
private final class CancellationObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    private var channels: [Channel] = []
    private var children: [Channel] = []
    let connected = CancellationSignal(), consentFinished = CancellationSignal()
    func label(_ value: String) {
        lock.lock(); labels.append(value); lock.unlock()
        if value == "tcp-connect-succeeded" { connected.signal() }
        if value == "host-key-confirmation-finished" { consentFinished.signal() }
    }
    func record(_ channel: Channel) { lock.lock(); channels.append(channel); lock.unlock() }
    func recordChild(_ channel: Channel) { lock.lock(); children.append(channel); lock.unlock() }
    func childSnapshot() -> [Channel] { lock.lock(); defer { lock.unlock() }; return children }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return labels }
    func channelSnapshot() -> [Channel] { lock.lock(); defer { lock.unlock() }; return channels }
}
private final class CancellationSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func read(serverID: UUID, kind: CredentialKind) throws -> Data {
        lock.lock(); reads += 1; lock.unlock()
        return Data("synthetic-fixture-password".utf8)
    }
    func save(_ data: Data, serverID: UUID, kind: CredentialKind) throws {}
    func delete(serverID: UUID, kind: CredentialKind) throws {}
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
}
private final class DeferredConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Bool, Never>?
    let started = CancellationSignal()
    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock(); pending = continuation; lock.unlock(); started.signal()
        }
    }
    func approveAfterCancellation() { resolve(true) }
    func resolve(_ accepted: Bool) {
        lock.lock(); let next = pending; pending = nil; lock.unlock(); next?.resume(returning: accepted)
    }
}
private final class DeferredTCP: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: EventLoopPromise<Channel>?
    let started = CancellationSignal()
    func connect(on loop: EventLoop) -> EventLoopFuture<Channel> {
        let promise = loop.makePromise(of: Channel.self)
        lock.lock(); pending = promise; lock.unlock(); started.signal()
        return promise.futureResult
    }
    func completeLate(_ channel: Channel) {
        lock.lock(); let next = pending; pending = nil; lock.unlock(); next?.succeed(channel)
    }
}
private final class FixtureAuthentication: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let observations: CancellationObservations
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    init(_ observations: CancellationObservations) { self.observations = observations }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        observations.label("server-authentication-request")
        responsePromise.succeed(.success)
    }
}
private final class FixtureExecObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let observations: CancellationObservations
    let emitOutput: Bool
    init(_ observations: CancellationObservations, emitOutput: Bool = false) {
        self.observations = observations; self.emitOutput = emitOutput
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExecRequest { observations.label("server-exec-request") }
        if event is SSHChannelRequestEvent.PseudoTerminalRequest { observations.label("server-pty-request") }
        if event is SSHChannelRequestEvent.PseudoTerminalRequest || event is SSHChannelRequestEvent.ExecRequest {
            let channel = context.channel
            context.triggerUserOutboundEvent(ChannelSuccessEvent()).whenFailure { _ in channel.close(promise: nil) }
            if event is SSHChannelRequestEvent.ExecRequest, emitOutput {
                var buffer = channel.allocator.buffer(capacity: 32)
                buffer.writeString("synthetic-blocked-consumer-output")
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
            }
        }
    }
}
private struct CancellationServer {
    let group: MultiThreadedEventLoopGroup
    let listener: Channel
    let observations: CancellationObservations
    let identity: HostIdentity
    var port: UInt16 { UInt16(listener.localAddress!.port!) }
    static func start(ssh: Bool, emitOutput: Bool = false) async throws -> Self {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), observations = CancellationObservations()
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            observations.record(channel)
            guard ssh else { return channel.eventLoop.makeSucceededFuture(()) }
            do {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [hostKey], userAuthDelegate: FixtureAuthentication(observations))),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, _ in
                        observations.recordChild(child)
                        do {
                            try child.pipeline.syncOperations.addHandler(FixtureExecObserver(observations, emitOutput: emitOutput))
                            return child.eventLoop.makeSucceededFuture(())
                        } catch { return child.eventLoop.makeFailedFuture(error) }
                    }))
                return channel.eventLoop.makeSucceededFuture(())
            } catch { return channel.eventLoop.makeFailedFuture(error) }
        }.bind(host: "127.0.0.1", port: 0).get()
        let fields = String(openSSHPublicKey: hostKey.publicKey).split(separator: " ")
        let identity = try HostIdentity(host: "127.0.0.1", port: UInt16(server.localAddress!.port!),
            algorithm: String(fields[0]), blob: Data(base64Encoded: String(fields[1]))!)
        return Self(group: group, listener: server, observations: observations, identity: identity)
    }
    func endSession() async throws {
        for child in observations.childSnapshot() { try await child.close().get() }
    }
    func shutdown() async throws {
        for channel in observations.channelSnapshot() { try? await channel.close().get() }
        try await listener.close().get()
        try await group.shutdownGracefully()
    }
}
private func cancellationConfiguration(port: UInt16, hosts: InMemoryKnownHosts,
                                       secrets: CancellationSecrets, observations: CancellationObservations,
                                       consent: DeferredConsent? = nil) -> SSHTransportConfiguration {
    .init(serverID: UUID(), host: "127.0.0.1", port: port, username: "synthetic-fixture",
          authentication: .password, knownHosts: hosts, secrets: secrets,
          confirmUnknownFingerprint: { _ in await consent?.request() ?? false },
          lifecycleEvent: { observations.label($0) })
}

@Test func nioSSHCancellationDuringDeferredTCPRejectsAndClosesLateChannel() async throws {
    let server = try await CancellationServer.start(ssh: false)
    let hosts = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations(), tcp = DeferredTCP()
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: hosts, secrets: secrets, observations: observations), connect: { tcp.connect(on: $0) })
    let attach = Task { try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { _ in } }
    await tcp.started.wait()
    do {
        try await transport.attach(command: "concurrent-no-exec", pty: .init(columns: 80, rows: 24)) { _ in }
        Issue.record("Concurrent attach replaced active cancellation ownership")
    } catch { #expect(error as? SSHTransportError == .closed) }
    let began = ContinuousClock().now
    attach.cancel()
    do { try await attach.value; Issue.record("Cancelled TCP attachment succeeded") } catch {}
    #expect(began.duration(to: ContinuousClock().now) < .seconds(1))
    // Complete a real connected channel AFTER cancellation; the production initializer must reject/close it.
    let late = try await ClientBootstrap(group: server.group).connect(host: "127.0.0.1", port: Int(server.port)).get()
    tcp.completeLate(late)
    try await late.closeFuture.get()
    #expect(!late.isActive)
    #expect(secrets.readCount() == 0)
    #expect(try hosts.identity(for: "127.0.0.1", port: server.port) == nil)
    #expect(!observations.snapshot().contains("session-ready"))
    await transport.close(); try await server.shutdown()
}

@Test func nioSSHCancellationDuringSSHNegotiationCompletesPromptly() async throws {
    let server = try await CancellationServer.start(ssh: false)
    let hosts = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations()
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: hosts, secrets: secrets, observations: observations))
    let attach = Task { try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { _ in } }
    await observations.connected.wait()
    let began = ContinuousClock().now
    attach.cancel()
    do { try await attach.value; Issue.record("Cancelled negotiation succeeded") } catch {}
    #expect(began.duration(to: ContinuousClock().now) < .seconds(1))
    #expect(secrets.readCount() == 0)
    #expect(!observations.snapshot().contains("authentication-offered"))
    #expect(!observations.snapshot().contains("session-ready"))
    await transport.close(); try await server.shutdown()
}

@Test func nioSSHCancellationDuringConsentRejectsLateApprovalWithoutTrustCredentialsOrExec() async throws {
    let server = try await CancellationServer.start(ssh: true)
    let hosts = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations(), consent = DeferredConsent()
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: hosts, secrets: secrets, observations: observations, consent: consent))
    let attach = Task { try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { _ in } }
    await consent.started.wait()
    let began = ContinuousClock().now
    attach.cancel()
    do { try await attach.value; Issue.record("Cancelled consent succeeded") } catch {}
    #expect(began.duration(to: ContinuousClock().now) < .seconds(1))
    consent.approveAfterCancellation()
    await observations.consentFinished.wait()
    #expect(try hosts.identity(for: "127.0.0.1", port: server.port) == nil)
    #expect(secrets.readCount() == 0)
    #expect(!observations.snapshot().contains("host-key-confirmed"))
    #expect(!observations.snapshot().contains("authentication-offered"))
    #expect(!observations.snapshot().contains("session-ready"))
    #expect(!server.observations.snapshot().contains("server-authentication-request"))
    #expect(!server.observations.snapshot().contains("server-exec-request"))
    await transport.close(); try await server.shutdown()
}

@Test(arguments: [true, false]) func nioSSHConsentResolvedAfterActualShutdownHasExactlyOneOutcome(approval: Bool) async throws {
    let server = try await CancellationServer.start(ssh: true)
    let hosts = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations(), consent = DeferredConsent()
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: hosts, secrets: secrets, observations: observations, consent: consent))
    let attach = Task { try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { _ in } }
    await consent.started.wait()
    let began = ContinuousClock().now
    await transport.close()
    do { try await attach.value; Issue.record("Closed consent succeeded") } catch {}
    #expect(began.duration(to: ContinuousClock().now) < .seconds(1))
    await transport.waitForFixtureShutdown() // Actual group termination, not merely shutdown initiation.
    consent.resolve(approval)
    await observations.consentFinished.wait()
    #expect(try hosts.identity(for: "127.0.0.1", port: server.port) == nil)
    #expect(secrets.readCount() == 0)
    #expect(!server.observations.snapshot().contains("server-exec-request"))
    #expect(!server.observations.snapshot().contains("server-pty-request"))
    #expect(!server.observations.snapshot().contains("server-authentication-request"))
    #expect(!observations.snapshot().contains("authentication-offered"))
    #expect(!observations.snapshot().contains("session-ready"))
    #expect(observations.snapshot().filter { $0 == "host-key-validation-completed" }.count == 1)
    try await server.shutdown()
}

@Test func nioSSHLoopbackFixtureCannotEnablePublicAddressAndDefaultStaysStrict() async throws {
    let hosts = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations()
    var configuration = cancellationConfiguration(port: 22, hosts: hosts, secrets: secrets, observations: observations)
    let production = NIOSSHStreamingTransport(configuration: configuration)
    do { try await production.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { _ in }; Issue.record("Default allowed loopback") }
    catch { #expect(error as? SSHTransportError == .noTrustedAddress) }
    await production.close()
    configuration = .init(serverID: UUID(), host: "8.8.8.8", port: 22, username: "fixture", authentication: .password,
                          knownHosts: hosts, secrets: secrets, confirmUnknownFingerprint: { _ in false })
    #expect(throws: SSHTransportError.invalidEndpoint) { try NIOSSHStreamingTransport(loopbackFixture: configuration) }
}

@Test(arguments: 0..<8) func nioSSHConcurrentCancelAndCloseDeliverValidationBeforeShutdown(iteration: Int) async throws {
    let server = try await CancellationServer.start(ssh: true)
    let hosts = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations(), consent = DeferredConsent()
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: hosts, secrets: secrets, observations: observations, consent: consent))
    let attach = Task { try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { _ in } }
    await consent.started.wait()
    await withTaskGroup(of: Void.self) { group in
        group.addTask { attach.cancel() }
        group.addTask { await transport.close() }
    }
    do { try await attach.value; Issue.record("Concurrent cancel/close succeeded") } catch {}
    await transport.waitForFixtureShutdown()
    consent.resolve(iteration % 2 == 0)
    await observations.consentFinished.wait()
    #expect(try hosts.identity(for: "127.0.0.1", port: server.port) == nil)
    #expect(secrets.readCount() == 0)
    #expect(!observations.snapshot().contains("authentication-offered"))
    #expect(!observations.snapshot().contains("session-ready"))
    #expect(observations.snapshot().filter { $0 == "host-key-validation-completed" }.count == 1)
    #expect(!server.observations.snapshot().contains("server-authentication-request"))
    #expect(!server.observations.snapshot().contains("server-pty-request"))
    #expect(!server.observations.snapshot().contains("server-exec-request"))
    try await server.shutdown()
}

@Test func nioSSHRevocationPublicationCannotOvertakeCancellationEnqueueAcknowledgement() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate()
    let promise = group.next().makePromise(of: Void.self), observations = CancellationObservations()
    let completion = HostValidationCompletion(promise: promise) { id in
        gate.finishValidation(id); observations.label("validation-outcome")
    }
    gate.registerValidation(completion)
    promise.futureResult.whenComplete {
        switch $0 {
        case .success: Issue.record("Revoked validation succeeded")
        case .failure: observations.label("validation-rejected")
        }
    }
    let deliveryEntered = CancellationSignal(), firstFinished = CancellationSignal(), shutdownFinished = CancellationSignal()
    let releaseDelivery = DispatchSemaphore(value: 0), secondReturned = DispatchSemaphore(value: 0)
    gate.installAbort { deliveryEntered.signal(); releaseDelivery.wait() }
    DispatchQueue.global().async { gate.fail(.closed); firstFinished.signal() }
    await deliveryEntered.wait() // Failure is already published, but abort delivery is deliberately held.
    #expect(gate.failure() == .closed)
    DispatchQueue.global().async {
        gate.fail(.closed)
        secondReturned.signal()
        group.shutdownGracefully { _ in shutdownFinished.signal() }
    }
    // A bounded absence assertion, not a sleep used to order the race; deliveryEntered owns the ordering.
    let returnedEarly = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: secondReturned.wait(timeout: .now() + .milliseconds(50)) == .success)
        }
    }
    #expect(!returnedEarly)
    releaseDelivery.signal()
    await firstFinished.wait(); await shutdownFinished.wait()
    completion.complete(.success(())) // Must be a no-op even after the loop has actually terminated.
    #expect(observations.snapshot() == ["validation-outcome", "validation-rejected"])
}

@Test func nioSSHValidationRegistrationAfterRevocationCompletesOnce() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), observations = CancellationObservations()
    let promise = group.next().makePromise(of: Void.self)
    gate.fail(.closed)
    let completion = HostValidationCompletion(promise: promise) { _ in observations.label("validation-outcome") }
    try await promise.futureResult.eventLoop.submit { gate.registerValidation(completion) }.get()
    do { try await promise.futureResult.get(); Issue.record("Registration after revocation succeeded") }
    catch { #expect(error as? SSHTransportError == .closed) }
    try await group.shutdownGracefully()
    completion.complete(.failure(SSHTransportError.changedHostKey))
    completion.complete(.success(()))
    #expect(observations.snapshot() == ["validation-outcome"])
}

@Test func nioSSHApprovalAndRevocationAreSerializedAroundPersistence() async throws {
    let gate = TrustGate(), persistStarted = CancellationSignal(), approvalFinished = CancellationSignal(), revokeFinished = CancellationSignal()
    let releasePersistence = DispatchSemaphore(value: 0), results = CancellationObservations()
    gate.beginConfirmationWindow()
    DispatchQueue.global().async {
        do { try gate.approve { persistStarted.signal(); releasePersistence.wait(); results.label("persisted") } }
        catch { Issue.record("Approval unexpectedly failed before concurrent revocation") }
        approvalFinished.signal()
    }
    await persistStarted.wait()
    DispatchQueue.global().async { gate.fail(.closed); revokeFinished.signal() }
    releasePersistence.signal()
    await approvalFinished.wait(); await revokeFinished.wait()
    #expect(results.snapshot() == ["persisted"])
    #expect(throws: SSHTransportError.closed) { try gate.withOpen {} }
    #expect(throws: SSHTransportError.closed) { try gate.approve { results.label("late-persist") } }
    #expect(results.snapshot() == ["persisted"])
}

@Test func nioSSHKnownChangedAndInvalidHostValidationBranchesUseCompletionOwner() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    let fields = String(openSSHPublicKey: key).split(separator: " ")
    let identity = try HostIdentity(host: "127.0.0.1", port: 22, algorithm: String(fields[0]), blob: Data(base64Encoded: String(fields[1]))!)
    let hosts = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations()
    try hosts.trust(identity)
    let gate = TrustGate(), configuration = cancellationConfiguration(port: 22, hosts: hosts, secrets: secrets, observations: observations)
    let delegate = VerifyingHostKeyDelegate(configuration: configuration, gate: gate)
    for _ in 0..<2 {
        let promise = group.next().makePromise(of: Void.self)
        try await promise.futureResult.eventLoop.submit { delegate.validateHostKey(hostKey: key, validationCompletePromise: promise) }.get()
        try await promise.futureResult.get()
    }
    #expect(observations.snapshot().filter { $0 == "host-key-validation-completed" }.count == 2)
    let changedKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    let changed = group.next().makePromise(of: Void.self)
    try await changed.futureResult.eventLoop.submit { delegate.validateHostKey(hostKey: changedKey, validationCompletePromise: changed) }.get()
    do { try await changed.futureResult.get(); Issue.record("Changed host validation succeeded") }
    catch { #expect(error as? SSHTransportError == .changedHostKey) }
    let invalidConfiguration = SSHTransportConfiguration(serverID: UUID(), host: "inva\nlid", port: 22, username: "fixture",
        authentication: .password, knownHosts: hosts, secrets: secrets, confirmUnknownFingerprint: { _ in false },
        lifecycleEvent: { observations.label($0) })
    let invalid = group.next().makePromise(of: Void.self)
    let invalidDelegate = VerifyingHostKeyDelegate(configuration: invalidConfiguration, gate: TrustGate())
    try await invalid.futureResult.eventLoop.submit { invalidDelegate.validateHostKey(hostKey: key, validationCompletePromise: invalid) }.get()
    do { try await invalid.futureResult.get(); Issue.record("Invalid host identity succeeded") }
    catch { #expect(error as? SSHTransportError == .changedHostKey) }
    #expect(observations.snapshot().filter { $0 == "host-key-validation-completed" }.count == 4)
    #expect(secrets.readCount() == 0)
    try await group.shutdownGracefully()
}

private actor BlockedSSHConsumer {
    let started = CancellationSignal(), eof = CancellationSignal()
    private var pending: CheckedContinuation<Void, Never>?
    private var blocked = false
    private var bytes = Data()
    private var eofCount = 0
    private var dataAfterEOF = false
    func receive(_ value: Data) async {
        if value.isEmpty { eofCount += 1; eof.signal(); return }
        if eofCount > 0 { dataAfterEOF = true }
        bytes.append(value)
        if !blocked {
            blocked = true
            await withCheckedContinuation { pending = $0; started.signal() }
        }
    }
    func release() { let next = pending; pending = nil; next?.resume() }
    func snapshot() -> (Data, Int, Bool) { (bytes, eofCount, dataAfterEOF) }
}

@Test func nioSSHBlockedConsumerDrainsAcceptedBytesAndOneEOFAfterActualShutdown() async throws {
    let server = try await CancellationServer.start(ssh: true, emitOutput: true)
    let known = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations()
    try known.trust(server.identity)
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: known, secrets: secrets, observations: observations))
    let consumer = BlockedSSHConsumer()
    try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { await consumer.receive($0) }
    await consumer.started.wait()
    await transport.close()
    await transport.waitForFixtureShutdown()
    // Real consumer return AFTER actual group termination; never attach new NIO callbacks in this test harness.
    await consumer.release()
    await consumer.eof.wait()
    let snapshot = await consumer.snapshot()
    #expect(snapshot.0 == Data("synthetic-blocked-consumer-output".utf8))
    #expect(snapshot.1 == 1)
    #expect(!snapshot.2)
    try await server.shutdown()
    #expect(server.observations.channelSnapshot().allSatisfy { !$0.isActive })
}

@Test(arguments: 0..<8) func nioSSHConsumerEnqueueRacingCloseNeverReopensOrLosesOrderedEOF(iteration: Int) async throws {
    let server = try await CancellationServer.start(ssh: true, emitOutput: true)
    let known = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations()
    try known.trust(server.identity)
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: known, secrets: secrets, observations: observations))
    let consumer = BlockedSSHConsumer()
    try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { await consumer.receive($0) }
    await consumer.started.wait()
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await consumer.release() }
        group.addTask { await transport.close() }
    }
    await transport.waitForFixtureShutdown(); await consumer.eof.wait()
    let snapshot = await consumer.snapshot()
    #expect(snapshot.0 == Data("synthetic-blocked-consumer-output".utf8))
    #expect(snapshot.1 == 1)
    #expect(!snapshot.2)
    try await server.shutdown()
    #expect(server.observations.channelSnapshot().allSatisfy { !$0.isActive })
}

@Test func nioSSHRetirementAtomicallyRejectsLateEnqueuesAndDrainsAcceptedCallbacks() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), observations = CancellationObservations()
    let owner = EventLoopEnqueueOwner(eventLoop: group.next()) { [weak gate] in gate?.finishProducer($0) }
    gate.registerProducer(owner)
    let admitted = CancellationObservations()
    DispatchQueue.concurrentPerform(iterations: 32) { index in
        if index == 16 { gate.fail(.closed) }
        if owner.enqueue({ observations.label("batch-\(index)") }) { admitted.label("batch-\(index)") }
    }
    gate.fail(.closed)
    try await group.shutdownGracefully()
    #expect(observations.snapshot().sorted() == admitted.snapshot().sorted())
    #expect(Set(observations.snapshot()).count == observations.snapshot().count)
    #expect(!owner.enqueue { Issue.record("A retired producer invoked a late callback") })
}

@Test func nioSSHLateIOCancellationDNSResultAndTimerCleanupNeverAccessStoppedLoop() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), gate = TrustGate(), observations = CancellationObservations()
    let loop = group.next()
    let io = IOCompletion(eventLoop: loop) { id in gate.finishIO(id); observations.label("io-outcome") }
    gate.registerIO(io)
    let resolver = ResolverCompletion(eventLoop: loop)
    resolver.promise.futureResult.whenComplete { _ in observations.label("dns-outcome") }
    gate.installAbort { resolver.fail(.closed) }
    let timerAccess = EventLoopEnqueueOwner(eventLoop: loop) { [weak gate] in gate?.finishProducer($0) }
    gate.registerProducer(timerAccess)
    let timer = loop.scheduleTask(in: .hours(1)) { Issue.record("Uncancelled deadline executed") }
    gate.fail(.closed)
    do { try await io.promise.futureResult.get(); Issue.record("Revoked I/O succeeded") } catch {}
    try await group.shutdownGracefully()
    #expect(!io.complete(.failure(CancellationError())))
    resolver.complete(.success([try SocketAddress(ipAddress: "127.0.0.1", port: 22)]))
    #expect(!timerAccess.enqueue { timer.cancel() })
    #expect(observations.snapshot().sorted() == ["dns-outcome", "io-outcome"])
}

@Test func nioSSHNormalSenderEOFDrainsAcceptedBytesBehindSlowConsumer() async throws {
    let server = try await CancellationServer.start(ssh: true, emitOutput: true)
    let known = InMemoryKnownHosts(), secrets = CancellationSecrets(), observations = CancellationObservations()
    try known.trust(server.identity)
    let transport = try NIOSSHStreamingTransport(loopbackFixture: cancellationConfiguration(
        port: server.port, hosts: known, secrets: secrets, observations: observations))
    let consumer = BlockedSSHConsumer()
    try await transport.attach(command: "synthetic-no-exec", pty: .init(columns: 80, rows: 24)) { await consumer.receive($0) }
    await consumer.started.wait()
    try await server.endSession() // EOF only after the client's attachment succeeded and output was accepted.
    await consumer.release()
    await consumer.eof.wait() // Sender EOF, without a preceding explicit transport.close().
    let snapshot = await consumer.snapshot()
    #expect(snapshot.0 == Data("synthetic-blocked-consumer-output".utf8))
    #expect(snapshot.1 == 1)
    #expect(!snapshot.2)
    await transport.close(); await transport.waitForFixtureShutdown()
    try await server.shutdown()
}
#endif
