import Crypto
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHProofError: Error, Equatable {
    case unknownHostKey
    case changedHostKey
    case endpointMismatch
    case untrustedAddress
    case invalidPTY
    case outputLimitExceeded
    case inputLimitExceeded
    case timedOut
    case missingExitStatus
    case requestRejected
    case authenticationRejected
    case ptyRejected
    case cancelled
}

/// A known-host entry is inseparable from its configured endpoint and exact key algorithm/bytes.
public struct HostKeyIdentity: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let key: String

    public init(host: String, port: Int, openSSHKey: String) {
        self.host = host
        self.port = port
        self.key = openSSHKey.split(separator: " ").prefix(2).joined(separator: " ")
    }

    public var sha256Fingerprint: String {
        let encoded = key.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let bytes = Data(base64Encoded: encoded) ?? Data()
        return "SHA256:" + SHA256.hash(data: bytes).withUnsafeBytes {
            Data($0).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
    }
}

/// Generated keys use Crypto's Ed25519 implementation; callers persist the raw private bytes in Keychain, never source.
public struct Ed25519Credentials: Sendable {
    public let privateKeyBase64: String
    public let publicKey: String

    public init() {
        let key = Curve25519.Signing.PrivateKey()
        privateKeyBase64 = key.rawRepresentation.base64EncodedString()
        publicKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    init(privateKeyBase64: String) throws {
        let bytes = Data(base64Encoded: privateKeyBase64) ?? Data()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
        self.privateKeyBase64 = privateKeyBase64
        publicKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    var nioPrivateKey: NIOSSHPrivateKey {
        get throws {
            let bytes = Data(base64Encoded: privateKeyBase64) ?? Data()
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: bytes))
        }
    }
}

public struct SSHProofPTY: Sendable {
    public let term: String
    public let columns: UInt32
    public let rows: UInt32
    public init(term: String = "xterm-256color", columns: UInt32, rows: UInt32) throws {
        guard !term.isEmpty, term.utf8.count <= 64, columns > 0, rows > 0, columns <= 1_000, rows <= 1_000 else {
            throw SSHProofError.invalidPTY
        }
        self.term = term
        self.columns = columns
        self.rows = rows
    }
}

public final class TrustedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trustedKey: HostKeyIdentity?
    private let lock = NSLock()
    private var storedRejection: SSHProofError?
    var rejection: SSHProofError? { lock.lock(); defer { lock.unlock() }; return storedRejection }
    private var storedOnReject: (@Sendable (SSHProofError) -> Void)?
    var onReject: (@Sendable (SSHProofError) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnReject }
        set { lock.lock(); storedOnReject = newValue; lock.unlock() }
    }
    public init(identity: HostKeyIdentity?) { trustedKey = identity }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey).split(separator: " ").prefix(2).joined(separator: " ")
        let error: SSHProofError?
        if let trustedKey { error = presented == trustedKey.key ? nil : .changedHostKey }
        else { error = .unknownHostKey }
        guard let error else { validationCompletePromise.succeed(()); return }
        lock.lock(); storedRejection = error; lock.unlock()
        onReject?(error)
        validationCompletePromise.fail(error)
    }
}

private final class PublicKeyDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var offer: NIOSSHUserAuthenticationOffer?
    private let offered: () -> Void
    init(username: String, key: NIOSSHPrivateKey, offered: @escaping () -> Void = {}) {
        offer = .init(username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key)))
        self.offered = offered
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), let offer else {
            nextChallengePromise.fail(SSHProofError.authenticationRejected)
            return
        }
        self.offer = nil; offered()
        nextChallengePromise.succeed(offer)
    }
}

private final class PasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var offer: NIOSSHUserAuthenticationOffer?
    init(username: String, password: String) {
        offer = .init(username: username, serviceName: "ssh-connection", offer: .password(.init(password: password)))
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.password), let offer else {
            nextChallengePromise.fail(SSHProofError.authenticationRejected)
            return
        }
        self.offer = nil
        nextChallengePromise.succeed(offer)
    }
}

public enum SSHProofAuthentication: Sendable {
    case ed25519(privateKeyBase64: String)
    case password(String)
}

