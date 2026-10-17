import AppCore
import Foundation
import SecurityCore
import XCTest

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock(); private var bytes = Data(); private var fulfilled = false
    let complete: XCTestExpectation
    let eof: XCTestExpectation
    private var eofCount = 0
    private var dataAfterEOF = false
    init(complete: XCTestExpectation, eof: XCTestExpectation) { self.complete = complete; self.eof = eof }
    func append(_ value: Data) {
        lock.lock()
        if eofCount > 0 && !value.isEmpty { dataAfterEOF = true }
        if value.isEmpty { eofCount += 1 }
        let firstEOF = value.isEmpty && eofCount == 1
        bytes.append(value)
        let shouldFulfill = !fulfilled && String(decoding: bytes, as: UTF8.self).contains("got=hello")
        if shouldFulfill { fulfilled = true }
        lock.unlock()
        if shouldFulfill { complete.fulfill() }
        if firstEOF { eof.fulfill() }
    }
    func eofStatus() -> (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (eofCount, dataAfterEOF) }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

final class NIOSSHStreamingIntegrationTests: XCTestCase {
    func testInteractiveTransportTrustStreamingResizeAndChangedKey() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["APP_SSH_HOST"], let portText = env["APP_SSH_PORT"], let port = UInt16(portText),
              let user = env["APP_SSH_USER"], let hostKeyPath = env["APP_SSH_HOST_KEY"],
              let privateBase64 = env["APP_SSH_CLIENT_PRIVATE_KEY"], let privateKey = Data(base64Encoded: privateBase64) else {
            throw XCTSkip("scripts/test-ios-app-ssh.sh supplies the isolated OpenSSH fixture")
        }
        let fields = try String(contentsOfFile: hostKeyPath, encoding: .utf8).split(separator: " ")
        let presented = try HostIdentity(host: host, port: port, algorithm: String(fields[0]), blob: Data(base64Encoded: String(fields[1]))!)
        let id = UUID(), secrets = InMemorySecretStore(), knownHosts = InMemoryKnownHosts(), events = EventRecorder()
        try secrets.save(privateKey, serverID: id, kind: .privateKey)
        let configuration = SSHTransportConfiguration(serverID: id, host: host, port: port, username: user,
            authentication: .ed25519, knownHosts: knownHosts, secrets: secrets,
            confirmUnknownFingerprint: { identity in
                XCTAssertEqual(identity, presented); events.append("consent"); return true
            }, lifecycleEvent: { events.append($0) })
        let received = expectation(description: "incremental interactive output")
        let ended = expectation(description: "ordered EOF after streamed output")
        let capture = StreamCapture(complete: received, eof: ended), transport = NIOSSHStreamingTransport(configuration: configuration)
        try await transport.attach(command: "i=0; while [ $i -lt 4096 ]; do printf 'STREAM:%05d\\n' $i; i=$((i+1)); done; read value; sleep 1; stty size; printf 'got=%s\\n' \"$value\"; sleep 30",
                                   pty: TerminalSize(columns: 80, rows: 24)) { capture.append($0) }
        try await transport.resize(TerminalSize(columns: 101, rows: 37, cellWidth: 9, cellHeight: 18))
        try await transport.send(Data("hel".utf8)); try await transport.send(Data("lo\n".utf8))
        await fulfillment(of: [received], timeout: 5)
        let output = capture.text()
        XCTAssertTrue(output.contains("got=hello"), output)
        XCTAssertTrue(output.contains("37 101"), output)
        let records = output.components(separatedBy: "STREAM:").dropFirst().map { String($0.prefix(5)) }
        XCTAssertEqual(records, (0..<4096).map { String(format: "%05d", $0) }, "SSH must preserve every record in byte order")
        let closing = ContinuousClock().now
        await transport.close()
        XCTAssertLessThan(closing.duration(to: ContinuousClock().now), .seconds(7), "Transport teardown must be bounded")
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(capture.eofStatus().0, 1)
        XCTAssertFalse(capture.eofStatus().1)
        XCTAssertEqual(capture.text(), output, "EOF must not overtake queued bytes")

