import SwiftUI
import Store
import TermUI

/// Drawer / management list for reusable terminal `CommandSnippet`s.
struct SnippetDrawerView: View {
    let onRun: ((CommandSnippet) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @State private var snippets: [CommandSnippet] = SnippetStore.load()
    @State private var adding = false
    @State private var editing: CommandSnippet?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    init(onRun: ((CommandSnippet) -> Void)? = nil) {
        self.onRun = onRun
    }

    var body: some View {
        if onRun != nil {
            NavigationStack {
                snippetList
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        } else {
            snippetList
        }
    }

    private var snippetList: some View {
        List {
            ForEach(snippets) { snippet in
                snippetRow(for: snippet)
                    .contextMenu {
                        if let onRun {
                            Button("Run", systemImage: "bolt.fill") {
                                runSnippet(snippet, handler: onRun)
                            }
                        }
                        Button("Edit", systemImage: "pencil") {
                            editing = snippet
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleteSnippet(snippet)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteSnippet(snippet)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editing = snippet
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .overlay {
            if snippets.isEmpty {
                ContentUnavailableView {
                    Label("No Snippets", systemImage: "bolt.slash")
                } description: {
                    Text("Tap + to save a command snippet.")
                } actions: {
                    Button("New Snippet") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Command Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppHaptics.impact(.light)
                    adding = true
                } label: {
                    Label("Add Snippet", systemImage: "plus")
                }
            }
        }
        .onAppear {
            snippets = SnippetStore.load()
        }
        .sheet(isPresented: $adding) {
            SnippetEditorView(snippet: nil) { saved in
                snippets.append(saved)
                SnippetStore.save(snippets)
            }
        }
        .sheet(item: $editing) { existing in
            SnippetEditorView(snippet: existing) { saved in
                if let index = snippets.firstIndex(where: { $0.id == saved.id }) {
                    snippets[index] = saved
                    SnippetStore.save(snippets)
                }
            }
        }
    }

    private func snippetRow(for snippet: CommandSnippet) -> some View {
        Button {
            if let onRun {
                runSnippet(snippet, handler: onRun)
            } else {
                AppHaptics.impact(.light)
                editing = snippet
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(snippet.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if snippet.appendNewline {
                            Text("↵")
                                .font(.caption2.monospaced().weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(theme.accentColor)
                                .background(
                                    theme.accentColor.opacity(theme.isDark ? 0.20 : 0.14),
                                    in: Capsule()
                                )
                                .accessibilityLabel("Sends Return")
                        }
                    }

                    Text(snippet.command)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                if onRun != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(theme.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runSnippet(_ snippet: CommandSnippet, handler: (CommandSnippet) -> Void) {
        AppHaptics.impact(.light)
        handler(snippet)
        dismiss()
    }

    private func deleteSnippet(_ snippet: CommandSnippet) {
        snippets.removeAll { $0.id == snippet.id }
        SnippetStore.save(snippets)
        AppHaptics.notify(.warning)
    }
}

private struct SnippetEditorView: View {
    let snippet: CommandSnippet?
    let onSave: (CommandSnippet) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var appendNewline: Bool

    init(snippet: CommandSnippet?, onSave: @escaping (CommandSnippet) -> Void) {
        self.snippet = snippet
        self.onSave = onSave
        _name = State(initialValue: snippet?.name ?? "")
        _command = State(initialValue: snippet?.command ?? "")
        _appendNewline = State(initialValue: snippet?.appendNewline ?? true)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                }

                Section("Command") {
                    TextField("Command", text: $command, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...5)

                    Toggle("Send Return (↵)", isOn: $appendNewline)
                }
            }
            .navigationTitle(snippet == nil ? "New Snippet" : "Edit Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let saved = CommandSnippet(
                            id: snippet?.id ?? UUID(),
                            name: trimmedName,
                            command: command,
                            appendNewline: appendNewline
                        )
                        AppHaptics.notify(.success)
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
