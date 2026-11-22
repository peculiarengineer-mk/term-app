#if DEBUG
import SwiftUI
import SwiftData
import Store

struct DebugSyncTools: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Host.label) private var hosts: [Host]
    @State private var items: [Item] = []
    @State private var message: String?

    private struct Item: Identifiable {
        let service: String
        let account: String
        let synchronizable: Bool
        var id: String { "\(service)|\(account)|\(synchronizable)" }
    }

    var body: some View {
        List {
            Section("Duplicate host") {
                ForEach(hosts) { host in
                    Button(host.label.isEmpty ? host.hostname : host.label) { duplicate(host) }
                }
                if let message { Text(message).font(.footnote) }
            }
            Section("Keychain items") {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.service).font(.footnote)
                        Text(item.account).font(.system(.footnote, design: .monospaced))
                        Text(item.synchronizable ? "synced" : "local").font(.caption)
                        if item.service == KeychainService.hostPassword {
                            Text(hostLabel(for: item.account) ?? "unknown host").font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sync debug")
        .onAppear(perform: reload)
    }

    private func hostLabel(for account: String) -> String? {
        hosts.first { $0.id.uuidString == account }?.label
    }

    private func duplicate(_ h: Host) {
        context.insert(Host(
            id: h.id, label: h.label, hostname: h.hostname, port: h.port, username: h.username,
            authMethod: h.authMethod, keyID: h.keyID, tmuxCommand: h.tmuxCommand, tags: h.tags,
            source: h.source, createdAt: h.createdAt, updatedAt: h.updatedAt, copyID: UUID()))
        do {
            try context.save()
            message = "Duplicated"
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }

    private func reload() {
        let store = KeychainStore()
        var out: [Item] = []
        for service in [KeychainService.knownHosts, KeychainService.hostPassword] {
            for e in (try? store.readAll(service: service)) ?? [] {
                out.append(Item(service: service, account: e.account, synchronizable: e.synchronizable))
            }
        }
        items = out
    }
}
#endif