/// A deliberately small buffered command proof, not the application's streaming terminal transport.
/// It resolves and filters before TCP, validates host identity before auth, and bounds its lifecycle.
public final class SSHProofClient: @unchecked Sendable {
    public let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let resolverPool = NIOThreadPool(numberOfThreads: 1)
    private let addressPolicy: AddressPolicy
    private let resolver: @Sendable (String, Int, AddressPolicy) throws -> [SocketAddress]
    private let authOfferLock = NSLock()
    internal private(set) var authenticationOfferCount = 0
    public convenience init() { self.init(addressPolicy: .production) }

    // This is intentionally internal: only @testable fixture code may permit loopback or inject a bounded resolver.
    init(addressPolicy: AddressPolicy,
         resolver: @escaping @Sendable (String, Int, AddressPolicy) throws -> [SocketAddress] = resolvedTrustedAddresses) {
        self.addressPolicy = addressPolicy; self.resolver = resolver; resolverPool.start()
    }

    /// Cancellation may be called from any thread. The registered action always hops to the connection event loop.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        private var actionID: UUID?
        private var requested = false
        public init() {}
        public func cancel() { lock.lock(); requested = true; let action = action; lock.unlock(); action?() }
        fileprivate func install(id: UUID, _ action: @escaping @Sendable () -> Void) {
            lock.lock(); self.actionID = id; self.action = action; let requested = self.requested; lock.unlock()
            if requested { action() }
        }
        fileprivate func uninstall(id: UUID) {
            lock.lock(); defer { lock.unlock() }
            if actionID == id { action = nil; actionID = nil }
        }
    }
    deinit {
        // The final reference can be released by an event-loop callback. Blocking shutdown there deadlocks.
        resolverPool.shutdownGracefully { _ in }
        group.shutdownGracefully { _ in }
    }

    fileprivate func offeredAuthentication() -> Bool {
        authOfferLock.lock(); defer { authOfferLock.unlock() }; return authenticationOfferCount > 0
    }

    fileprivate func recordAuthenticationOffer() {
        authOfferLock.lock(); authenticationOfferCount += 1; authOfferLock.unlock()
    }

    public func exec(host: String, port: Int, username: String, authentication: SSHProofAuthentication,
                     trustedHost: HostKeyIdentity?, command: String, pty: SSHProofPTY? = nil,
                     input: Data = Data(), resize: (columns: UInt32, rows: UInt32)? = nil,
                     outputLimit: Int = 1 << 20, timeout: TimeAmount = .seconds(10),
                     cancellation: Cancellation? = nil) throws -> (output: Data, exitStatus: Int) {
        if let trustedHost { guard trustedHost.host == host, trustedHost.port == port else { throw SSHProofError.endpointMismatch } }
        guard outputLimit > 0, outputLimit <= 1 << 20, input.count <= 64 * 1024 else {
            throw outputLimit > 0 ? SSHProofError.inputLimitExceeded : SSHProofError.outputLimitExceeded
        }
        if let resize {
            _ = try SSHProofPTY(columns: resize.columns, rows: resize.rows)
            guard pty != nil else { throw SSHProofError.invalidPTY }
        }
        let loop = group.next()
        let access = ProofCallbackAccess(eventLoop: loop)
        let execution = try loop.submit {
            NIOLoopBound(try ProofExecution(loop: loop, group: self.group, access: access, username: username,
                authentication: authentication, trustedHost: trustedHost, command: command, pty: pty, input: input,
                resize: resize, outputLimit: outputLimit,
                offered: { [weak self] in self?.recordAuthenticationOffer() },
                didOffer: { [weak self] in self?.offeredAuthentication() ?? false }), eventLoop: loop)
        }.wait()
        let completion = try loop.submit { execution.value.promise.futureResult }.wait()
        let cancellationID = UUID()
        cancellation?.install(id: cancellationID) {
            access.enqueue { execution.value.complete(.failure(SSHProofError.cancelled)) }
        }
        defer {
            cancellation?.uninstall(id: cancellationID)
            access.retire()
            // The client still owns its live loop here. Fetch state on that loop, then wait off-loop as before.
            if let close = try? loop.submit({ execution.value.connectionCloseFuture }).wait() { try? close.wait() }
        }
        let resolver = self.resolver, policy = addressPolicy, pool = resolverPool
        access.enqueue {
            let owner = execution.value
            guard !owner.terminal else { return }
            owner.deadline = loop.scheduleTask(in: timeout) { execution.value.complete(.failure(SSHProofError.timedOut)) }
            owner.hostDelegate.onReject = { error in
                access.enqueue { execution.value.complete(.failure(error)) }
            }
            // No unguarded NIO future is completed by a DNS worker after this execution retires.
            pool.submit { state in
                let result: Result<[SocketAddress], Error>
                if case .active = state { result = Result { try resolver(host, port, policy) } }
                else { result = .failure(SSHProofError.cancelled) }
                access.enqueue { execution.value.resolved(result, execution: execution) }
            }
        }
        return try completion.wait()
    }
}

