#if canImport(SSHepherdTerminal)
import AppCore
import AppUI
import Foundation
import Testing

private enum FixtureDisconnect: Error { case refused }
private actor ReattachmentTransport: SSHStreamingTransport {
    let refuses: Bool
    private var receive: (@Sendable (Data) async -> Void)?
    var sent: [Data] = []
    init(refuses: Bool) { self.refuses = refuses }
    func attach(command: String, pty: TerminalSize, receive: @escaping @Sendable (Data) async -> Void) async throws {
        if refuses { throw FixtureDisconnect.refused }
        self.receive = receive
    }
    func endSession() async { await receive?(Data()) }
    func send(_ bytes: Data) async throws { sent.append(bytes) }
    func resize(_ size: TerminalSize) async throws {}
    func close() async {}
}
private final class ReattachmentFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [ReattachmentTransport] = []
    func make() -> ReattachmentTransport {
        lock.lock(); defer { lock.unlock() }
        let transport = ReattachmentTransport(refuses: !created.isEmpty)
        created.append(transport); return transport
    }
    func snapshot() -> [ReattachmentTransport] { lock.lock(); defer { lock.unlock() }; return created }
}

private actor DeferredKeyEngine: NativeTerminalEngine {
    private var pending: CheckedContinuation<Data, Never>?
    func waiting() -> Bool { pending != nil }
    func release() { let next = pending; pending = nil; next?.resume(returning: Data([1])) }
    func write(_ bytes: Data) async throws {}
    func resize(_ size: TerminalSize) async throws {}
    func frame() async throws -> Data { Data() }
    func replies() async throws -> Data { Data() }
    func key(_ event: TerminalKeyEvent) async throws -> Data { await withCheckedContinuation { pending = $0 } }
    func mouse(_ event: TerminalMouseEvent) async throws -> Data { Data() }
    func close() async { release() }
}

@Test func inFlightKeyEncodingCannotCrossAnAttachmentGeneration() async throws {
    let engine = DeferredKeyEngine(), transport = ReattachmentTransport(refuses: false)
    let coordinator = TerminalSessionCoordinator(transportFactory: { transport }, engine: engine)
    try await coordinator.connect()
    let key = Task { await coordinator.sendKey(.init(.character("a"), modifiers: .control)) }
    let deadline = ContinuousClock().now + .seconds(1)
    while !(await engine.waiting()), ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await engine.waiting())
    await coordinator.detach()
    try await coordinator.connect()
    await engine.release()
    await key.value
    #expect(await transport.sent.isEmpty)
    await coordinator.shutdown()
}

@Test func automaticReattachmentStopsAfterThreeAttemptsAndNeverReplaysDisconnectedInput() async throws {
    let factory = ReattachmentFactory(), engine = try AppleTerminalEngine()
    let coordinator = TerminalSessionCoordinator(transportFactory: { factory.make() }, engine: engine)
    try await coordinator.connect()
    let first = factory.snapshot()[0]
    let ending = Task { await first.endSession() }
    let deadline = ContinuousClock().now + .seconds(1)
    while coordinator.state == .connected, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(coordinator.state == .suspended)
    await coordinator.send(Data("uncertain input must never be replayed".utf8))
    let began = ContinuousClock().now
    await ending.value
    #expect(began.duration(to: ContinuousClock().now) < .seconds(8))
    #expect(factory.snapshot().count == 4)
    #expect(coordinator.state == .failed("SSH connection lost; reconnect manually"))
    for transport in factory.snapshot() { #expect(await transport.sent.isEmpty) }
    await coordinator.shutdown()
}

@Test func detachDuringReconnectBackoffCancelsTheOldAttachmentGeneration() async throws {
    let factory = ReattachmentFactory(), engine = try AppleTerminalEngine()
    let coordinator = TerminalSessionCoordinator(transportFactory: { factory.make() }, engine: engine)
    try await coordinator.connect()
    let first = factory.snapshot()[0]
    let ending = Task { await first.endSession() }
    let deadline = ContinuousClock().now + .seconds(1)
    while coordinator.state == .connected, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(coordinator.state == .suspended)
    await coordinator.detach()
    await ending.value
    #expect(factory.snapshot().count == 1)
    #expect(coordinator.state == .disconnected)
    await coordinator.send(Data("not connected".utf8))
    #expect(await first.sent.isEmpty)
    await coordinator.shutdown()
}
#endif
