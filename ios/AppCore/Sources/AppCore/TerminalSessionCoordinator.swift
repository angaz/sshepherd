import AppUI
import Foundation

public enum TerminalTransportError: Error, Equatable, Sendable { case disconnected, inputTooLarge, closed }

/// The SSH adapter owns a fresh channel for every attachment. It must never replay accepted input.
public protocol SSHStreamingTransport: Sendable {
    func attach(command: String, pty: TerminalSize, receive: @escaping @Sendable (Data) async -> Void) async throws
    func send(_ bytes: Data) async throws
    func resize(_ size: TerminalSize) async throws
    func close() async
}

public struct TerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cellWidth: UInt32
    public let cellHeight: UInt32
    public var pixelWidth: Int { columns * Int(cellWidth) }
    public var pixelHeight: Int { rows * Int(cellHeight) }
    public init(columns: Int, rows: Int, cellWidth: UInt32 = 8, cellHeight: UInt32 = 16) {
        self.columns = max(1, min(columns, 1_000))
        self.rows = max(1, min(rows, 1_000))
        self.cellWidth = max(1, min(cellWidth, 1_000))
        self.cellHeight = max(1, min(cellHeight, 1_000))
    }
}

/// Native C-ABI bridge implementation is supplied by the reviewed Apple artifact. No Swift ANSI fallback exists.
public protocol NativeTerminalEngine: Sendable {
    func write(_ bytes: Data) async throws
    func resize(_ size: TerminalSize) async throws
    func frame() async throws -> Data
    func replies() async throws -> Data
    func key(_ event: TerminalKeyEvent) async throws -> Data
    func mouse(_ event: TerminalMouseEvent) async throws -> Data
    func close() async
}

public enum NativeEngineError: Error, Equatable, Sendable {
    case unavailable
    case closed
    case invalidBuffer
    case operationFailed(Int32)
}

/// Explicit production failure until the reviewed C ABI and matching library slices are linked.
public struct UnavailableNativeTerminalEngine: NativeTerminalEngine {
    public init() {}
    public func write(_ bytes: Data) async throws { throw NativeEngineError.unavailable }
    public func resize(_ size: TerminalSize) async throws { throw NativeEngineError.unavailable }
    public func frame() async throws -> Data { throw NativeEngineError.unavailable }
    public func replies() async throws -> Data { throw NativeEngineError.unavailable }
    public func key(_ event: TerminalKeyEvent) async throws -> Data { throw NativeEngineError.unavailable }
    public func mouse(_ event: TerminalMouseEvent) async throws -> Data { throw NativeEngineError.unavailable }
    public func close() async {}
}

private final class ConnectionStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConnectionState = .disconnected
    func get() -> ConnectionState { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: ConnectionState) { lock.lock(); value = next; lock.unlock() }
}

