import AppUI
import Foundation
import SecurityCore

public final class PersistentHostStore: HostStore, @unchecked Sendable {
    private let inventory: ServerInventory
    public init(inventory: ServerInventory) { self.inventory = inventory }
    public func hosts() async throws -> [AppUI.Host] {
        try inventory.load().map { AppUI.Host(id: $0.id, name: $0.name, address: $0.hostname, port: $0.port, username: $0.username, authentication: $0.authentication == .password ? .password : .ed25519) }
    }
    public func save(_ hosts: [AppUI.Host]) async throws {
        let servers = try hosts.map { try Server(id: $0.id, name: $0.name, hostname: $0.address, port: $0.port, username: $0.username, authentication: $0.authentication == .password ? .password : .ed25519) }
        try inventory.save(servers)
    }
}
