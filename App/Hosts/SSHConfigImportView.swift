import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import Store
import TermUI

/// Modal sheet for importing host entries from an OpenSSH `~/.ssh/config` file or pasted text.
struct SSHConfigImportView: View {
    private static let maxConfigFileBytes = 1024 * 1024

    private struct ParsedEntryRow: Identifiable, Equatable {
        let id = UUID()
        let entry: SSHConfigEntry
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Host.label) private var existingHosts: [Host]
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var configText = ""
    @State private var parsedRows: [ParsedEntryRow] = []
    @State private var deselectedIDs: Set<UUID> = []
    @State private var showFileImporter = false
    @State private var fileImportTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var selectedEntries: [SSHConfigEntry] {
        parsedRows.filter { !deselectedIDs.contains($0.id) }.map(\.entry)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("SSH Config") {
                    ZStack(alignment: .topLeading) {
                        if configText.isEmpty {
                            Text("Host prod\n    HostName 203.0.113.10\n    User deploy\n    Port 22")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $configText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 150)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack(spacing: 16) {
                        Button("Choose file…", systemImage: "folder") {
                            showFileImporter = true
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button("Paste", systemImage: "doc.on.clipboard") {
                            pasteFromClipboard()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    if parsedRows.isEmpty {
                        Text(configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "Paste ~/.ssh/config text or choose a file above."
                             : "No concrete Host entries found. Wildcard-only blocks are skipped.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(parsedRows) { row in
                            entryRow(for: row)
                        }
                    }
                } header: {
                    HStack {
                        Text(parsedRows.isEmpty ? "Detected Hosts" : "Detected Hosts (\(parsedRows.count))")
                        Spacer()
                        if !parsedRows.isEmpty {
                            Button(selectedEntries.count == parsedRows.count ? "Deselect All" : "Select All") {
                                AppHaptics.impact(.light)
                                if selectedEntries.count == parsedRows.count {
                                    deselectedIDs = Set(parsedRows.map(\.id))
                                } else {
                                    deselectedIDs.removeAll()
                                }
                            }
                            .font(.caption.weight(.medium))
                            .textCase(nil)
                        }
                    }
                }
            }
            .onChange(of: configText) { _, newValue in
                errorMessage = nil
                reparseConfig(newValue)
            }
            .onDisappear {
                fileImportTask?.cancel()
                fileImportTask = nil
            }
            .navigationTitle("Import SSH Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import (\(selectedEntries.count))") {
                        importSelected()
                    }
                    .disabled(selectedEntries.isEmpty)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.plainText, .data, .item]
            ) { result in
                loadImportedFile(result)
            }
        }
    }

    private func entryRow(for row: ParsedEntryRow) -> some View {
        let entry = row.entry
        let isSelected = !deselectedIDs.contains(row.id)
        let duplicate = alreadyExists(entry)

        return Button {
            AppHaptics.impact(.light)
            if isSelected {
                deselectedIDs.insert(row.id)
            } else {
                deselectedIDs.remove(row.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? theme.accentColor : Color.secondary.opacity(0.6))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.alias)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if duplicate {
                            Text("Already exists")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .foregroundStyle(.secondary)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                    }

                    Text(endpointDisplay(for: entry))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if entry.proxyJump != nil || entry.forwardAgent {
                        HStack(spacing: 6) {
                            if let jump = entry.proxyJump {
                                Text("via \(jump)")
                            }
                            if entry.forwardAgent {
                                Text("Agent (-A)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func endpointDisplay(for entry: SSHConfigEntry) -> String {
        let userPart = entry.username.isEmpty ? "" : "\(entry.username)@"
        let portPart = entry.port == 22 ? "" : ":\(entry.port)"
        return "\(userPart)\(entry.hostname)\(portPart)"
    }

    private func alreadyExists(_ entry: SSHConfigEntry) -> Bool {
        existingHosts.contains { host in
            host.hostname.caseInsensitiveCompare(entry.hostname) == .orderedSame
                && host.port == entry.port
                && host.username == entry.username
        }
    }

    private func reparseConfig(_ text: String) {
        let rows = SSHConfigParser.parse(text).map { ParsedEntryRow(entry: $0) }
        parsedRows = rows
        deselectedIDs = Set(rows.filter { alreadyExists($0.entry) }.map(\.id))
    }

    private func pasteFromClipboard() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else {
            AppHaptics.notify(.warning)
            errorMessage = "Clipboard is empty."
            return
        }
        AppHaptics.impact(.light)
        if configText == pasted {
            deselectedIDs = Set(parsedRows.filter { alreadyExists($0.entry) }.map(\.id))
        } else {
            configText = pasted
        }
        errorMessage = nil
    }

    private func loadImportedFile(_ result: Result<URL, any Error>) {
        fileImportTask?.cancel()
        switch result {
        case .success(let url):
            fileImportTask = Task { @MainActor in
                defer { fileImportTask = nil }
                do {
                    let decoded = try await SecurityScopedFileReader.readText(
                        from: url,
                        maxBytes: Self.maxConfigFileBytes,
                        allowASCIIFallback: true
                    )
                    guard !Task.isCancelled else { return }
                    if configText == decoded {
                        deselectedIDs = Set(parsedRows.filter { alreadyExists($0.entry) }.map(\.id))
                    } else {
                        configText = decoded
                    }
                    errorMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = "Could not read file: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            errorMessage = "Could not open file: \(error.localizedDescription)"
        }
    }

    private func importSelected() {
        var importedPairs: [(entry: SSHConfigEntry, host: Host)] = []
        for entry in selectedEntries {
            let host = Host(
                label: entry.alias,
                hostname: entry.hostname,
                port: entry.port,
                username: entry.username,
                authMethod: entry.identityFile != nil ? "key" : "password",
                tags: ["imported"],
                forwardAgent: entry.forwardAgent
            )
            modelContext.insert(host)
            importedPairs.append((entry: entry, host: host))
        }

        let importedHosts = importedPairs.map(\.host)
        for (entry, host) in importedPairs {
            guard let proxyJump = entry.proxyJump, !proxyJump.isEmpty else { continue }
            if let jumpHostID = SSHOptionsBuilder.resolveImportedProxyJump(
                proxyJump: proxyJump,
                for: host,
                importedHosts: importedHosts,
                existingHosts: existingHosts
            ) {
                host.proxyJumpHostID = jumpHostID
            }
        }

        do {
            try modelContext.save()
            AppHaptics.notify(.success)
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = "Could not import hosts: \(error.localizedDescription)"
        }
    }
}
