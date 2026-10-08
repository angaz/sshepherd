import NIOCore
import XCTest
@testable import SSHProof

final class SSHProofTests: XCTestCase {
    private func fixtureClient() -> SSHProofClient { SSHProofClient(addressPolicy: .loopbackFixture) }

    func testHostIdentityIncludesEndpointAndFingerprint() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA== fixture"
        let identity = HostKeyIdentity(host: "mesh.example", port: 2222, openSSHKey: key)
        XCTAssertEqual(identity.host, "mesh.example")
        XCTAssertEqual(identity.port, 2222)
        XCTAssertTrue(identity.sha256Fingerprint.hasPrefix("SHA256:"))
        XCTAssertThrowsError(try SSHProofPTY(columns: 0, rows: 24))
    }

    func testStockOpenSSHFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["SSH_PROOF_PORT"], let port = Int(portText),
              let hostKeyPath = env["SSH_PROOF_HOST_KEY"], let privateKey = env["SSH_PROOF_CLIENT_PRIVATE_KEY"] else {
            XCTFail("scripts/test-ios-ssh.sh must provide the isolated fixture; skipping is a failure")
            return
        }
        let hostKey = try String(contentsOfFile: hostKeyPath, encoding: .utf8)
        let trusted = HostKeyIdentity(host: "127.0.0.1", port: port, openSSHKey: hostKey)
        let auth = SSHProofAuthentication.ed25519(privateKeyBase64: privateKey)

        let client = fixtureClient()
        let result = try client.exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!,
                                     authentication: auth, trustedHost: trusted,
                                     command: "read value; stty size; printf 'input=%s\\n' \"$value\"; exit 7",
                                     pty: try SSHProofPTY(columns: 80, rows: 24), input: Data("fixture-input\n".utf8),
                                     resize: (columns: 101, rows: 37))
        let output = String(decoding: result.output, as: UTF8.self)
        XCTAssertEqual(result.exitStatus, 7)
        XCTAssertTrue(output.contains("input=fixture-input"), output)
        XCTAssertTrue(output.contains("37 101"), output)
    }

    func testMissingKnownHostAndChangedHostAreDistinctBeforeAuthentication() throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["SSH_PROOF_PORT"], let port = Int(portText),
              let privateKey = env["SSH_PROOF_CLIENT_PRIVATE_KEY"] else {
            XCTFail("scripts/test-ios-ssh.sh must provide the isolated fixture; skipping is a failure")
            return
        }
        let missingClient = fixtureClient()
        XCTAssertThrowsError(try missingClient.exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!,
            authentication: .ed25519(privateKeyBase64: privateKey), trustedHost: nil, command: "true",
            timeout: .seconds(2))) { XCTAssertEqual($0 as? SSHProofError, .unknownHostKey) }
        XCTAssertEqual(missingClient.authenticationOfferCount, 0)

        let changed = HostKeyIdentity(host: "127.0.0.1", port: port, openSSHKey: Ed25519Credentials().publicKey)
        let changedClient = fixtureClient()
        XCTAssertThrowsError(try changedClient.exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!,
            authentication: .ed25519(privateKeyBase64: privateKey), trustedHost: changed, command: "true",
            timeout: .seconds(2))) { XCTAssertEqual($0 as? SSHProofError, .changedHostKey) }
        XCTAssertEqual(changedClient.authenticationOfferCount, 0, "host rejection must precede USERAUTH")
    }

    func testOutputLimitAndCancellation() throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["SSH_PROOF_PORT"], let port = Int(portText),
              let hostKeyPath = env["SSH_PROOF_HOST_KEY"], let privateKey = env["SSH_PROOF_CLIENT_PRIVATE_KEY"] else {
            XCTFail("scripts/test-ios-ssh.sh must provide the isolated fixture; skipping is a failure")
            return
        }
        let trusted = HostKeyIdentity(host: "127.0.0.1", port: port,
                                      openSSHKey: try String(contentsOfFile: hostKeyPath))
        let auth = SSHProofAuthentication.ed25519(privateKeyBase64: privateKey)
        XCTAssertThrowsError(try fixtureClient().exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!,
            authentication: auth, trustedHost: trusted, command: "yes x | head -c 4096", outputLimit: 64)) { XCTAssertEqual($0 as? SSHProofError, .outputLimitExceeded) }
        XCTAssertThrowsError(try fixtureClient().exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!,
            authentication: auth, trustedHost: trusted, command: "sleep 30", timeout: .milliseconds(200))) { XCTAssertEqual($0 as? SSHProofError, .timedOut) }
        let cancellation = SSHProofClient.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        XCTAssertThrowsError(try fixtureClient().exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!,
            authentication: auth, trustedHost: trusted, command: "sleep 30", timeout: .seconds(5), cancellation: cancellation)) {
            XCTAssertEqual($0 as? SSHProofError, .cancelled)
        }
        XCTAssertThrowsError(try fixtureClient().exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!,
            authentication: .ed25519(privateKeyBase64: Ed25519Credentials().privateKeyBase64), trustedHost: trusted,
            command: "true", timeout: .seconds(2))) { XCTAssertEqual($0 as? SSHProofError, .authenticationRejected) }
    }

    func testAddressPolicyIsExact() {
        XCTAssertTrue(trustedPrivateAddress("10.0.0.1"))
        XCTAssertTrue(trustedPrivateAddress("172.16.0.1"))
        XCTAssertTrue(trustedPrivateAddress("192.168.1.1"))
        XCTAssertTrue(trustedPrivateAddress("100.64.0.1"))
        XCTAssertTrue(trustedPrivateAddress("fd00::1"))
        for ip in ["127.0.0.1", "8.8.8.8", "169.254.1.1", "::ffff:10.0.0.1", "10.1.bad.1", "10.1.1", "fc-not-an-ip", "fd:not-an-ip", "fd00:::1"] {
            XCTAssertFalse(trustedPrivateAddress(ip), ip)
        }
        XCTAssertTrue(trustedPrivateAddress("127.0.0.1", policy: .loopbackFixture))
        XCTAssertTrue(trustedPrivateAddress("::1", policy: .loopbackFixture))
    }

    func testEmptyInputSendsEOFAndPTYRejectionDoesNotExec() throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["SSH_PROOF_PORT"].flatMap(Int.init), let noTTYPort = env["SSH_PROOF_NO_TTY_PORT"].flatMap(Int.init),
              let hostKeyPath = env["SSH_PROOF_HOST_KEY"], let privateKey = env["SSH_PROOF_CLIENT_PRIVATE_KEY"],
              let marker = env["SSH_PROOF_NO_TTY_MARKER"] else { return XCTFail("fixture environment missing") }
        let key = try String(contentsOfFile: hostKeyPath)
        let auth = SSHProofAuthentication.ed25519(privateKeyBase64: privateKey)
        let eof = try fixtureClient().exec(host: "127.0.0.1", port: port, username: env["SSH_PROOF_USER"]!, authentication: auth,
            trustedHost: HostKeyIdentity(host: "127.0.0.1", port: port, openSSHKey: key), command: "cat")
        XCTAssertEqual(eof.exitStatus, 0); XCTAssertTrue(eof.output.isEmpty)

        XCTAssertThrowsError(try fixtureClient().exec(host: "127.0.0.1", port: noTTYPort, username: env["SSH_PROOF_USER"]!,
            authentication: auth, trustedHost: HostKeyIdentity(host: "127.0.0.1", port: noTTYPort, openSSHKey: key),
            command: "touch '\(marker)'", pty: try SSHProofPTY(columns: 80, rows: 24))) {
                XCTAssertEqual($0 as? SSHProofError, .ptyRejected)
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "exec must not start after rejected PTY")
    }

    func testResolverSharesDeadlineAndCompletionOrderingIsExactlyOnce() throws {
        let client = SSHProofClient(addressPolicy: .loopbackFixture) { _, _, _ in
            Thread.sleep(forTimeInterval: 0.5)
            return [try SocketAddress(ipAddress: "127.0.0.1", port: 22)]
        }
        let start = Date()
        XCTAssertThrowsError(try client.exec(host: "127.0.0.1", port: 22, username: "fixture",
            authentication: .ed25519(privateKeyBase64: Ed25519Credentials().privateKeyBase64), trustedHost: nil,
            command: "true", timeout: .milliseconds(50))) { XCTAssertEqual($0 as? SSHProofError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)

        var statusFirst = ProofCompletionState()
        XCTAssertNil(statusFirst.receivedExitStatus(7)); XCTAssertEqual(statusFirst.receivedInputClosed(), 7)
        XCTAssertNil(statusFirst.receivedInputClosed()); XCTAssertFalse(statusFirst.failOnce())
        var eofFirst = ProofCompletionState()
        XCTAssertNil(eofFirst.receivedInputClosed()); XCTAssertEqual(eofFirst.receivedExitStatus(9), 9)
        XCTAssertNil(eofFirst.receivedExitStatus(10)); XCTAssertFalse(eofFirst.failOnce())
    }
}
