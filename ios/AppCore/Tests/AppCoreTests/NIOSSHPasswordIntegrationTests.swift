#if DEBUG
@testable import AppCore
import Foundation
import SecurityCore
import XCTest

/// Reads only the disposable fixture's credential, and records actual store reads.
private final class FixturePasswordStore: SecretStore, @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var reads = 0
    init(path: String) { self.path = path }
    func read(serverID: UUID, kind: CredentialKind) throws -> Data {
        lock.lock(); reads += 1; lock.unlock()
        guard kind == .password else { throw KeychainError.notFound }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
    func save(_ data: Data, serverID: UUID, kind: CredentialKind) throws { throw KeychainError.accessDenied }
    func delete(serverID: UUID, kind: CredentialKind) throws { throw KeychainError.accessDenied }
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
}

private final class PasswordStreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var fulfilled = false
    private var eofCount = 0
    private var dataAfterEOF = false
    let marker: XCTestExpectation
    let eof: XCTestExpectation
    init(marker: XCTestExpectation, eof: XCTestExpectation) { self.marker = marker; self.eof = eof }
    func append(_ value: Data) {
        lock.lock()
        if eofCount > 0 && !value.isEmpty { dataAfterEOF = true }
        if value.isEmpty { eofCount += 1 }
        bytes.append(value)
        let text = String(decoding: bytes, as: UTF8.self)
        let complete = !fulfilled && (text.contains("PASSWORD_EXEC:hello\r\n") || text.contains("PASSWORD_EXEC:hello\n"))
        if complete { fulfilled = true }
        let firstEOF = value.isEmpty && eofCount == 1
        lock.unlock()
        if complete { marker.fulfill() }
        if firstEOF { eof.fulfill() }
    }
    func snapshot() -> (String, Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: bytes, as: UTF8.self), eofCount, dataAfterEOF)
    }
}

final class NIOSSHPasswordIntegrationTests: XCTestCase {
    private struct Fixture {
        let host: String, port: UInt16, user: String, passwordPath: String, identity: HostIdentity
    }
    private func fixture() throws -> Fixture {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["APP_SSH_PASSWORD_HOST"], let port = env["APP_SSH_PASSWORD_PORT"].flatMap(UInt16.init),
              let user = env["APP_SSH_PASSWORD_USER"], let keyPath = env["APP_SSH_PASSWORD_HOST_KEY"],
              let passwordPath = env["APP_SSH_PASSWORD_FILE"] else {
            throw XCTSkip("The private stock OpenSSH password fixture supplies these variables")
        }
        guard host == "127.0.0.1", URL(fileURLWithPath: passwordPath).lastPathComponent == "fixture-password.private" else {
            throw SSHTransportError.invalidEndpoint
        }
        let fields = try String(contentsOfFile: keyPath, encoding: .utf8).split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { throw KeychainError.invalidData }
        return Fixture(host: host, port: port, user: user, passwordPath: passwordPath,
                       identity: try HostIdentity(host: host, port: port, algorithm: String(fields[0]), blob: blob))
    }

    func testFixtureAddressPolicyIsLiteralOnlyAndDefaultRejectsLoopback() async throws {
        let secrets = InMemorySecretStore(), known = InMemoryKnownHosts()
        for host in ["8.8.8.8", "2001:4860:4860::8888", "::1", "127.0.0.2", "localhost", "10.0.0.1"] {
            let configuration = SSHTransportConfiguration(serverID: UUID(), host: host, port: 22, username: "synthetic-fixture",
                authentication: .password, knownHosts: known, secrets: secrets, confirmUnknownFingerprint: { _ in
                    XCTFail("Rejected fixture addresses must not reach trust"); return false
                })
            XCTAssertThrowsError(try NIOSSHStreamingTransport(loopbackFixture: configuration)) {
                XCTAssertEqual($0 as? SSHTransportError, .invalidEndpoint)
            }
        }
        for host in ["127.0.0.1", "8.8.8.8", "2001:4860:4860::8888"] {
            let transport = NIOSSHStreamingTransport(configuration: SSHTransportConfiguration(
                serverID: UUID(), host: host, port: 22, username: "synthetic-fixture", authentication: .password,
                knownHosts: known, secrets: secrets, confirmUnknownFingerprint: { _ in
                    XCTFail("Default must reject before host confirmation"); return false
                }))
            do {
                try await transport.attach(command: "synthetic-no-exec", pty: TerminalSize(columns: 80, rows: 24)) { _ in }
                XCTFail("Production default must reject loopback/public addresses")
            } catch { XCTAssertEqual(error as? SSHTransportError, .noTrustedAddress) }
            await transport.close()
        }
    }