/// Serialized non-main-actor terminal lifecycle with generation guards and bounded reconnect attempts.
public actor TerminalSessionCoordinator: TerminalSession, TerminalFrameProvider {
    private let transportFactory: @Sendable () -> any SSHStreamingTransport
    private let engine: any NativeTerminalEngine
    private let command: String
    private var transport: (any SSHStreamingTransport)?
    private var currentSize = TerminalSize(columns: 80, rows: 24)
    private var generation = 0
    private var connectionState: ConnectionState = .disconnected
    private var reconnectAttempts = 0
    private var connectedAt: ContinuousClock.Instant?
    private var pendingReplies = Data()
    private var isClosed = false
    private var herdrStream = HerdrBridgeStream()
    private var herdrStore = HerdrCatalogStore()
    private var herdrResults: [String: HerdrBridgeMessage] = [:]
    private nonisolated let stateBox = ConnectionStateBox()
    public nonisolated var state: ConnectionState { stateBox.get() }

    private func setState(_ state: ConnectionState) {
        connectionState = state
        stateBox.set(state)
    }

    public init(command: String = "herdr --session default", transportFactory: @escaping @Sendable () -> any SSHStreamingTransport, engine: any NativeTerminalEngine) {
        self.command = command; self.transportFactory = transportFactory; self.engine = engine
    }

    public func connect() async throws {
        guard connectionState != .connected && connectionState != .connecting else { return }
        reconnectAttempts = 0
        try await attach()
    }

    private func attach() async throws {
        guard !isClosed else { throw TerminalTransportError.closed }
        guard connectionState != .connected && connectionState != .connecting else { return }
        setState(.connecting)
        generation += 1
        let expected = generation
        let next = transportFactory()
        transport = next
        pendingReplies.removeAll(keepingCapacity: true)
        resetHerdrBrowser()
        let attachedSize = currentSize
        do {
            try await next.attach(command: command, pty: attachedSize) { [weak self] bytes in
                await self?.received(bytes, generation: expected)
            }
            guard expected == generation else { await next.close(); return }
            var remoteSize = attachedSize
            while remoteSize != currentSize {
                let latest = currentSize
                try await next.resize(latest)
                guard expected == generation else { await next.close(); return }
                remoteSize = latest
            }
            setState(.connected)
            connectedAt = ContinuousClock().now
            let replies = pendingReplies; pendingReplies.removeAll(keepingCapacity: true)
            if !replies.isEmpty { await send(replies) }
        } catch {
            if expected == generation { transport = nil; setState(failureState(error)) }
            await next.close()
            throw error
        }
    }

    public func detach() async {
        generation += 1; setState(.suspended)
        let expected = generation
        let old = transport; transport = nil
        pendingReplies.removeAll(keepingCapacity: true)
        resetHerdrBrowser()
        await old?.close()
        if expected == generation { setState(.disconnected) }
    }

    /// Permanently releases both the SSH attachment and native handle when a terminal screen is dismissed.
    public func shutdown() async {
        isClosed = true
        await detach()
        await engine.close()
    }

    public func send(_ bytes: Data) async {
        guard bytes.count <= 60_000, connectionState == .connected, let transport else { return }
        let expected = generation
        do { try await transport.send(bytes) }
        catch { if expected == generation { await disconnected() } }
    }
    public func sendKey(_ event: TerminalKeyEvent) async {
        guard connectionState == .connected else { return }
        let expected = generation
        if let bytes = try? await engine.key(event), expected == generation, !bytes.isEmpty { await send(bytes) }
    }
    public func sendMouse(_ event: TerminalMouseEvent) async {
        guard connectionState == .connected else { return }
        let expected = generation
        if let bytes = try? await engine.mouse(event), expected == generation, !bytes.isEmpty { await send(bytes) }
    }
    public func resize(columns: Int, rows: Int) async {
        let next = TerminalSize(columns: columns, rows: rows)
        guard next != currentSize else { return }
        currentSize = next
        let expected = generation
        try? await engine.resize(next)
        guard expected == generation, currentSize == next else { return }
        if connectionState == .connected, let transport {
            do { try await transport.resize(next) }
            catch { if expected == generation { await disconnected() } }
        }
    }
    public func frameSnapshot() async throws -> Data { try await engine.frame() }

    public func herdrCatalog() -> HerdrCatalog? { herdrStore.catalog }
    public func herdrCatalogContext() -> (generation: Int, catalog: HerdrCatalog?) { (generation, herdrStore.catalog) }

    public func selectHerdrWorkspace(_ id: String) async throws {
        guard herdrStore.catalog?.workspaces.contains(where: { $0.id == id }) == true else { throw HerdrBrowserError.expired }
        try await selectHerdr(kind: "workspace", target: id)
    }

    public func selectHerdrAgent(_ paneID: String) async throws {
        guard herdrStore.catalog?.agents.contains(where: { $0.id == paneID }) == true else { throw HerdrBrowserError.expired }
        try await selectHerdr(kind: "pane", target: paneID)
    }

    public func restoreHerdrView(_ view: RememberedHerdrView) async throws {
        guard let catalog = herdrStore.catalog, let target = view.target(in: catalog) else { throw HerdrBrowserError.expired }
        switch target {
        case .pane(let id): try await selectHerdr(kind: "pane", target: id)
        case .workspace(let id): try await selectHerdr(kind: "workspace", target: id)
        }
    }

    private func selectHerdr(kind: String, target: String) async throws {
        guard connectionState == .connected else { throw HerdrBrowserError.disconnected }
        guard let catalog = herdrStore.catalog else { throw HerdrBrowserError.unavailable }
        let expected = generation
        let id = UUID().uuidString
        let bytes = try HerdrBridgeStream.focus(id: id, bootID: catalog.bootID, kind: kind, target: target)
        await send(bytes)
        defer { herdrResults.removeValue(forKey: id) }
        for _ in 0..<100 {
            guard expected == generation, connectionState == .connected else { throw HerdrBrowserError.disconnected }
            guard herdrStore.catalog?.bootID == catalog.bootID else { throw HerdrBrowserError.expired }
            if let result = herdrResults.removeValue(forKey: id) {
                if let error = result.error { throw HerdrBrowserError.refused(error) }
                return
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw HerdrBrowserError.timedOut
    }

    private func resetHerdrBrowser() {
        herdrStream = HerdrBridgeStream()
        herdrStore.reset()
        herdrResults.removeAll()
    }

    private func received(_ bytes: Data, generation expected: Int) async {
        guard expected == generation, connectionState == .connected || connectionState == .connecting else { return }
        guard !bytes.isEmpty else {
            if connectionState == .connecting {
                generation += 1
                let old = transport; transport = nil
                setState(.failed("SSH session ended during setup"))
                await old?.close()
            } else { await disconnected() }
            return
        }
        guard bytes.count <= 1 << 20 else { await disconnected(); return }
        do {
            let (terminal, messages) = try herdrStream.feed(bytes)
            for message in messages {
                if message.type == "catalog", let catalog = message.catalog { herdrStore.accept(catalog) }
                else if message.type == "result", let id = message.id {
                    if herdrResults.count >= 32 { herdrResults.removeAll() }
                    herdrResults[id] = message
                }
            }
            if !terminal.isEmpty { try await engine.write(terminal) }
            guard expected == generation else { return }
            let replies = try await engine.replies()
            guard expected == generation else { return }
            if connectionState == .connecting {
                guard pendingReplies.count + replies.count <= 60_000 else { await disconnected(); return }
                pendingReplies.append(replies)
            } else if !replies.isEmpty { await send(replies) }
        } catch { if expected == generation { await disconnected() } }
    }
    private func disconnected() async {
        guard !isClosed, connectionState != .disconnected, connectionState != .suspended else { return }
        if let connectedAt, connectedAt.duration(to: ContinuousClock().now) >= .seconds(30) { reconnectAttempts = 0 }
        connectedAt = nil
        generation += 1
        let expected = generation
        let old = transport
        transport = nil; setState(.suspended); reconnectAttempts += 1
        resetHerdrBrowser()
        await old?.close()
        guard expected == generation, !isClosed else { return }
        guard reconnectAttempts <= 3 else { setState(.failed("SSH connection lost; reconnect manually")); return }
        do { try await Task.sleep(for: .seconds(reconnectAttempts)) } catch { return }
        guard expected == generation, connectionState == .suspended, !isClosed else { return }
        do { try await attach() }
        catch {
            guard generation == expected + 1 else { return }
            if let policy = error as? SSHTransportError,
               policy == .changedHostKey || policy == .unknownHostRejected || policy == .authenticationUnavailable || policy == .requestRejected { return }
            await disconnected()
        }
    }

    private func failureState(_ error: Error) -> ConnectionState {
        switch error as? SSHTransportError {
        case .changedHostKey?: return .failed("Server fingerprint changed; connection refused")
        case .unknownHostRejected?: return .failed("Server fingerprint was not approved")
        case .authenticationUnavailable?: return .failed("SSH authentication rejected; check credential enrollment")
        case .requestRejected?: return .failed("Server refused the terminal or Herdr command")
        default: return .failed("SSH connection failed; check network and server settings")
        }
    }
}
