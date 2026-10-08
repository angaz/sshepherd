import AppUI
import Foundation
import Testing
@testable import AppCore

private func bridgePacket(_ value: [String: Any]) throws -> Data {
    var data = HerdrBridgeStream.prefix
    data.append(try JSONSerialization.data(withJSONObject: value).base64EncodedData())
    data.append(7)
    return data
}

private func bridgeCatalog() -> [String: Any] {
    ["boot_id": "fixture", "revision": 1, "focused_workspace_id": "w1", "focused_pane_id": "w1:p1",
     "workspaces": [["workspace_id": "w1", "label": "One", "number": 1, "focused": true, "agent_status": "working"]],
     "agents": [["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t1", "title": "Review", "focused": true, "agent_status": "working"]]]
}

@Test func bridgeStreamHandlesEveryByteBoundaryWithoutLeakingCatalogIntoTerminal() throws {
    let packet = try bridgePacket(["type": "catalog", "catalog": bridgeCatalog()])
    let stream = Data("before\u{1b}[31m".utf8) + packet + Data("after\u{1b}[0m".utf8)
    var parser = HerdrBridgeStream()
    var terminal = Data()
    var messages: [HerdrBridgeMessage] = []
    for byte in stream {
        let (text, decoded) = try parser.feed(Data([byte]))
        terminal.append(text)
        messages.append(contentsOf: decoded)
    }
    #expect(terminal == Data("before\u{1b}[31mafter\u{1b}[0m".utf8))
    #expect(messages.count == 1)
    #expect(messages.first?.catalog?.agents.first?.id == "w1:p1")
}

@Test func bridgeStreamPreservesOtherOSCSequencesAndRejectsMalformedPrivateMessages() throws {
    var parser = HerdrBridgeStream()
    let normal = Data("\u{1b}]0;window title\u{7}\u{1b}]52;c;YWJj\u{7}".utf8)
    let (text, messages) = try parser.feed(normal)
    #expect(text == normal)
    #expect(messages.isEmpty)
    #expect(throws: HerdrBrowserError.self) { try parser.feed(HerdrBridgeStream.prefix + Data("bad!\u{7}".utf8)) }
    var oversized = HerdrBridgeStream()
    #expect(throws: HerdrBrowserError.self) {
        try oversized.feed(HerdrBridgeStream.prefix + Data(repeating: 65, count: 4 * 1024 * 1024))
    }
}

private actor BridgeEngine: NativeTerminalEngine {
    var output = Data()
    func write(_ data: Data) { output.append(data) }
    func resize(_ size: TerminalSize) {}
    func frame() -> Data { output }
    func replies() -> Data { Data() }
    func key(_ event: TerminalKeyEvent) -> Data { Data() }
    func mouse(_ event: TerminalMouseEvent) -> Data { Data() }
    func close() {}
}

private actor BridgeTransport: SSHStreamingTransport {
    var receiver: (@Sendable (Data) async -> Void)?
    var sent: [Data] = []
    let refused: Bool
    init(refused: Bool = false) { self.refused = refused }
    func attach(command: String, pty: TerminalSize, receive: @escaping @Sendable (Data) async -> Void) async throws {
        receiver = receive
        await receive(try bridgePacket(["type": "catalog", "catalog": bridgeCatalog()]) + Data("terminal only".utf8))
    }
    func send(_ bytes: Data) async throws {
        sent.append(bytes)
        let encoded = bytes.dropFirst(HerdrBridgeStream.prefix.count).dropLast()
        let object = try JSONSerialization.jsonObject(with: Data(base64Encoded: Data(encoded))!) as! [String: Any]
        var result: [String: Any] = ["type": "result", "id": object["id"]!]
        if refused { result["error"] = "selection no longer exists" }
        await receiver?(try bridgePacket(result))
    }
    func resize(_ size: TerminalSize) {}
    func close() {}
}

@Test func browserSelectionsUseStableIDsAndAcknowledgementsWithoutSendingSearchInput() async throws {
    let transport = BridgeTransport(), engine = BridgeEngine()
    let coordinator = TerminalSessionCoordinator(transportFactory: { transport }, engine: engine)
    try await coordinator.connect()
    let catalog = await coordinator.herdrCatalog()
    #expect(catalog?.matchingAgents("review").count == 1)
    #expect(await transport.sent.isEmpty)
    #expect(await engine.output == Data("terminal only".utf8))
    try await coordinator.selectHerdrWorkspace("w1")
    try await coordinator.selectHerdrAgent("w1:p1")
    #expect(await transport.sent.count == 2)
    do {
        try await coordinator.selectHerdrAgent("deleted")
        Issue.record("Missing target was accepted")
    } catch { #expect(error as? HerdrBrowserError != nil) }
    #expect(await transport.sent.count == 2)
    await coordinator.detach()
    #expect(await coordinator.herdrCatalog() == nil)
    await coordinator.shutdown()
}

@Test func lastViewRestoresThroughTheSameClientEndpointAndRejectsReusedIDs() async throws {
    let transport = BridgeTransport()
    let coordinator = TerminalSessionCoordinator(transportFactory: { transport }, engine: BridgeEngine())
    try await coordinator.connect()
    let catalog = try #require(await coordinator.herdrCatalog())
    let saved = try #require(RememberedHerdrView(catalog: catalog))
    try await coordinator.restoreHerdrView(saved)
    #expect(await transport.sent.count == 1)
    var expiredJSON = bridgeCatalog()
    expiredJSON["boot_id"] = "earlier-server-boot"
    let expiredCatalog = try JSONDecoder().decode(HerdrCatalog.self, from: JSONSerialization.data(withJSONObject: expiredJSON))
    let expired = try #require(RememberedHerdrView(catalog: expiredCatalog))
    do {
        try await coordinator.restoreHerdrView(expired)
        Issue.record("IDs from a different server boot were restored")
    } catch { #expect(error as? HerdrBrowserError != nil) }
    #expect(await transport.sent.count == 1)
    await coordinator.shutdown()
}

@Test func browserDisplaysRefusalRatherThanTreatingSentInputAsSuccess() async throws {
    let transport = BridgeTransport(refused: true)
    let coordinator = TerminalSessionCoordinator(transportFactory: { transport }, engine: BridgeEngine())
    try await coordinator.connect()
    do {
        try await coordinator.selectHerdrAgent("w1:p1")
        Issue.record("Refused selection appeared successful")
    } catch { #expect(error.localizedDescription == "selection no longer exists") }
    await coordinator.shutdown()
}
