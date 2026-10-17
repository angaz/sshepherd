import AppCore
import AppUI
import Foundation
import Testing

private enum GenerationFailure: Error { case oldOperation }
private actor GenerationTransport: SSHStreamingTransport {
    enum Mode { case none, send, resize, attach }
    let mode: Mode
    var closeCount = 0
    var sent: [Data] = []
    var sizes: [TerminalSize] = []
    var pty: TerminalSize?
    private var receiver: (@Sendable (Data) async -> Void)?
    private var pending: CheckedContinuation<Void, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    init(_ mode: Mode = .none) { self.mode = mode }
    private func suspend() async throws {
        try await withCheckedThrowingContinuation {
            pending = $0
            let waiting = startWaiters; startWaiters = []
            waiting.forEach { $0.resume() }
        }
    }
    func waitStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release(fail: Bool = true) {
        let next = pending; pending = nil
        if fail { next?.resume(throwing: GenerationFailure.oldOperation) } else { next?.resume() }
    }
    func attach(command: String, pty: TerminalSize, receive: @escaping @Sendable (Data) async -> Void) async throws {
        self.pty = pty; receiver = receive
        if mode == .attach { try await suspend() }
    }
    func send(_ bytes: Data) async throws {
        sent.append(bytes)
        if mode == .send { try await suspend() }
    }
    func resize(_ size: TerminalSize) async throws {
        sizes.append(size)
        if mode == .resize { try await suspend() }
    }
    func deliver(_ bytes: Data) async { await receiver?(bytes) }
    func close() async { closeCount += 1 }
}
private final class GenerationFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    let transports: [GenerationTransport]
    init(_ transports: [GenerationTransport]) { self.transports = transports }
    func make() -> GenerationTransport {
        lock.lock(); defer { lock.unlock() }
        let next = transports[min(index, transports.count - 1)]; index += 1
        return next
    }
}
private actor GenerationEngine: NativeTerminalEngine {
    let deferWrite: Bool
    private var pending: CheckedContinuation<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(deferWrite: Bool = false) { self.deferWrite = deferWrite }
    func write(_ bytes: Data) async throws {
        if deferWrite {
            try await withCheckedThrowingContinuation {
                pending = $0; let waiting = waiters; waiters = []; waiting.forEach { $0.resume() }
            }
        }
    }
    func waitWriteStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func failWrite() { let next = pending; pending = nil; next?.resume(throwing: GenerationFailure.oldOperation) }
    func resize(_ size: TerminalSize) async throws {}
    func frame() async throws -> Data { Data() }
    func replies() async throws -> Data { Data() }
    func key(_ event: TerminalKeyEvent) async throws -> Data { Data() }
    func mouse(_ event: TerminalMouseEvent) async throws -> Data { Data() }
    func close() async {}
}

@Test func coordinatorOldSendFailureCannotDisconnectReplacement() async throws {
    let old = GenerationTransport(.send), replacement = GenerationTransport()
    let factory = GenerationFactory([old, replacement])
    let coordinator = TerminalSessionCoordinator(transportFactory: { factory.make() }, engine: GenerationEngine())
    try await coordinator.connect()
    let send = Task { await coordinator.send(Data("uncertain".utf8)) }
    await old.waitStarted()
    await coordinator.detach(); try await coordinator.connect()
    await old.release(); await send.value
    #expect(coordinator.state == .connected)
    #expect(await replacement.closeCount == 0)
    #expect(await replacement.sent.isEmpty)
    await coordinator.shutdown()
}

@Test func coordinatorOldResizeFailureCannotDisconnectReplacement() async throws {
    let old = GenerationTransport(.resize), replacement = GenerationTransport()
    let factory = GenerationFactory([old, replacement])
    let coordinator = TerminalSessionCoordinator(transportFactory: { factory.make() }, engine: GenerationEngine())
    try await coordinator.connect()
    let resize = Task { await coordinator.resize(columns: 91, rows: 27) }
    await old.waitStarted()
    await coordinator.detach(); try await coordinator.connect()
    await old.release(); await resize.value
    #expect(coordinator.state == .connected)
    #expect(await replacement.closeCount == 0)
    #expect(await replacement.sent.isEmpty)
    await coordinator.shutdown()
}

@Test func coordinatorOldEngineWriteFailureCannotDisconnectReplacement() async throws {
    let old = GenerationTransport(), replacement = GenerationTransport(), engine = GenerationEngine(deferWrite: true)
    let factory = GenerationFactory([old, replacement])
    let coordinator = TerminalSessionCoordinator(transportFactory: { factory.make() }, engine: engine)
    try await coordinator.connect()
    let receive = Task { await old.deliver(Data("old output".utf8)) }
    await engine.waitWriteStarted()
    await coordinator.detach(); try await coordinator.connect()
    await engine.failWrite(); await receive.value
    #expect(coordinator.state == .connected)
    #expect(await replacement.closeCount == 0)
    #expect(await replacement.sent.isEmpty)
    await coordinator.shutdown()
}

@Test func coordinatorReconcilesSizeChangedDuringDeferredAttach() async throws {
    let transport = GenerationTransport(.attach)
    let coordinator = TerminalSessionCoordinator(transportFactory: { transport }, engine: GenerationEngine())
    let attach = Task { try await coordinator.connect() }
    await transport.waitStarted()
    await coordinator.resize(columns: 91, rows: 27)
    await transport.release(fail: false); try await attach.value
    #expect(await transport.pty == TerminalSize(columns: 80, rows: 24))
    #expect(await transport.sizes == [TerminalSize(columns: 91, rows: 27)])
    await coordinator.resize(columns: 91, rows: 27)
    #expect(await transport.sizes.count == 1)
    #expect(coordinator.state == .connected)
    await coordinator.shutdown()
}
