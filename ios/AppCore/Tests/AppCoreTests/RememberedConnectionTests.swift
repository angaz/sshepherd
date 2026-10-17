import Foundation
import SecurityCore
import Testing
@testable import AppCore

private final class NavigationMemory: AtomicDataStore, @unchecked Sendable {
    var bytes: Data?
    var failWrites = false
    func read() -> Data? { bytes }
    func replace(with data: Data) throws {
        if failWrites { throw InventoryError.storageFailure }
        bytes = data
    }
}

private func resumeCatalog(boot: String = "boot", workspace: String = "w1", pane: String? = "w1:p1", available: Bool = true) throws -> HerdrCatalog {
    var json: [String: Any] = ["boot_id": boot, "revision": 1, "focused_workspace_id": workspace,
        "workspaces": available ? [["workspace_id": workspace, "label": "Workspace", "number": 1, "focused": true, "agent_status": "idle"]] : [],
        "agents": [], "panes": available ? [["pane_id": "w1:p1", "workspace_id": workspace]] : []]
    if let pane { json["focused_pane_id"] = pane }
    return try JSONDecoder().decode(HerdrCatalog.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func selectedServerSurvivesStoreRecreationAndOverridesSingleServerMigration() throws {
    let memory = NavigationMemory()
    let store = try RememberedConnectionStore(storage: memory)
    let first = UUID(), second = UUID()
    #expect(store.startupServerID(available: [first]) == first)
    #expect(store.startupServerID(available: [first, second]) == nil)
    #expect(store.startupServerID(available: []) == nil)
    try store.selectServer(second)
    let relaunched = try RememberedConnectionStore(storage: memory)
    #expect(relaunched.startupServerID(available: [first, second]) == second)
    #expect(relaunched.startupServerID(available: [first]) == nil, "Deleting the chosen server must not silently choose a different server")
}

@Test func phoneViewPersistenceIsServerScopedAndContainsNoTerminalContents() throws {
    let memory = NavigationMemory()
    let store = try RememberedConnectionStore(storage: memory)
    let server = UUID(), other = UUID()
    let view = try #require(RememberedHerdrView(catalog: resumeCatalog()))
    try store.selectServer(server)
    try store.remember(view, for: server)
    let relaunched = try RememberedConnectionStore(storage: memory)
    #expect(relaunched.view(for: server) == view)
    #expect(relaunched.view(for: other) == nil)
    #expect(view.target(in: try resumeCatalog()) == .pane("w1:p1"), "A non-agent shell pane must also be restorable")
    let json = try #require(memory.bytes)
    #expect(!String(decoding: json, as: UTF8.self).contains("Workspace"))
}

@Test func resumeFallsBackForDeletedWorkspacePaneOrDifferentEndpointBoot() throws {
    let view = try #require(RememberedHerdrView(catalog: resumeCatalog()))
    #expect(view.target(in: try resumeCatalog(boot: "restarted")) == nil)
    #expect(view.target(in: try resumeCatalog(available: false)) == nil)
    #expect(view.target(in: try resumeCatalog(workspace: "w2")) == nil)
    let deletedPane = try JSONDecoder().decode(HerdrCatalog.self, from: Data("""
        {"boot_id":"boot","revision":2,"workspaces":[{"workspace_id":"w1","label":"One","number":1,"focused":true,"agent_status":"idle"}],"agents":[],"panes":[]}
        """.utf8))
    #expect(view.target(in: deletedPane) == nil)
    let workspaceOnly = try #require(RememberedHerdrView(catalog: resumeCatalog(pane: nil)))
    #expect(workspaceOnly.target(in: try resumeCatalog()) == .workspace("w1"))
}

@Test func corruptOptionalNavigationAndFailedWritesDoNotInventSelections() throws {
    let memory = NavigationMemory()
    memory.bytes = Data("not json".utf8)
    let store = try RememberedConnectionStore(storage: memory)
    #expect(store.selectedServerID == nil)
    let first = UUID(), second = UUID()
    try store.selectServer(first)
    memory.failWrites = true
    #expect(throws: InventoryError.self) { try store.selectServer(second) }
    #expect(store.selectedServerID == first)
}
