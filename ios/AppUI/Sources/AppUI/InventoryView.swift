#if os(iOS)
import SwiftUI
import Observation

@MainActor @Observable public final class InventoryModel {
    public private(set) var hosts: [Host] = []
    public var state: [UUID: ConnectionState] = [:]
    private let store: any HostStore
    public init(store: any HostStore) { self.store = store }
    public func load() async { hosts = (try? await store.hosts()) ?? [] }
    public func save(_ hosts: [Host]) async { guard (try? await store.save(hosts)) != nil else { return }; self.hosts = hosts }
    public func remove(_ host: Host) async { await save(hosts.filter { $0.id != host.id }) }
    public func upsert(_ host: Host) async {
        var next = hosts
        if let index = next.firstIndex(where: { $0.id == host.id }) { next[index] = host } else { next.append(host) }
        await save(next)
    }
}

public struct InventoryView: View {
    @State private var model: InventoryModel
    @State private var editor: Host?
    private let connect: (Host) -> Void
    public init(model: InventoryModel, connect: @escaping (Host) -> Void = { _ in }) { _model = State(initialValue: model); self.connect = connect }
    public var body: some View {
        NavigationStack {
            List {
                if model.hosts.isEmpty {
                    ContentUnavailableView("No servers", systemImage: "server.rack", description: Text("Add a server to begin."))
                }
                ForEach(model.hosts) { host in
                    Button { connect(host) } label: {
                        HStack { VStack(alignment: .leading) { Text(host.name); Text("\(host.username)@\(host.address):\(host.port)").font(.caption).foregroundStyle(.secondary) }; Spacer(); status(model.state[host.id] ?? .disconnected) }
                    }
                    .accessibilityLabel("Connect to \(host.name)")
                    .swipeActions {
                        Button("Settings") { editor = host }.tint(.blue)
                        Button("Delete", role: .destructive) { Task { await model.remove(host) } }
                    }
                }
                .onDelete { offsets in Task { await model.save(model.hosts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)) } }
            }
            .navigationTitle("Servers")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { editor = Host(name: "", address: "", username: "") } label: { Label("Add server", systemImage: "plus") } } }
        }
        .task { await model.load() }
        .sheet(item: $editor) { host in HostEditor(host: host) { updated in Task { await model.upsert(updated) }; editor = nil } }
    }
    @ViewBuilder private func status(_ value: ConnectionState) -> some View {
        switch value { case .connected: Label("Connected", systemImage: "checkmark.circle").foregroundStyle(.green); case .connecting: ProgressView(); case .suspended: Label("Paused", systemImage: "pause.circle"); case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red); case .disconnected: EmptyView() }
    }
}

private struct HostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    private let save: (Host) -> Void
    init(host: Host, save: @escaping (Host) -> Void) { _host = State(initialValue: host); self.save = save }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $host.name)
                TextField("Address", text: $host.address).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username", text: $host.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $host.port, format: .number).keyboardType(.numberPad)
                Picker("Authentication", selection: $host.authentication) {
                    Text("Generated Ed25519 key").tag(HostAuthentication.ed25519)
                    Text("Password").tag(HostAuthentication.password)
                }
            }
            .navigationTitle("Server Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(host) }.disabled(host.name.isEmpty || host.address.isEmpty || host.username.isEmpty) }
            }
        }
    }
}
#endif