// Only the admission flag crosses threads; execution state itself remains bound to one NIO loop.
private final class ProofCallbackAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let eventLoop: EventLoop
    init(eventLoop: EventLoop) { self.eventLoop = eventLoop }
    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        guard active else { lock.unlock(); return }
        eventLoop.execute { self.lock.lock(); self.lock.unlock(); operation() }
        lock.unlock()
    }
    func retire() { lock.lock(); active = false; lock.unlock() }
}

/// All methods/state are confined to `loop`; callbacks carry only NIOLoopBound<ProofExecution>.
private final class ProofExecution {
    let loop: EventLoop
    let group: MultiThreadedEventLoopGroup
    let access: ProofCallbackAccess
    let promise: EventLoopPromise<(Data, Int)>
    let hostDelegate: TrustedHostKeyDelegate
    let authDelegate: NIOSSHClientUserAuthenticationDelegate
    let command: String, pty: SSHProofPTY?, input: Data, resize: (columns: UInt32, rows: UInt32)?, outputLimit: Int
    let didOffer: @Sendable () -> Bool
    private(set) var terminal = false
    private var activeConnection: Channel?
    private(set) var connectionCloseFuture: EventLoopFuture<Void>?
    var deadline: Scheduled<Void>?

    init(loop: EventLoop, group: MultiThreadedEventLoopGroup, access: ProofCallbackAccess, username: String,
         authentication: SSHProofAuthentication, trustedHost: HostKeyIdentity?, command: String, pty: SSHProofPTY?,
         input: Data, resize: (columns: UInt32, rows: UInt32)?, outputLimit: Int,
         offered: @escaping @Sendable () -> Void, didOffer: @escaping @Sendable () -> Bool) throws {
        loop.preconditionInEventLoop()
        switch authentication {
        case .ed25519(let raw):
            authDelegate = PublicKeyDelegate(username: username, key: try Ed25519Credentials(privateKeyBase64: raw).nioPrivateKey, offered: offered)
        case .password(let password): authDelegate = PasswordDelegate(username: username, password: password)
        }
        self.loop = loop; self.group = group; self.access = access; self.didOffer = didOffer
        self.command = command; self.pty = pty; self.input = input; self.resize = resize; self.outputLimit = outputLimit
        hostDelegate = TrustedHostKeyDelegate(identity: trustedHost)
        promise = loop.makePromise(of: (Data, Int).self)
    }
    func complete(_ result: Result<(Data, Int), Error>) {
        loop.preconditionInEventLoop()
        guard !terminal else { return }
        terminal = true
        access.retire()
        deadline?.cancel(); deadline = nil
        let closing = activeConnection; activeConnection = nil
        closing?.close(promise: nil)
        promise.completeWith(result)
    }
    func resolved(_ result: Result<[SocketAddress], Error>, execution: NIOLoopBound<ProofExecution>) {
        loop.preconditionInEventLoop()
        guard !terminal else { return }
        switch result {
        case .failure(let error): complete(.failure(error))
        case .success(let addresses):
            guard let address = addresses.first else { complete(.failure(SSHProofError.untrustedAddress)); return }
            // Bootstrap and non-Sendable delegates/handlers are constructed and accessed on this loop only.
            let bootstrap = ClientBootstrap(group: group).channelInitializer { channel in
                let owner = execution.value
                guard !owner.terminal else { return channel.eventLoop.makeFailedFuture(SSHProofError.cancelled) }
                do {
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: .client(.init(userAuthDelegate: owner.authDelegate, serverAuthDelegate: owner.hostDelegate)),
                                      allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        ParentErrorHandler { execution.value.complete(.failure($0)) })
                    return channel.eventLoop.makeSucceededFuture(())
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
            bootstrap.connect(to: address).whenComplete { execution.value.connected($0, execution: execution) }
        }
    }
    func connected(_ result: Result<Channel, Error>, execution: NIOLoopBound<ProofExecution>) {
        loop.preconditionInEventLoop()
        guard !terminal else { if case .success(let channel) = result { channel.close(promise: nil) }; return }
        switch result {
        case .failure(let error): complete(.failure(error))
        case .success(let connection):
            activeConnection = connection; connectionCloseFuture = connection.closeFuture
            connection.closeFuture.whenComplete { _ in
                let owner = execution.value
                owner.complete(.failure(owner.hostDelegate.rejection ?? (owner.didOffer() ? SSHProofError.authenticationRejected : SSHProofError.requestRejected)))
            }
            do {
                let handler = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let child = loop.makePromise(of: Channel.self)
                handler.createChannel(child) { channel, type in
                    let owner = execution.value
                    guard !owner.terminal, type == .session else { return channel.eventLoop.makeFailedFuture(SSHProofError.requestRejected) }
                    return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        let owner = execution.value
                        do {
                            try channel.pipeline.syncOperations.addHandler(SessionHandler(command: owner.command, pty: owner.pty,
                                input: owner.input, resize: owner.resize, outputLimit: owner.outputLimit,
                                completion: { execution.value.complete($0) }))
                            return channel.eventLoop.makeSucceededFuture(())
                        } catch { return channel.eventLoop.makeFailedFuture(error) }
                    }
                }
                child.futureResult.whenFailure { execution.value.complete(.failure($0)) }
            } catch { complete(.failure(error)) }
        }
    }
}

