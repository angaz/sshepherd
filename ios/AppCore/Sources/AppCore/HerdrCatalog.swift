import Foundation

/// The client-local projection delivered by Herdr's `shell.snapshot.v1` endpoint.
/// Do not substitute the public socket's session-wide focus projection.
public struct HerdrCatalog: Decodable, Equatable, Sendable {
    public let bootID: String
    public let revision: UInt64
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let workspaces: [Workspace]
    public let agents: [Agent]
    public let panes: [Pane]?

    enum CodingKeys: String, CodingKey {
        case bootID = "boot_id", revision
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces, agents, panes
    }

    public struct Workspace: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let number: Int
        public let focused: Bool
        public let agentStatus: String
        enum CodingKeys: String, CodingKey {
            case id = "workspace_id", label, number, focused
            case agentStatus = "agent_status"
        }
    }

    public struct Pane: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let workspaceID: String
        enum CodingKeys: String, CodingKey {
            case id = "pane_id", workspaceID = "workspace_id"
        }
    }

    public struct Agent: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let workspaceID: String
        public let tabID: String
        public let name: String?
        public let displayAgent: String?
        public let agent: String?
        public let title: String?
        public let terminalTitle: String?
        public let terminalTitleStripped: String?
        public let agentStatus: String
        public let focused: Bool

        public var label: String {
            [name, title, terminalTitleStripped, terminalTitle, displayAgent, agent]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? id
        }

        enum CodingKeys: String, CodingKey {
            case id = "pane_id", workspaceID = "workspace_id", tabID = "tab_id"
            case name, agent, title, focused
            case displayAgent = "display_agent", terminalTitle = "terminal_title"
            case terminalTitleStripped = "terminal_title_stripped", agentStatus = "agent_status"
        }
    }

    public func matchingWorkspaces(_ query: String) -> [Workspace] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces.filter { term.isEmpty || $0.label.localizedStandardContains(term) || $0.id.localizedStandardContains(term) }
    }

    public func matchingAgents(_ query: String) -> [Agent] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.filter { item in
            term.isEmpty || [item.label, item.id, item.agent ?? "", item.workspaceID, item.agentStatus]
                .contains { $0.localizedStandardContains(term) }
        }
    }
}

/// Rejects reordered snapshots, while allowing a new endpoint boot to restart revisions.
/// Call `reset()` when the SSH connection changes; boot IDs are not ordered timestamps.
public struct HerdrCatalogStore: Sendable {
    public private(set) var catalog: HerdrCatalog?
    public init() {}

    @discardableResult
    public mutating func accept(_ incoming: HerdrCatalog) -> Bool {
        if let current = catalog, current.bootID == incoming.bootID, incoming.revision <= current.revision {
            return false
        }
        catalog = incoming
        return true
    }

    public mutating func reset() { catalog = nil }
}
