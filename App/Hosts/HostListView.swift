import SwiftUI
import SwiftData
import Store

struct HostListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Host.label) private var hosts: [Host]
    @State private var search = ""
    @State private var editing: Host?
    @State private var adding = false
    @State private var connecting: Host?

    private var filtered: [Host] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return hosts }
        return hosts.filter {
            $0.label.localizedCaseInsensitiveContains(q)
                || $0.hostname.localizedCaseInsensitiveContains(q)
                || $0.username.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { host in
                Button { connecting = host } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.label.isEmpty ? host.hostname : host.label).font(.headline)
                        Text("\(host.username.isEmpty ? "" : host.username + "@")\(host.hostname):\(host.port)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { delete(host) } label: { Label("Delete", systemImage: "trash") }
                    Button { editing = host } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                }
            }
        }
        .overlay {
            if hosts.isEmpty {
                ContentUnavailableView("No hosts", systemImage: "server.rack",
                                       description: Text("Tap + to add a host."))
            }
        }
        .searchable(text: $search)
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Label("Add host", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { HostEditorView(host: nil) } }
        .sheet(item: $editing) { host in NavigationStack { HostEditorView(host: host) } }
        .fullScreenCover(item: $connecting) { host in
            NavigationStack { HostConnectionView(host: host) }
        }
    }

    private func delete(_ host: Host) {
        HostSecrets.deletePassword(for: host.id)
        context.delete(host)
        try? context.save()
    }
}
