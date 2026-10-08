import AppCore
import AppUI
import SecurityCore
import SwiftUI
import UIKit

@main
struct SSHepherdApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment = AppEnvironment.make()
    @State private var selectedHost: Host?
    @State private var attemptedStartupResume = false

    var body: some Scene {
        WindowGroup {
            Group {
                switch environment {
                case .success(let values):
                    Group {
                        if let host = selectedHost {
                            ConnectionView(host: host, environment: values) { selectedHost = nil }
                        } else {
                            InventoryView(model: values.inventory) { host in
                                try? values.navigation.selectServer(host.id)
                                selectedHost = host
                            }
                        }
                    }
                    .task {
                        guard !attemptedStartupResume else { return }
                        attemptedStartupResume = true
                        #if DEBUG
                        if let proof = values.phoneProof { selectedHost = proof.host; return }
                        if CommandLine.arguments.contains("--show-servers") || CommandLine.arguments.contains("--prepare-public-key") { return }
                        #endif
                        await values.inventory.load()
                        guard selectedHost == nil,
                              let id = values.navigation.startupServerID(available: values.inventory.hosts.map(\.id)),
                              let host = values.inventory.hosts.first(where: { $0.id == id }) else { return }
                        try? values.navigation.selectServer(id)
                        selectedHost = host
                    }
                case .failure:
                    ContentUnavailableView("Storage unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text("SSHepherd could not open its protected application data."))
                }
            }
        }
    }
}

@MainActor
private final class AppValues {
    let inventory: InventoryModel
    let secrets: KeychainSecretStore
    let knownHosts: PersistentKnownHostStore
    let navigation: RememberedConnectionStore
    let fingerprints = FingerprintConsent()
    #if DEBUG
    var phoneProof: PhoneProof?
    #endif

    init() throws {
        let inventoryStore = try AppSupportAtomicDataStore(filename: "servers.json")
        let knownHostStore = try AppSupportAtomicDataStore(filename: "known-hosts.json")
        let serverInventory = ServerInventory(storage: inventoryStore)
        inventory = InventoryModel(store: PersistentHostStore(inventory: serverInventory))
        secrets = KeychainSecretStore(service: "io.angaz.sshepherd.ios.ssh")
        knownHosts = try PersistentKnownHostStore(storage: knownHostStore)
        navigation = try RememberedConnectionStore(storage: AppSupportAtomicDataStore(filename: "navigation.json", maximumSize: 64 * 1024))

        #if DEBUG
        let launch = CommandLine.arguments
        if launch.contains("--export-public-key") {
            let id = try PhoneProof.argument("--export-public-key", in: launch)
            guard let uuid = UUID(uuidString: id),
                  let server = try serverInventory.load().first(where: { $0.id == uuid && $0.authentication == .ed25519 }),
                  try SSHCredentialSetup.isReady(for: Host(id: server.id, name: server.name, address: server.hostname, port: server.port, username: server.username), secrets: secrets) else { throw InventoryError.invalidField }
            let key = try SSHCredentialSetup.preparePublicKey(serverID: uuid, secrets: secrets)
            try AppSupportAtomicDataStore(filename: "device-public-key-\(uuid.uuidString).pub", maximumSize: 4096)
                .replace(with: Data((key + "\n").utf8))
        }
        if launch.contains("--phone-proof") {
            phoneProof = try PhoneProof(arguments: launch, hosts: serverInventory.load().map { Host(id: $0.id, name: $0.name, address: $0.hostname, port: $0.port, username: $0.username, authentication: $0.authentication == .ed25519 ? .ed25519 : .password) }, knownHosts: knownHosts)
        } else if launch.contains("--own-session") || launch.contains("--expected-host-fingerprint") {
            throw InventoryError.invalidField
        }
        #endif

        #if DEBUG && targetEnvironment(simulator)
        // Explicit simulator-only provisioning: private bytes never leave the app's Keychain.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--prepare-public-key") {
            guard arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]),
                  try serverInventory.load().contains(where: { $0.id == id && $0.authentication == .ed25519 }) else {
                throw InventoryError.invalidField
            }
            let publicKey = try SSHCredentialSetup.preparePublicKey(serverID: id, secrets: secrets)
            let export = try AppSupportAtomicDataStore(filename: "simulator-public-key-\(id.uuidString).pub", maximumSize: 4096)
            try export.replace(with: Data((publicKey + "\n").utf8))
        }
        #endif
    }
}