private final class ParentErrorHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let report: (Error) -> Void
    init(report: @escaping (Error) -> Void) { self.report = report }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        report(error)
        context.close(promise: nil)
    }
}

internal struct ProofCompletionState {
    private(set) var exitStatus: Int?
    private(set) var inputClosed = false
    private(set) var finished = false
    mutating func receivedExitStatus(_ status: Int) -> Int? { exitStatus = status; return takeIfComplete() }
    mutating func receivedInputClosed() -> Int? { inputClosed = true; return takeIfComplete() }
    mutating func failOnce() -> Bool { guard !finished else { return false }; finished = true; return true }
    private mutating func takeIfComplete() -> Int? {
        guard !finished, inputClosed, let exitStatus else { return nil }
        finished = true; return exitStatus
    }
}

private final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    let command: String
    let pty: SSHProofPTY?
    let input: Data
    let resize: (columns: UInt32, rows: UInt32)?
    let outputLimit: Int
    let complete: (Result<(Data, Int), Error>) -> Void
    var output = Data()
    var completionState = ProofCompletionState()
    private enum RequestPhase { case waitingForPTY, waitingForExec, running }
    private var requestPhase: RequestPhase?

    init(command: String, pty: SSHProofPTY?, input: Data, resize: (columns: UInt32, rows: UInt32)?, outputLimit: Int,
         completion: @escaping (Result<(Data, Int), Error>) -> Void) {
        self.command = command; self.pty = pty; self.input = input; self.resize = resize
        self.outputLimit = outputLimit; self.complete = completion
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if let pty {
            requestPhase = .waitingForPTY
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: pty.term,
                terminalCharacterWidth: Int(pty.columns), terminalRowHeight: Int(pty.rows),
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop), boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.triggerUserOutboundEvent(request).whenFailure { handler.value.fail($0, context: boundContext.value) }
        } else {
            startExec(context: context)
        }
    }

    private func startExec(context: ChannelHandlerContext) {
        requestPhase = .waitingForExec
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop), boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
            .whenFailure { handler.value.fail($0, context: boundContext.value) }
    }

    private func startInput(context: ChannelHandlerContext) {
        requestPhase = .running
        let resized: EventLoopFuture<Void>
        if let resize {
            resized = context.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: Int(resize.columns), terminalRowHeight: Int(resize.rows),
                terminalPixelWidth: 0, terminalPixelHeight: 0))
        } else {
            resized = context.eventLoop.makeSucceededFuture(())
        }
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop), boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        resized.flatMap {
            let owner = handler.value, context = boundContext.value
            guard !owner.input.isEmpty else { return context.eventLoop.makeSucceededFuture(()) }
            var buffer = context.channel.allocator.buffer(capacity: owner.input.count)
            buffer.writeBytes(owner.input)
            return context.writeAndFlush(owner.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))))
        }.flatMap {
            // Buffered proof commands always finish stdin. The streaming app deliberately does not.
            boundContext.value.channel.close(mode: .output)
        }.whenFailure { handler.value.fail($0, context: boundContext.value) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = message.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        guard output.count <= outputLimit - bytes.count else {
            fail(SSHProofError.outputLimitExceeded, context: context)
            return
        }
        output.append(contentsOf: bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            switch requestPhase {
            case .waitingForPTY: startExec(context: context)
            case .waitingForExec: startInput(context: context)
            case .running, .none: break
            }
            return
        }
        if event is ChannelFailureEvent {
            switch requestPhase {
            case .waitingForPTY: fail(SSHProofError.ptyRejected, context: context)
            case .waitingForExec: fail(SSHProofError.requestRejected, context: context)
            case .running, .none: fail(SSHProofError.requestRejected, context: context)
            }
            return
        }
        if let status = event as? SSHChannelRequestEvent.ExitStatus,
           let completed = completionState.receivedExitStatus(status.exitStatus) { finish(status: completed, context: context) }
        if event is ChannelEvent, case ChannelEvent.inputClosed = event {
            if let completed = completionState.receivedInputClosed() { finish(status: completed, context: context) }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error, context: context) }
    func channelInactive(context: ChannelHandlerContext) { if !completionState.finished { fail(SSHProofError.missingExitStatus, context: context) } }

    private func finish(status: Int, context: ChannelHandlerContext) {
        complete(.success((output, status)))
        context.close(promise: nil)
    }
    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard completionState.failOnce() else { return }
        complete(.failure(error))
        context.close(promise: nil)
    }
}