    func testStockOpenSSHPasswordPTYExecStreamingResizeAndEOF() async throws {
        let f = try fixture(), secrets = FixturePasswordStore(path: f.passwordPath), known = InMemoryKnownHosts()
        let transport = try NIOSSHStreamingTransport(loopbackFixture: SSHTransportConfiguration(
            serverID: UUID(), host: f.host, port: f.port, username: f.user, authentication: .password,
            knownHosts: known, secrets: secrets, confirmUnknownFingerprint: { identity in
                XCTAssertEqual(identity, f.identity); return identity == f.identity
            }))
        let capture = PasswordStreamCapture(marker: expectation(description: "password-authenticated exec marker"),
                                            eof: expectation(description: "ordered EOF"))
        try await transport.attach(command: "i=0; while [ $i -lt 4096 ]; do printf 'PWSTREAM:%05d\\n' $i; i=$((i+1)); done; read value; sleep 1; stty size; printf 'PASSWORD_EXEC:%s\\n' \"$value\"; sleep 30",
                                   pty: TerminalSize(columns: 80, rows: 24)) { capture.append($0) }
        try await transport.resize(TerminalSize(columns: 101, rows: 37, cellWidth: 9, cellHeight: 18))
        try await transport.send(Data("hel".utf8)); try await transport.send(Data("lo\n".utf8))
        await fulfillment(of: [capture.marker], timeout: 10)
        let before = capture.snapshot().0
        XCTAssertTrue(before.contains("PASSWORD_EXEC:hello\r\n") || before.contains("PASSWORD_EXEC:hello\n"), "complete exec marker line missing")
        let closing = ContinuousClock().now
        await transport.close()
        XCTAssertLessThan(closing.duration(to: ContinuousClock().now), .seconds(7))
        await fulfillment(of: [capture.eof], timeout: 3)
        let after = capture.snapshot()
        XCTAssertTrue(after.0.contains("37 101"), "PTY resize missing")
        let records = after.0.components(separatedBy: "PWSTREAM:").dropFirst().map { String($0.prefix(5)) }
        XCTAssertEqual(records, (0..<4096).map { String(format: "%05d", $0) })
        XCTAssertEqual(after.1, 1); XCTAssertFalse(after.2)
        XCTAssertEqual(secrets.readCount(), 1)
        XCTAssertEqual(try known.identity(for: f.host, port: f.port), f.identity)
    }

    func testStockOpenSSHWrongPasswordRejected() async throws {
        let f = try fixture(), secrets = InMemorySecretStore(), known = InMemoryKnownHosts(), id = UUID()
        try secrets.save(Data("deliberately-wrong-fixture-password".utf8), serverID: id, kind: .password)
        try known.trust(f.identity)
        let transport = try NIOSSHStreamingTransport(loopbackFixture: SSHTransportConfiguration(
            serverID: id, host: f.host, port: f.port, username: f.user, authentication: .password,
            knownHosts: known, secrets: secrets, confirmUnknownFingerprint: { _ in XCTFail("already trusted"); return false }))
        do {
            try await transport.attach(command: "printf WRONG_PASSWORD_EXEC", pty: TerminalSize(columns: 80, rows: 24)) { _ in }
            XCTFail("Wrong password must never permit exec")
        } catch { XCTAssertEqual(error as? SSHTransportError, .authenticationUnavailable) }
        await transport.close()
    }

    func testStockOpenSSHChangedAndUnapprovedHostRejectedBeforePasswordRead() async throws {
        let f = try fixture()
        for changed in [false, true] {
            let secrets = FixturePasswordStore(path: f.passwordPath), known = InMemoryKnownHosts()
            if changed {
                try known.trust(try HostIdentity(host: f.host, port: f.port, algorithm: "ssh-ed25519", blob: Data(repeating: 7, count: 51)))
            }
            let transport = try NIOSSHStreamingTransport(loopbackFixture: SSHTransportConfiguration(
                serverID: UUID(), host: f.host, port: f.port, username: f.user, authentication: .password,
                knownHosts: known, secrets: secrets, confirmUnknownFingerprint: { identity in
                    XCTAssertFalse(changed, "Changed keys are not first use"); XCTAssertEqual(identity, f.identity); return false
                }))
            do {
                try await transport.attach(command: "printf UNTRUSTED_EXEC", pty: TerminalSize(columns: 80, rows: 24)) { _ in }
                XCTFail("Untrusted host must never permit exec")
            } catch { XCTAssertEqual(error as? SSHTransportError, changed ? .changedHostKey : .unknownHostRejected) }
            await transport.close()
            XCTAssertEqual(secrets.readCount(), 0, "Host rejection must precede actual credential-store reads")
            XCTAssertEqual(try known.identity(for: f.host, port: f.port) == f.identity, false)
        }
    }
}

#endif