private enum AppEnvironment {
    case success(AppValues)
    case failure
    @MainActor static func make() -> AppEnvironment { (try? AppValues()).map(Self.success) ?? .failure }
}

@MainActor
private final class FingerprintConsent: ObservableObject, @unchecked Sendable {
    @Published var identity: HostIdentity?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var requestID: UUID?
    private var approvalTimeout: Task<Void, Never>?

    func request(_ identity: HostIdentity) async -> Bool {
        guard !Task.isCancelled, continuation == nil else { return false }
        let id = UUID()
        requestID = id
        self.identity = identity
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation = $0
                approvalTimeout = Task {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self.answer(false)
                }
                if Task.isCancelled { answer(false) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == id else { return }
                self?.answer(false)
            }
        }
    }
    func answer(_ accepted: Bool) {
        approvalTimeout?.cancel(); approvalTimeout = nil
        let pending = continuation; continuation = nil
        requestID = nil
        identity = nil
        pending?.resume(returning: accepted)
    }
}

private struct ConnectionView: View {
    let host: Host
    let environment: AppValues
    let onBack: () -> Void
    @ObservedObject private var fingerprints: FingerprintConsent
    @State private var password = ""
    @State private var publicKey: String?
    @State private var controller: TerminalController?
    @State private var error: String?
    @State private var checkingCredentials = true
    @State private var checkedCredentials = false
    @State private var managingSignIn = false

    init(host: Host, environment: AppValues, onBack: @escaping () -> Void) {
        self.host = host
        self.environment = environment
        self.onBack = onBack
        self.fingerprints = environment.fingerprints
    }

