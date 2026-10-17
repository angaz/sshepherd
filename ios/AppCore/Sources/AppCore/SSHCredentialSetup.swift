import AppUI
import Foundation
import SecurityCore

/// Separates first-use credential setup from connecting with an already saved credential.
/// This never offers credentials to a server or bypasses SSH host-key verification.
public enum SSHCredentialSetup {
    public static func isReady(for host: AppUI.Host, secrets: any SecretStore) throws -> Bool {
        do {
            switch host.authentication {
            case .ed25519:
                _ = try SSHKey.load(from: secrets, serverID: host.id)
            case .password:
                let data = try secrets.read(serverID: host.id, kind: .password)
                guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                    throw KeychainError.invalidData
                }
            }
            return true
        } catch KeychainError.notFound {
            return false
        }
    }

    /// Returns only the public key. Reuses the saved key and never overwrites an unreadable key.
    public static func preparePublicKey(serverID: UUID, secrets: any SecretStore) throws -> String {
        let key: SSHKey
        do {
            key = try SSHKey.load(from: secrets, serverID: serverID)
        } catch KeychainError.notFound {
            key = SSHKey()
            try key.save(to: secrets, serverID: serverID)
        }
        return key.authorizedKeysLine
    }
}