internal enum AddressPolicy: Sendable { case production, loopbackFixture }

private func resolvedTrustedAddresses(host: String, port: Int, policy: AddressPolicy) throws -> [SocketAddress] {
    var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                         ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { throw SSHProofError.untrustedAddress }
    defer { freeaddrinfo(first) }
    var output: [SocketAddress] = [], cursor: UnsafeMutablePointer<addrinfo>? = first
    while let entry = cursor?.pointee {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(entry.ai_addr, entry.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let ip = String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if trustedPrivateAddress(ip, policy: policy), let address = try? SocketAddress(ipAddress: ip, port: port), !output.contains(address) {
                output.append(address)
            }
        }
        cursor = entry.ai_next
    }
    guard !output.isEmpty else { throw SSHProofError.untrustedAddress }
    return output
}

internal func trustedPrivateAddress(_ ip: String, policy: AddressPolicy = .production) -> Bool {
    var v4 = in_addr()
    if inet_pton(AF_INET, ip, &v4) == 1 {
        let bytes = withUnsafeBytes(of: &v4) { Array($0.prefix(4)) }
        if bytes[0] == 127 { return policy == .loopbackFixture && bytes == [127, 0, 0, 1] }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, ip, &v6) == 1 else { return false }
    let bytes = withUnsafeBytes(of: &v6) { Array($0.prefix(16)) }
    if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return policy == .loopbackFixture }
    if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff { return false }
    return bytes[0] & 0xfe == 0xfc
}