    var body: some View {
        NavigationStack {
            Group {
                if let controller {
                    TerminalScreen(controller: controller, hostName: host.name, onBack: onBack) {
                        if host.authentication == .ed25519 { generateKey() }
                        managingSignIn = true
                    }
                } else if checkingCredentials {
                    ProgressView("Preparing connection…")
                } else {
                    Form {
                        Section("Set up sign-in") {
                            LabeledContent("Endpoint", value: "\(host.username)@\(host.address):\(host.port)")
                            LabeledContent("Authentication", value: host.authentication == .password ? "Password" : "Ed25519")
                            Text("This server needs a saved credential. After setup, tapping its card connects directly.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if host.authentication == .password {
                            Section("Credential") {
                                SecureField("Password", text: $password)
                                    .textContentType(.password)
                                Text("The password is saved only in this device's Keychain after you tap Connect.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Section("Public key") {
                                if let publicKey {
                                    Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                                    ShareLink(item: publicKey) { Label("Export approved public key", systemImage: "square.and.arrow.up") }
                                } else {
                                    Button("Generate device-only key") { generateKey() }
                                }
                                Text("Enroll only the displayed public key through your existing trusted server process.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        Button("Connect") { connect() }
                            .disabled(host.authentication == .password ? password.isEmpty : publicKey == nil)
                    }
                }
            }
            .navigationTitle(host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if controller == nil {
                    ToolbarItem(placement: .navigation) {
                        Button("Servers", systemImage: "chevron.left", action: onBack)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(host.authentication == .ed25519 ? "SSH key" : "Manage sign-in") {
                            if host.authentication == .ed25519 { generateKey() }
                            managingSignIn = true
                        }
                    }
                }
            }
            .toolbar(.visible, for: .navigationBar)
            .sheet(isPresented: $managingSignIn) {
                NavigationStack {
                    Form {
                        LabeledContent("Endpoint", value: "\(host.username)@\(host.address):\(host.port)")
                        if host.authentication == .ed25519 {
                            if let publicKey {
                                Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                                ShareLink(item: publicKey) { Label("Export public key", systemImage: "square.and.arrow.up") }
                            }
                            Text("Enroll this existing public key through your trusted server process. The private key stays on this device. Exporting does not replace the key.")
                        } else {
                            SecureField("Password", text: $password).textContentType(.password)
                            Button("Save sign-in") {
                                do {
                                    guard !password.isEmpty else { return }
                                    try environment.secrets.save(Data(password.utf8), serverID: host.id, kind: .password)
                                    password = ""; managingSignIn = false
                                } catch { self.error = "The password could not be saved." }
                            }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                    .navigationTitle("Manage sign-in")
                    .toolbar { Button("Done") { managingSignIn = false } }
                }
            }
            .alert("Verify server fingerprint", isPresented: Binding(
                get: { fingerprints.identity != nil },
                set: { if !$0 { fingerprints.answer(false) } })) {
                    Button("Cancel", role: .cancel) { fingerprints.answer(false) }
                    Button("Trust and authenticate") { fingerprints.answer(true) }
                } message: {
                    Text(fingerprints.identity.map { "\($0.host):\($0.port)\n\($0.algorithm)\n\($0.fingerprint)" } ?? "")
                }
            .task { prepareConnection() }
            .onDisappear { fingerprints.answer(false) }
        }
    }

    private func prepareConnection() {
        guard !checkedCredentials else { return }
        checkedCredentials = true
        defer { checkingCredentials = false }
        do {
            if try SSHCredentialSetup.isReady(for: host, secrets: environment.secrets) {
                controller = try TerminalController(host: host, environment: environment)
            } else {
                #if DEBUG
                environment.phoneProof?.failure = "credentialNotReady"
                environment.phoneProof?.write()
                #endif
            }
        } catch {
            #if DEBUG
            environment.phoneProof?.failure = "credentialReadUnavailable"
            environment.phoneProof?.events.appendFailure(SSHConnectionDiagnostic.capture(error))
            environment.phoneProof?.write()
            #endif
            self.error = "The saved credential could not be read. Unlock this device and try again."
        }
    }
    private func generateKey() {
        do {
            publicKey = try SSHCredentialSetup.preparePublicKey(serverID: host.id, secrets: environment.secrets)
        } catch { self.error = "The device-only key could not be saved." }
    }
    private func connect() {
        do {
            if host.authentication == .password {
                try environment.secrets.save(Data(password.utf8), serverID: host.id, kind: .password)
                password = ""
            }
            controller = try TerminalController(host: host, environment: environment)
        } catch { self.error = "The native terminal could not be created." }
    }
}

@MainActor
private final class TerminalController: ObservableObject {
    let coordinator: TerminalSessionCoordinator
    @Published var status: ConnectionState = .connecting
    @Published var keyboardVisible = false
    @Published var controlsExpanded = false
    @Published var pasteRequestCount = 0
    @Published var browserRequestCount = 0
    @Published var restoringView = false
    private let navigation: RememberedConnectionStore
    private let serverID: UUID
    private var resumeTask: Task<Void, Never>?
    private var resumeGeneration = 0
    private var mayRememberView = false
    private var viewConnectionGeneration: Int?
    private(set) var manuallyDetached = false
    weak var terminalView: TerminalView?
    private var shutdownTask: Task<Void, Never>?
    private(set) var shutdownCompleted = false
    private(set) var uiPresentedFrames = 0

    func observePresentedFrames(in view: TerminalView? = nil) {
        uiPresentedFrames = max(uiPresentedFrames, (view ?? terminalView)?.presentedFrames ?? 0)
    }
    #if DEBUG
    private let proof: PhoneProof?
    private let proofEngine: AppleTerminalEngine
    #endif

    init(host: Host, environment: AppValues) throws {
        navigation = environment.navigation
        serverID = host.id
        let engine = try AppleTerminalEngine()
        #if DEBUG
        proof = environment.phoneProof
        if let proof, proof.host.id != host.id { throw InventoryError.invalidField }
        proofEngine = engine
        let proofFingerprint = proof?.fingerprint
        let proofEvents = proof?.events
        let trust: any KnownHostStore = proof?.trust ?? environment.knownHosts
        #else
        let trust: any KnownHostStore = environment.knownHosts
        #endif
        let configuration = SSHTransportConfiguration(
            serverID: host.id, host: host.address.lowercased(), port: host.port, username: host.username,
            authentication: host.authentication == .password ? .password : .ed25519,
            knownHosts: trust, secrets: environment.secrets,
            confirmUnknownFingerprint: { identity in
                #if DEBUG
                if let proofFingerprint { return identity.fingerprint == proofFingerprint }
                #endif
                return await environment.fingerprints.request(identity)
            }, lifecycleEvent: { label in
                #if DEBUG
                proofEvents?.append(label)
                #endif
            }, diagnosticFailure: { diagnostic in
                #if DEBUG
                proofEvents?.appendFailure(diagnostic)
                #endif
            })
        #if DEBUG
        let command = proof.map { "herdr --session \($0.session)" } ?? "herdr --session default"
        #else
        let command = "herdr --session default"
        #endif
        coordinator = TerminalSessionCoordinator(command: command, transportFactory: { NIOSSHStreamingTransport(configuration: configuration) }, engine: engine)
    }

    var isPhoneProof: Bool {
        #if DEBUG
        proof != nil
        #else
        false
        #endif
    }

    func connect() async {
        guard shutdownTask == nil else { status = coordinator.state; return }
        manuallyDetached = false
        status = .connecting
        do {
            try await coordinator.connect(); status = coordinator.state
            if !isPhoneProof { startViewResume() }
        }
        catch {
            status = coordinator.state
            #if DEBUG
            proof?.events.appendFailure(SSHConnectionDiagnostic.capture(error))
            if proof?.failure == nil {
                proof?.failure = (error as? SSHTransportError).map { String(describing: $0) } ?? "connectionFailed"
            }
            #endif
        }
    }
    func pause(manual: Bool = false) async {
        if manual { manuallyDetached = true }
        await rememberCurrentView()
        stopViewResume()
        await coordinator.detach(); status = coordinator.state
    }

    func confirmBrowserSelection() { mayRememberView = true }

    private func stopViewResume() {
        resumeGeneration &+= 1
        resumeTask?.cancel(); resumeTask = nil
        restoringView = false
    }

    private func rememberCurrentView() async {
        guard mayRememberView else { return }
        let context = await coordinator.herdrCatalogContext()
        guard context.generation == viewConnectionGeneration, let catalog = context.catalog,
              let view = RememberedHerdrView(catalog: catalog) else { return }
        try? navigation.remember(view, for: serverID)
    }

    private func startViewResume() {
        stopViewResume()
        let expected = resumeGeneration
        let saved = navigation.view(for: serverID)
        mayRememberView = false
        restoringView = true
        resumeTask = Task { [weak self] in
            guard let self else { return }
            let connection = await self.coordinator.herdrCatalogContext().generation
            var catalog: HerdrCatalog?
            for _ in 0..<80 {
                guard !Task.isCancelled, expected == self.resumeGeneration else { return }
                if self.coordinator.state != .connected { break }
                catalog = await self.coordinator.herdrCatalog()
                if catalog != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, expected == self.resumeGeneration else { return }
            var restored = false
            if self.coordinator.state == .connected, let saved, let catalog, saved.target(in: catalog) != nil {
                do {
                    try await self.coordinator.restoreHerdrView(saved)
                    for _ in 0..<60 {
                        guard !Task.isCancelled, expected == self.resumeGeneration else { return }
                        if let current = await self.coordinator.herdrCatalog(),
                           current.focusedWorkspaceID == saved.workspaceID,
                           saved.paneID == nil || current.focusedPaneID == saved.paneID {
                            restored = true; break
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                } catch { /* A deleted/restarted target returns to the native picker. */ }
            }
            guard !Task.isCancelled, expected == self.resumeGeneration else { return }
            self.restoringView = false
            self.mayRememberView = restored
            self.viewConnectionGeneration = connection
            let initial = await self.coordinator.herdrCatalog().flatMap(RememberedHerdrView.init(catalog:))
            if !restored && self.coordinator.state == .connected { self.browserRequestCount &+= 1 }
            while !Task.isCancelled, expected == self.resumeGeneration {
                if self.coordinator.state == .connected {
                    let context = await self.coordinator.herdrCatalogContext()
                    if context.generation != connection || (initial != nil && context.catalog != nil && context.catalog?.bootID != initial?.bootID) {
                        self.startViewResume()
                        return
                    }
                    await self.rememberCurrentView()
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        observePresentedFrames()
        await rememberCurrentView()
        stopViewResume()
        let task = Task {
            await coordinator.shutdown(); status = coordinator.state
            shutdownCompleted = true
            #if DEBUG
            proof?.events.append("coordinator-shutdown-completed")
            proof?.write(controller: self)
            #endif
        }
        shutdownTask = task
        await task.value
    }
    func sceneChanged(_ phase: ScenePhase) {
        #if DEBUG
        guard let proof else { return }
        switch phase {
        case .active: proof.scene = "active"
        case .inactive: proof.scene = "inactive"
        case .background: proof.scene = "background"; proof.failure = "sceneBackground"
        @unknown default: proof.scene = "unknown"
        }
        proof.events.append("scene-" + proof.scene)
        proof.write(controller: self)
        #endif
    }
    #if DEBUG
    func runPhoneProof() async {
        guard let proof else { await connect(); return }
        guard !proof.started else { return }
        proof.started = true
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            proof.failure = "timedOut"
            await shutdown()
            proof.write(controller: self)
        }
        defer { timeout.cancel() }
        await connect()
        guard coordinator.state == .connected, proof.failure == nil, !Task.isCancelled else { await shutdown(); proof.write(controller: self); return }
        await coordinator.resize(columns: 91, rows: 27)
        proof.resizeRequested = true
        // PTY acceptance is not Herdr readiness. Require the parent's OWN fixture banner and real UIKit presentation.
        for _ in 0..<60 {
            if Task.isCancelled || proof.failure != nil || coordinator.state != .connected { break }
            observePresentedFrames()
            if let data = try? await coordinator.frameSnapshot(), let frame = try? TerminalFrame.decode(data) {
                proof.nativeFrameSeen = true
                proof.observedWindow = [frame.columns, frame.rows]
                proof.readyMarkerObserved = frame.cells.map(\.text).joined().contains("SSHEPHERD_PHONE_FIXTURE_READY")
                if proof.readyMarkerObserved, let view = terminalView, view.presentedFrames > 0,
                   view.window?.windowScene?.activationState == .foregroundActive {
                    proof.uiReady = true; break
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard proof.uiReady, proof.failure == nil, !Task.isCancelled, coordinator.state == .connected else {
            if proof.failure == nil { proof.failure = proof.readyMarkerObserved ? "uiFramesNotPresented" : "fixtureNotReady" }
            await shutdown(); proof.write(controller: self); return
        }
        proof.events.append("fixture-ui-ready")
        do {
            // Encode semantic Enter with the same native engine used by UIKit, then send one ordered payload.
            // No raw LF, retry, separate uncertain Enter, or input replay on reconnect.
            let enter = try await proofEngine.key(.init(.enter))
            guard !enter.isEmpty, coordinator.state == .connected, proof.failure == nil, !Task.isCancelled else {
                throw TerminalTransportError.disconnected
            }
            var input = Data("printf 'SSHEPHERD_PHONE_%s_OK\\n' PROOF".utf8)
            input.append(enter)
            await coordinator.send(input)
            proof.inputSent = true
        } catch {
            proof.failure = "semanticEnterUnavailable"
            await shutdown(); proof.write(controller: self); return
        }
        for _ in 0..<60 {
            if Task.isCancelled || proof.failure != nil { break }
            observePresentedFrames()
            if let data = try? await coordinator.frameSnapshot(), let frame = try? TerminalFrame.decode(data) {
                proof.nativeFrameSeen = true
                proof.observedWindow = [frame.columns, frame.rows]
                let text = frame.cells.map(\.text).joined()
                if text.contains("SSHEPHERD_PHONE_PROOF_OK") { proof.markerObserved = true; break }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if proof.markerObserved && proof.failure == nil {
            await pause()
            // Clear only the local native display, not the remote pane. A retained old frame cannot prove persistence.
            do { try await proofEngine.write(Data([0x1b, 0x63])) }
            catch { proof.failure = "nativeResetFailed" }
            guard proof.failure == nil else { await shutdown(); proof.write(controller: self); return }
            await connect()
            proof.reconnected = coordinator.state == .connected
            for _ in 0..<40 {
                if Task.isCancelled || proof.failure != nil { break }
                observePresentedFrames()
                if let bytes = try? await coordinator.frameSnapshot(), let frame = try? TerminalFrame.decode(bytes),
                   frame.cells.map(\.text).joined().contains("SSHEPHERD_PHONE_PROOF_OK") {
                    proof.markerAfterReconnect = true; break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        if proof.failure == nil && !proof.markerAfterReconnect { proof.failure = "fixtureMarkerNotObserved" }
        proof.connectionStatus = proof.reconnected ? "reconnected" : "connected"
        await shutdown()
        proof.write(controller: self)
    }
    #endif
}

private struct TerminalScreen: View {
    @ObservedObject var controller: TerminalController
    let hostName: String
    let onBack: () -> Void
    let manageSignIn: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var pasteText: String?
    @State private var pasteError: String?
    @State private var showingBrowser = false

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = controller.status {
                HStack {
                    Text(message).font(.caption)
                    Button("Reconnect") { Task { await controller.connect() } }
                }.padding(6)
            }
            TerminalRepresentable(controller: controller)
                .background(.black)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .background(.black)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    controller.keyboardVisible = false
                    showingBrowser = true
                } label: {
                    Label("Agents | Workspaces", systemImage: "square.stack")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline).lineLimit(1)
                }
                .accessibilityLabel("Agents | Workspaces")
                .accessibilityIdentifier("Agents | Workspaces")
                .disabled(controller.status != .connected || controller.restoringView)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text(hostName)
                    Button("Switch server", systemImage: "server.rack", action: onBack)
                    Button("Paste text", systemImage: "doc.on.clipboard") { preparePaste() }
                        .disabled(controller.status != .connected)
                    Button("Manage sign-in", systemImage: "key", action: manageSignIn)
                    if controller.status == .disconnected {
                        Button("Reconnect", systemImage: "arrow.clockwise") { Task { await controller.connect() } }
                    } else {
                        Button("Detach", systemImage: "network.slash") { Task { await controller.pause(manual: true) } }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Terminal menu")
            }
        }
        .overlay {
            if controller.status == .connecting || controller.status == .suspended || controller.restoringView {
                ProgressView(controller.restoringView ? "Restoring last view…" : (controller.manuallyDetached ? "Disconnecting…" : (controller.status == .suspended ? "Reconnecting…" : "Connecting…")))
                    .padding().background(.regularMaterial).clipShape(.rect(cornerRadius: 12))
            }
        }
        .onChange(of: controller.browserRequestCount) { _, _ in showingBrowser = true }
        .sheet(isPresented: $showingBrowser) { HerdrBrowserView(controller: controller) }
        .onChange(of: controller.pasteRequestCount) { _, _ in preparePaste() }
        .alert(pasteError == nil ? "Paste text into terminal?" : "Paste refused", isPresented: Binding(get: { pasteText != nil || pasteError != nil }, set: { if !$0 { pasteText = nil; pasteError = nil } })) {
            if pasteText != nil {
                Button("Cancel", role: .cancel) { pasteText = nil }
                Button("Paste") {
                    if let value = pasteText { controller.terminalView?.confirmPaste(value, confirmed: true) }
                    pasteText = nil
                }.disabled(controller.status != .connected)
            } else { Button("OK") { pasteError = nil } }
        } message: {
            if let error = pasteError { Text(error) }
            else if let text = pasteText {
                Text("\(text.utf8.count) bytes\n\n\(String(text.prefix(1200)))\(text.count > 1200 ? "\n\nPreview truncated; the entire captured text will be sent." : "")")
            }
        }
        .task {
            controller.sceneChanged(scenePhase)
            #if DEBUG
            await controller.runPhoneProof()
            #else
            await controller.connect()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            controller.sceneChanged(phase)
            if controller.isPhoneProof {
                if phase == .background { Task { await controller.shutdown() } }
                return
            }
            if phase == .background { Task { await controller.pause() } }
            else if phase == .active && !controller.manuallyDetached {
                let state = controller.coordinator.state
                if state == .disconnected || state == .suspended { Task { await controller.connect() } }
            }
        }
        .onDisappear { Task { await controller.shutdown() } }
    }
    private func preparePaste() {
        pasteText = nil; pasteError = nil
        guard let text = UIPasteboard.general.string, !text.isEmpty else { pasteError = "The clipboard contains no text."; return }
        do { _ = try PasteInput.utf8(text); pasteText = text }
        catch { pasteError = "Paste must be text at most 60,000 UTF-8 bytes, without control characters other than tabs and newlines." }
    }
}

private struct HerdrBrowserView: View {
    @ObservedObject var controller: TerminalController
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: HerdrCatalog?
    @State private var query = ""
    @State private var section = "agents"
    @State private var selection: String?
    @State private var error: String?
    @State private var waited = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Browse", selection: $section) {
                    Text("Agents").tag("agents")
                    Text("Workspaces").tag("workspaces")
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                if controller.status != .connected {
                    ContentUnavailableView("Disconnected", systemImage: "network.slash", description: Text("Reconnect the terminal before selecting an agent or workspace."))
                } else if let catalog {
                    List {
                        if section == "agents" {
                            let agents = catalog.matchingAgents(query)
                            if agents.isEmpty {
                                Text(query.isEmpty ? "No agents are running." : "No matching agents.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(agents) { agent in
                                Button {
                                    select(agent.id, workspace: false)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "terminal")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(agent.label).foregroundStyle(.primary)
                                            Text("\(workspaceLabel(agent.workspaceID)) · \(agent.agentStatus)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selection == agent.id { ProgressView() }
                                        else if agent.id == catalog.focusedPaneID { Image(systemName: "checkmark") }
                                    }
                                }
                                .accessibilityIdentifier("Herdr agent \(agent.id)")
                                .disabled(selection != nil || controller.restoringView)
                            }
                        } else {
                            let workspaces = catalog.matchingWorkspaces(query)
                            if workspaces.isEmpty { Text("No matching workspaces.").foregroundStyle(.secondary) }
                            ForEach(workspaces) { workspace in
                                Button {
                                    select(workspace.id, workspace: true)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "square.stack")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(workspace.label).foregroundStyle(.primary)
                                            Text(workspace.agentStatus).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selection == workspace.id { ProgressView() }
                                        else if workspace.id == catalog.focusedWorkspaceID { Image(systemName: "checkmark") }
                                    }
                                }
                                .accessibilityIdentifier("Herdr workspace \(workspace.id)")
                                .disabled(selection != nil || controller.restoringView)
                            }
                        }
                    }
                    .listStyle(.plain)
                } else if waited {
                    ContentUnavailableView {
                        Label("Native browser unavailable", systemImage: "server.rack")
                    } description: {
                        Text("This connection needs the SSHepherd Herdr bridge. You can still use the terminal picker.")
                    } actions: {
                        Button("Open terminal picker") {
                            Task {
                                await controller.coordinator.sendKey(.init(.character("b"), modifiers: .control))
                                await controller.coordinator.sendKey(.init(.character("w")))
                                dismiss()
                            }
                        }
                    }
                } else {
                    Spacer(); ProgressView("Loading catalog…"); Spacer()
                }
            }
            .navigationTitle("Agents & Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: section == "agents" ? "Find an agent" : "Find a workspace")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { controller.confirmBrowserSelection(); dismiss() }
                    .disabled(controller.restoringView)
            } }
            .alert("Selection failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .task {
                var attempts = 0
                while !Task.isCancelled {
                    catalog = await controller.coordinator.herdrCatalog()
                    attempts += 1
                    if attempts >= 20 { waited = true }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
        }
    }

    private func workspaceLabel(_ id: String) -> String {
        catalog?.workspaces.first(where: { $0.id == id })?.label ?? id
    }

    private func select(_ id: String, workspace: Bool) {
        guard selection == nil else { return }
        selection = id
        Task {
            defer { selection = nil }
            do {
                if workspace { try await controller.coordinator.selectHerdrWorkspace(id) }
                else { try await controller.coordinator.selectHerdrAgent(id) }
                controller.confirmBrowserSelection()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct TerminalRepresentable: UIViewRepresentable {
    @ObservedObject var controller: TerminalController
    final class Coordinator {
        weak var controller: TerminalController?
        init(_ controller: TerminalController) { self.controller = controller }
    }
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.session = controller.coordinator; view.frameProvider = controller.coordinator
        view.pasteRequested = { [weak controller] in
            if let controller { controller.pasteRequestCount &+= 1 }
        }
        view.stateChanged = { [weak controller, weak view] state in
            guard let controller, let view, controller.terminalView === view,
                  state == controller.coordinator.state else { return }
            controller.observePresentedFrames()
            if controller.status != state { controller.status = state }
        }
        view.controlsExpansionChanged = { [weak controller] expanded in
            controller?.controlsExpanded = expanded
        }
        view.keyboardVisibilityChanged = { [weak controller] visible in
            if controller?.keyboardVisible != visible { controller?.keyboardVisible = visible }
        }
        controller.terminalView = view
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        view.setKeyboardVisible(controller.keyboardVisible)
        if controller.coordinator.state == .connected { view.startInput() }
        else { view.pauseInput() }
    }
    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.controller?.observePresentedFrames(in: view)
        view.stateChanged = nil
        view.pauseInput()
    }
}

#if DEBUG
/// Debug launch inputs never accept arbitrary commands or an implicit/default session.
@MainActor
private final class PhoneProof {
    let attemptUUID = UUID().uuidString
    let createdAt = ISO8601DateFormatter().string(from: Date())
    var scene = "unknown"
    let host: Host
    let session: String
    let fingerprint: String
    let trust: ProofKnownHosts
    let events = ProofEvents()
    var started = false
    var failure: String?
    var connectionStatus: String?
    var observedWindow: [Int] = []
    var resizeRequested = false
    var inputSent = false
    var nativeFrameSeen = false
    var readyMarkerObserved = false
    var uiReady = false
    var markerObserved = false
    var reconnected = false
    var markerAfterReconnect = false

    static func argument(_ flag: String, in arguments: [String]) throws -> String {
        guard arguments.filter({ $0 == flag }).count == 1,
              let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("--") else { throw InventoryError.invalidField }
        return arguments[index + 1]
    }

    init(arguments: [String], hosts: [Host], knownHosts: any KnownHostStore) throws {
        let id = try Self.argument("--phone-proof", in: arguments)
        guard let uuid = UUID(uuidString: id), let selected = hosts.first(where: { $0.id == uuid }),
              selected.authentication == .ed25519,
              !arguments.contains("--export-public-key") else { throw InventoryError.invalidField }
        host = selected
        session = try Self.argument("--own-session", in: arguments)
        guard session.hasPrefix("sshepherd-phone-proof-"), session.count > 22, session.count <= 80,
              session.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw InventoryError.invalidField
        }
        fingerprint = try Self.argument("--expected-host-fingerprint", in: arguments)
        guard fingerprint.hasPrefix("SHA256:"), fingerprint.count == 50,
              let digest = Data(base64Encoded: String(fingerprint.dropFirst(7)) + "="), digest.count == 32 else {
            throw InventoryError.invalidField
        }
        trust = ProofKnownHosts(base: knownHosts, fingerprint: fingerprint)
        write() // Fresh attempt record even if the subsequent credential read is unavailable.
    }

    func write(controller: TerminalController? = nil) {
        controller?.observePresentedFrames()
        let state: String
        switch controller?.coordinator.state {
        case nil: state = "launchPrepared"
        case .connected?: state = "connected"
        case .connecting?: state = "connecting"
        case .disconnected?: state = "disconnected"
        case .suspended?: state = "suspended"
        case .failed?: state = "failed"
        }
        let report: [String: Any] = [
            "attemptUUID": attemptUUID, "createdAt": createdAt, "scene": scene,
            "serverID": host.id.uuidString, "host": host.address, "port": host.port,
            "username": host.username, "session": session, "status": state,
            "connectionStatusBeforeTeardown": connectionStatus ?? state,
            "teardownCompleted": controller?.shutdownCompleted == true && controller?.coordinator.state == .disconnected,
            "failure": failure ?? NSNull(), "lifecycle": events.snapshot(),
            "errorDiagnostics": events.failureObjects(),
            "ptyAccepted": events.snapshot().contains("session-ready"),
            "resizeRequested": resizeRequested, "requestedWindow": [91, 27], "observedWindow": observedWindow,
            "inputSentOnce": inputSent, "nativeFrameSeen": nativeFrameSeen,
            "uiPresentedFrames": controller?.uiPresentedFrames ?? 0,
            "fixtureReadyMarkerObserved": readyMarkerObserved, "fixtureUIReady": uiReady,
            "uiWindowAttached": controller?.terminalView?.window != nil,
            "uiSceneForegroundActive": controller?.terminalView?.window?.windowScene?.activationState == .foregroundActive,
            "fixtureMarkerObserved": markerObserved, "reconnected": reconnected,
            "markerVisibleAfterReconnect": markerAfterReconnect,
            "persistenceProven": markerAfterReconnect, "teardownRequested": controller?.shutdownCompleted == true
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try AppSupportAtomicDataStore(filename: "device-phone-proof-\(host.id.uuidString).json", maximumSize: 16384).replace(with: data)
        } catch { failure = "diagnosticStorageFailed" }
    }
}

private final class ProofEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    private var failures: [SSHConnectionDiagnostic] = []
    func append(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        if labels.count < 64 { labels.append(String(label.prefix(80))) }
    }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return labels }
    func appendFailure(_ failure: SSHConnectionDiagnostic) {
        lock.lock(); defer { lock.unlock() }
        if failures.count < 4 { failures.append(failure) }
    }
    func failureObjects() -> [[String: Any]] {
        lock.lock(); let values = failures; lock.unlock()
        guard let data = try? JSONEncoder().encode(values),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return objects
    }
}

/// Always requests a real host-key callback; persistence still refuses changed saved identities.
private struct ProofKnownHosts: KnownHostStore {
    let base: any KnownHostStore
    let fingerprint: String
    func identity(for host: String, port: UInt16) throws -> HostIdentity? { nil }
    func trust(_ identity: HostIdentity, replacing expected: HostIdentity?) throws {
        guard expected == nil, identity.fingerprint == fingerprint else { throw KnownHostError.changed }
        if let saved = try base.identity(for: identity.host, port: identity.port) {
            guard saved == identity else { throw KnownHostError.changed }
        } else { try base.trust(identity) }
    }
}
#endif
