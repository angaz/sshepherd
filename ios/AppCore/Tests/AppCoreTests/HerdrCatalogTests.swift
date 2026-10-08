import Foundation
import XCTest
@testable import AppCore

final class HerdrCatalogTests: XCTestCase {
    private func snapshot(boot: String = "fixture", revision: UInt64 = 7) throws -> HerdrCatalog {
        // Shape from Herdr's stable endpoint, not the public workspace.list API.
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":"w1",
         "focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","future_field":true,
         "workspaces":[
           {"workspace_id":"w1","number":1,"label":"Desktop","focused":true,"agent_status":"working"},
           {"workspace_id":"w2","number":2,"label":"Phone","focused":false,"agent_status":"future_status"}],
         "agents":[
           {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","name":"",
            "title":"Review changes","agent":"codex","agent_status":"working","focused":true},
           {"pane_id":"w2:p2","workspace_id":"w2","tab_id":"w2:t1",
            "terminal_title_stripped":"Build app","agent":"claude","agent_status":"future_status","focused":false}]}
        """
        return try JSONDecoder().decode(HerdrCatalog.self, from: Data(json.utf8))
    }

    func testDecodesEndpointIDsFocusAndUnknownStatus() throws {
        let catalog = try snapshot()
        XCTAssertEqual(catalog.focusedWorkspaceID, "w1")
        XCTAssertEqual(catalog.focusedTabID, "w1:t1")
        XCTAssertEqual(catalog.focusedPaneID, "w1:p1")
        XCTAssertEqual(catalog.agents.map(\.id), ["w1:p1", "w2:p2"])
        XCTAssertEqual(catalog.agents.map(\.label), ["Review changes", "Build app"])
        XCTAssertEqual(catalog.workspaces[1].agentStatus, "future_status")
    }

    func testSearchIsLocalAndDoesNotChangeFocusOrInventory() throws {
        let catalog = try snapshot()
        XCTAssertEqual(catalog.matchingWorkspaces("  PHONE  ").map(\.id), ["w2"])
        XCTAssertEqual(catalog.matchingAgents("CLAUDE").map(\.id), ["w2:p2"])
        XCTAssertEqual(catalog.matchingAgents("review").map(\.id), ["w1:p1"])
        XCTAssertEqual(catalog.matchingAgents("future_status").map(\.id), ["w2:p2"])
        XCTAssertTrue(catalog.matchingAgents("nonexistent").isEmpty)
        XCTAssertEqual(catalog.matchingAgents("   ").count, 2)
        XCTAssertEqual(catalog.focusedPaneID, "w1:p1")
        XCTAssertEqual(catalog.agents.count, 2)
    }

    func testStoreRejectsOldAndDuplicateRevisionsAndAcceptsNewBoot() throws {
        var store = HerdrCatalogStore()
        XCTAssertTrue(store.accept(try snapshot()))
        XCTAssertFalse(store.accept(try snapshot(revision: 6)))
        XCTAssertFalse(store.accept(try snapshot()))
        XCTAssertEqual(store.catalog?.revision, 7)
        XCTAssertTrue(store.accept(try snapshot(revision: 8)))
        XCTAssertTrue(store.accept(try snapshot(boot: "restarted", revision: 1)))
        XCTAssertEqual(store.catalog?.bootID, "restarted")
        store.reset()
        XCTAssertNil(store.catalog)
        XCTAssertTrue(store.accept(try snapshot(revision: 1)))
    }

    func testRejectsIncompleteCatalogRatherThanInventingTargets() {
        XCTAssertThrowsError(try JSONDecoder().decode(HerdrCatalog.self, from: Data("{\"boot_id\":\"x\",\"revision\":1}".utf8)))
    }
}
