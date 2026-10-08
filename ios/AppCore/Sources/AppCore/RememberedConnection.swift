import Foundation
import SecurityCore

/// Only navigation identifiers, never credentials, terminal input, or screen contents.
public struct RememberedHerdrView: Codable, Equatable, Sendable {
    public let bootID: String
    public let workspaceID: String
    public let paneID: String?

    public init?(catalog: HerdrCatalog) {
        guard !catalog.bootID.isEmpty, let workspace = catalog.focusedWorkspaceID,
              catalog.workspaces.contains(where: { $0.id == workspace }) else { return nil }
        bootID = catalog.bootID
        workspaceID = workspace
        paneID = catalog.focusedPaneID
    }

    public enum Target: Equatable, Sendable { case workspace(String), pane(String) }
    public func target(in catalog: HerdrCatalog) -> Target? {
        // A reboot can reuse public IDs for different resources. Never guess.
        guard catalog.bootID == bootID, catalog.workspaces.contains(where: { $0.id == workspaceID }) else { return nil }
        if let paneID {
            let paneExists = catalog.panes?.contains(where: { $0.id == paneID && $0.workspaceID == workspaceID }) == true
                || catalog.agents.contains(where: { $0.id == paneID && $0.workspaceID == workspaceID })
            return paneExists ? .pane(paneID) : nil
        }
        return .workspace(workspaceID)
    }
}

/// Atomic app-local navigation state, scoped to the configured server UUID.
public final class RememberedConnectionStore: @unchecked Sendable {
    private struct State: Codable {
        var selectedServerID: UUID?
        var views: [String: RememberedHerdrView] = [:]
    }
    private let storage: any AtomicDataStore
    private let lock = NSLock()
    private var state: State

    public init(storage: any AtomicDataStore) throws {
        self.storage = storage
        if let bytes = try storage.read(), let decoded = try? JSONDecoder().decode(State.self, from: bytes) {
            state = decoded
        } else {
            // Corrupt optional navigation state must not discard servers or trust.
            state = State()
        }
    }

    public var selectedServerID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return state.selectedServerID
    }

    public func selectServer(_ id: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        var next = state
        next.selectedServerID = id
        try save(next)
    }

    public func view(for serverID: UUID) -> RememberedHerdrView? {
        lock.lock(); defer { lock.unlock() }
        return state.views[serverID.uuidString]
    }

    public func remember(_ view: RememberedHerdrView, for serverID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard state.views[serverID.uuidString] != view else { return }
        var next = state
        next.views[serverID.uuidString] = view
        try save(next)
    }

    private func save(_ next: State) throws {
        try storage.replace(with: JSONEncoder().encode(next))
        state = next
    }

    /// Prefer the explicit selection; only migrate automatically when there is one server.
    public func startupServerID(available: [UUID]) -> UUID? {
        if let selected = selectedServerID { return available.contains(selected) ? selected : nil }
        return available.count == 1 ? available.first : nil
    }
}