        XCTAssertEqual(try knownHosts.identity(for: host, port: port), presented)
        let order = events.snapshot()
        XCTAssertLessThan(order.firstIndex(of: "host-key-confirmed")!, order.firstIndex(of: "credential-read")!)
        XCTAssertLessThan(order.firstIndex(of: "credential-read")!, order.firstIndex(of: "authentication-offered")!)
        XCTAssertEqual(order.filter { $0 == "authentication-offered" }.count, 1)

        let changedStore = InMemoryKnownHosts()
        try changedStore.trust(try HostIdentity(host: host, port: port, algorithm: "ssh-ed25519", blob: Data(repeating: 7, count: 51)))
        let changedEvents = EventRecorder()
        let changed = NIOSSHStreamingTransport(configuration: SSHTransportConfiguration(
            serverID: id, host: host, port: port, username: user, authentication: .ed25519,
            knownHosts: changedStore, secrets: secrets, confirmUnknownFingerprint: { _ in XCTFail("changed keys are not first use"); return false },
            lifecycleEvent: { changedEvents.append($0) }))
        do {
            try await changed.attach(command: "true", pty: TerminalSize(columns: 80, rows: 24)) { _ in }
            XCTFail("changed key must fail")
        } catch {
            XCTAssertEqual(error as? SSHTransportError, .changedHostKey)
        }
        await changed.close()
        XCTAssertFalse(changedEvents.snapshot().contains("credential-read"))
        XCTAssertFalse(changedEvents.snapshot().contains("authentication-offered"))

        let wrongID = UUID(), wrongSecrets = InMemorySecretStore(), wrongKnownHosts = InMemoryKnownHosts()
        try SSHKey().save(to: wrongSecrets, serverID: wrongID)
        try wrongKnownHosts.trust(presented)
        let wrong = NIOSSHStreamingTransport(configuration: SSHTransportConfiguration(
            serverID: wrongID, host: host, port: port, username: user, authentication: .ed25519,
            knownHosts: wrongKnownHosts, secrets: wrongSecrets, confirmUnknownFingerprint: { _ in
                XCTFail("the fixture identity is already trusted"); return false
            }))
        do {
            try await wrong.attach(command: "true", pty: TerminalSize(columns: 80, rows: 24)) { _ in }
            XCTFail("wrong authentication must fail")
        } catch {
            XCTAssertEqual(error as? SSHTransportError, .authenticationUnavailable)
        }
        await wrong.close()

        guard let noTTYPort = env["APP_SSH_NO_TTY_PORT"].flatMap(UInt16.init),
              let noTTYMarker = env["APP_SSH_NO_TTY_MARKER"] else {
            return XCTFail("the fixture must provide its PermitTTY rejection endpoint")
        }
        let noTTYIdentity = try HostIdentity(host: host, port: noTTYPort, algorithm: String(fields[0]),
                                             blob: Data(base64Encoded: String(fields[1]))!)
        let noTTYKnownHosts = InMemoryKnownHosts(); try noTTYKnownHosts.trust(noTTYIdentity)
        let noTTY = NIOSSHStreamingTransport(configuration: SSHTransportConfiguration(
            serverID: id, host: host, port: noTTYPort, username: user, authentication: .ed25519,
            knownHosts: noTTYKnownHosts, secrets: secrets, confirmUnknownFingerprint: { _ in
                XCTFail("the PermitTTY fixture identity is already trusted"); return false
            }))
        do {
            try await noTTY.attach(command: "touch '\(noTTYMarker)'", pty: TerminalSize(columns: 80, rows: 24)) { _ in }
            XCTFail("a rejected PTY must prevent exec")
        } catch {
            XCTAssertEqual(error as? SSHTransportError, .requestRejected)
        }
        await noTTY.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: noTTYMarker))
    }
}
