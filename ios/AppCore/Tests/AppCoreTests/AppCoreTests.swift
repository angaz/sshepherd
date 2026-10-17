import AppCore
import AppUI
import Foundation
import SecurityCore
import Testing

private final class MemoryDataStore: AtomicDataStore, @unchecked Sendable {
    var data: Data?
    func read() throws -> Data? { data }
    func replace(with data: Data) throws { self.data = data }
}

private actor TestEngine: NativeTerminalEngine {
    var writes: [Data] = []
    func write(_ bytes: Data) async throws { writes.append(bytes) }
    func resize(_ size: TerminalSize) async throws {}
    func frame() async throws -> Data { Data("frame".utf8) }
    func replies() async throws -> Data { Data() }
    func key(_ event: TerminalKeyEvent) async throws -> Data { Data("k".utf8) }
    func mouse(_ event: TerminalMouseEvent) async throws -> Data { Data() }
    func close() async {}
}
private actor TestTransport: SSHStreamingTransport {
    var sent: [Data] = []
    func attach(command: String, pty: TerminalSize, receive: @escaping @Sendable (Data) async -> Void) async throws {}
    func send(_ bytes: Data) async throws { sent.append(bytes) }
    func resize(_ size: TerminalSize) async throws {}
    func close() async {}
}

@Test func persistentHostStorePersistsEmptyInventory() async throws {
    let memory = MemoryDataStore()
    let store = PersistentHostStore(inventory: ServerInventory(storage: memory))
    try await store.save([])
    #expect(try await store.hosts().isEmpty)
    #expect(memory.data != nil)
}

@Test func coordinatorRoutesNativeKeyThroughInjectedTransport() async throws {
    let transport = TestTransport(); let engine = TestEngine()
    let coordinator = TerminalSessionCoordinator(transportFactory: { transport }, engine: engine)
    try await coordinator.connect()
    #expect(coordinator.state == .connected)
    await coordinator.sendKey(TerminalKeyEvent(.enter))
    #expect(await transport.sent == [Data("k".utf8)])
    await coordinator.detach()
    #expect(coordinator.state == .disconnected)
}

#if canImport(SSHepherdTerminal)
@Test func appleTerminalAdapterRunsRealNativeEngine() async throws {
    let engine = try AppleTerminalEngine(columns: 12, rows: 4)
    try await engine.write(Data("native\r\n".utf8))
    let frame = try TerminalFrame.decode(await engine.frame())
    #expect(frame.columns == 12)
    #expect(frame.rows == 4)
    #expect(frame.cells.contains { $0.text == "n" })
    let enter = try await engine.key(TerminalKeyEvent(.enter))
    #expect(!enter.isEmpty)
    try await engine.resize(TerminalSize(columns: 20, rows: 6, cellWidth: 9, cellHeight: 18))
    let resized = try TerminalFrame.decode(await engine.frame())
    #expect(resized.columns == 20)
    #expect(resized.rows == 6)
    await engine.close()
    await #expect(throws: NativeEngineError.closed) { try await engine.frame() }
}
#endif
