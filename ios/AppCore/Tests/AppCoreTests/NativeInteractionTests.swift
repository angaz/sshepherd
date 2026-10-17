#if canImport(SSHepherdTerminal)
import AppCore
import AppUI
import Foundation
import Testing

@Test func realNativeControlAndNavigationKeysUseTheNativeEncoder() async throws {
    let engine = try AppleTerminalEngine()
    #expect(try await engine.key(.init(.character("a"), modifiers: .control)) == Data([1]))
    #expect(try await engine.key(.init(.character("c"), modifiers: .control)) == Data([3]))
    #expect(try await engine.key(.init(.character("u"), modifiers: .control)) == Data([21]))
    #expect(try await engine.key(.init(.tab)) == Data([9]))
    #expect(try await engine.key(.init(.enter)) == Data([13]))
    #expect(try await engine.key(.init(.backspace)) == Data([127]))
    #expect(try await engine.key(.init(.delete)) == Data("\u{1b}[3~".utf8))
    #expect(try await engine.key(.init(.pageUp)) == Data("\u{1b}[5~".utf8))
    #expect(try await engine.key(.init(.pageDown)) == Data("\u{1b}[6~".utf8))
    await engine.close()
}

@Test func realNativeControlKeysSurviveKittyKeyboardMode() async throws {
    for flags in [1, 3, 31] {
        let engine = try AppleTerminalEngine()
        try await engine.write(Data("\u{1b}[>\(flags)u".utf8))
        for (key, code) in [("c", 99), ("b", 98), ("u", 117)] {
            #expect(try await engine.key(.init(.character(key), modifiers: .control)) == Data("\u{1b}[\(code);5u".utf8))
        }
        await engine.close()
    }
}

@Test func realNativeMouseEncodesCellCoordinatesPressReleaseAndWheel() async throws {
    let engine = try AppleTerminalEngine(columns: 40, rows: 10)
    try await engine.resize(TerminalSize(columns: 40, rows: 10, cellWidth: 9, cellHeight: 18))
    try await engine.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
    let press = try await engine.mouse(.init(column: 7, row: 4))
    let release = try await engine.mouse(.init(column: 7, row: 4, action: .release))
    let wheel = try await engine.mouse(.init(column: 7, row: 4, button: 4, action: .scroll))
    #expect(press == Data("\u{1b}[<0;8;5M".utf8))
    #expect(release == Data("\u{1b}[<0;8;5m".utf8))
    #expect(wheel == Data("\u{1b}[<64;8;5M".utf8))
    await engine.close()
}

private actor EarlyOutputTransport: SSHStreamingTransport {
    var sent: [Data] = []
    func attach(command: String, pty: TerminalSize, receive: @escaping @Sendable (Data) async -> Void) async throws {
        // SSH may emit its first bytes immediately after exec acceptance, before attach returns.
        await receive(Data("EARLY BANNER\u{1b}[6n".utf8))
    }
    func send(_ bytes: Data) async throws { sent.append(bytes) }
    func resize(_ size: TerminalSize) async throws {}
    func close() async {}
}

@Test func earlySSHOutputAndTerminalRepliesSurviveAttachAndFrameCaching() async throws {
    let engine = try AppleTerminalEngine(columns: 80, rows: 24)
    let transport = EarlyOutputTransport()
    let coordinator = TerminalSessionCoordinator(transportFactory: { transport }, engine: engine)
    try await coordinator.connect()
    #expect(coordinator.state == .connected)
    let initial = try await coordinator.frameSnapshot()
    let frame = try TerminalFrame.decode(initial)
    #expect(frame.cells.prefix(12).map(\.text).joined() == "EARLY BANNER")
    #expect(await transport.sent == [Data("\u{1b}[1;13R".utf8)])
    for _ in 0..<100 { #expect(try await coordinator.frameSnapshot() == initial) }
    try await engine.write(Data("new".utf8))
    #expect(try await coordinator.frameSnapshot() != initial)
    await coordinator.resize(columns: 40, rows: 10)
    let resized = try TerminalFrame.decode(await coordinator.frameSnapshot())
    #expect(resized.columns == 40 && resized.rows == 10)
    await coordinator.shutdown()
    await #expect(throws: TerminalTransportError.closed) { try await coordinator.connect() }
}
#endif
