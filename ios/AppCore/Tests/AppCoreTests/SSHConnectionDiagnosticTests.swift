import AppCore
import Foundation
import NIOCore
import NIOPosix
import Testing
import SecurityCore

@Test func sshConnectionDiagnosticKeepsErrnoAndAddressWithoutIOReason() throws {
    let secret = "PRIVATE_SENTINEL_DO_NOT_SERIALIZE"
    let error = IOError(errnoCode: 61, reason: secret)
    let address = try SocketAddress(ipAddress: "127.0.0.1", port: 22)
    let value = SSHConnectionDiagnostic.capture(error, address: address)
    #expect(value.category == "posixIOError")
    #expect(value.posixErrno == 61)
    #expect(value.addressFamily == "ipv4")
    #expect(value.address == "127.0.0.1")
    #expect(value.port == 22)
    #expect(value.underlying.isEmpty)
    let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    #expect(!json.contains(secret))
}

@Test func sshConnectionDiagnosticKeepsSafeNSErrorDomainAndCodeOnly() throws {
    let secret = "PRIVATE_SENTINEL_DO_NOT_SERIALIZE"
    let error = NSError(domain: NSPOSIXErrorDomain, code: 65,
                        userInfo: [NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: NSError(domain: secret, code: 7)])
    let value = SSHConnectionDiagnostic.capture(error)
    #expect(value.category == "nsError")
    #expect(value.nsErrorDomain == NSPOSIXErrorDomain)
    #expect(value.nsErrorCode == 65)
    #expect(value.posixErrno == 65)
    #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains(secret))
    let unknown = SSHConnectionDiagnostic.capture(NSError(domain: secret, code: 7))
    #expect(unknown.nsErrorDomain == "other")
    #expect(!String(decoding: try JSONEncoder().encode(unknown), as: UTF8.self).contains(secret))
}

@Test func sshConnectionDiagnosticUsesStableChannelTimeoutCategory() {
    let value = SSHConnectionDiagnostic.capture(ChannelError.connectTimeout(.seconds(8)))
    #expect(value.category == "tcpConnectTimeout")
    #expect(value.posixErrno == nil)
    #expect(value.underlyingCount == 0)
}

@Test func sshConnectionDiagnosticBoundsRealNIOConnectionFailureMetadata() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        // Port zero cannot host an SSH listener. Only local loopback is attempted.
        let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(1))
            .connect(host: "127.0.0.1", port: 0).get()
        try await channel.close().get()
        Issue.record("Unexpected loopback port-zero connection success")
    } catch {
        let value = SSHConnectionDiagnostic.capture(error)
        #expect(value.category == "nioConnectionError")
        #expect(value.underlyingCount >= 1)
        #expect(value.underlying.count <= 8)
        #expect(value.underlying.contains { $0.posixErrno != nil && $0.address == "127.0.0.1" && $0.port == 0 })
    }
    try await group.shutdownGracefully()
}

@Test func sshConnectionDiagnosticCategorizesKeychainWithoutCredentialData() {
    let value = SSHConnectionDiagnostic.capture(KeychainError.failure(OSStatusCode(-25308)))
    #expect(value.category == "keychainOSStatus")
    #expect(value.nsErrorDomain == NSOSStatusErrorDomain)
    #expect(value.nsErrorCode == -25308)
    #expect(SSHConnectionDiagnostic.capture(KeychainError.accessDenied).category == "keychainAccessDenied")
}
