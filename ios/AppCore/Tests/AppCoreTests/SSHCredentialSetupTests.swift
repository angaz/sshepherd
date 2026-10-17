import AppCore
import AppUI
import Foundation
import SecurityCore
import Testing

@Test func savedCredentialsRouteDirectlyToConnectionWithoutOverwritingThem() throws {
    let store = InMemorySecretStore()
    var host = AppUI.Host(name: "Fixture", address: "192.168.1.10", username: "fixture")
    #expect(try !SSHCredentialSetup.isReady(for: host, secrets: store))
    let firstPublicKey = try SSHCredentialSetup.preparePublicKey(serverID: host.id, secrets: store)
    let original = try store.read(serverID: host.id, kind: .privateKey)
    #expect(try SSHCredentialSetup.isReady(for: host, secrets: store))
    #expect(try SSHCredentialSetup.preparePublicKey(serverID: host.id, secrets: store) == firstPublicKey)
    #expect(try store.read(serverID: host.id, kind: .privateKey) == original)
    let message = Data("public key matches the device-only saved private key".utf8)
    let key = try SSHKey.load(from: store, serverID: host.id)
    #expect(try SSHKey.verify(signature: key.signature(for: message), for: message, authorizedKeysLine: firstPublicKey))

    host.authentication = .password
    #expect(try !SSHCredentialSetup.isReady(for: host, secrets: store))
    try store.save(Data("fixture password".utf8), serverID: host.id, kind: .password)
    #expect(try SSHCredentialSetup.isReady(for: host, secrets: store))
    #expect(try store.read(serverID: host.id, kind: .password) == Data("fixture password".utf8))
    #expect(try store.read(serverID: host.id, kind: .privateKey) == original)
    let other = AppUI.Host(name: "Other", address: "192.168.1.11", username: "fixture")
    #expect(try !SSHCredentialSetup.isReady(for: other, secrets: store))
}

private final class DeniedSecretStore: SecretStore, @unchecked Sendable {
    func read(serverID: UUID, kind: CredentialKind) throws -> Data { throw KeychainError.accessDenied }
    func save(_ data: Data, serverID: UUID, kind: CredentialKind) throws { Issue.record("Must not replace an inaccessible credential") }
    func delete(serverID: UUID, kind: CredentialKind) throws { Issue.record("Must not delete an inaccessible credential") }
}

@Test func inaccessibleOrCorruptCredentialsDoNotGenerateReplacementKeys() throws {
    let host = AppUI.Host(name: "Fixture", address: "192.168.1.10", username: "fixture")
    let denied = DeniedSecretStore()
    #expect(throws: KeychainError.accessDenied) { try SSHCredentialSetup.isReady(for: host, secrets: denied) }
    #expect(throws: KeychainError.accessDenied) { try SSHCredentialSetup.preparePublicKey(serverID: host.id, secrets: denied) }

    let corrupt = InMemorySecretStore()
    let invalidKey = Data([1, 2, 3])
    try corrupt.save(invalidKey, serverID: host.id, kind: .privateKey)
    #expect(throws: (any Error).self) { try SSHCredentialSetup.preparePublicKey(serverID: host.id, secrets: corrupt) }
    #expect(try corrupt.read(serverID: host.id, kind: .privateKey) == invalidKey)
    var passwordHost = host
    passwordHost.authentication = .password
    try corrupt.save(Data([0xff]), serverID: host.id, kind: .password)
    #expect(throws: KeychainError.invalidData) { try SSHCredentialSetup.isReady(for: passwordHost, secrets: corrupt) }
}
