import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SSHKit
import TermUI

/// Sheet for browsing and managing remote files over SFTP on an active `SSHConnection`.
struct SFTPBrowserView: View {
    let connection: SSHConnection
    let hostTitle: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var currentPath = ""
    @State private var entries: [SFTPEntry] = []
    @State private var isLoading = false
    @State private var workingStatus: String?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var previewEntry: SFTPEntry?
    @State private var showingImporter = false
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingEntry: SFTPEntry?
    @State private var renameText = ""
    @State private var showingRenameAlert = false
    @State private var deletingEntry: SFTPEntry?
    @State private var loadGeneration = 0
    @State private var didInitialLoad = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var isMutating: Bool { workingStatus != nil }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let textExtensions: Set<String> = [
        "log", "txt", "md", "markdown", "json", "yml", "yaml", "swift", "py", "sh",
        "bash", "zsh", "js", "ts", "jsx", "tsx", "html", "css", "xml", "toml", "ini",
        "conf", "cfg", "env", "c", "h", "cpp", "hpp", "rs", "go", "rb", "java", "kt",
        "sql", "csv",
    ]

    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz4", "dmg", "pkg", "deb", "rpm",
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "bmp", "tiff", "ico", "raw",
    ]

    var body: some View {
        NavigationStack {
            directoryList
                .sheet(item: $previewEntry) { entry in
                    SFTPFileDetailSheet(entry: entry, connection: connection)
                        .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                        .tint(theme.accentColor)
                }
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: [.item]
                ) { result in
                    handleFileImport(result)
                }
                .modifier(
                    SFTPAlertsModifier(
                        currentPath: currentPath,
                        showingNewFolderAlert: $showingNewFolderAlert,
                        newFolderName: $newFolderName,
                        showingRenameAlert: $showingRenameAlert,
                        renamingEntry: $renamingEntry,
                        renameText: $renameText,
                        deletingEntry: $deletingEntry,
                        actionError: $actionError,
                        onCreateFolder: { name in Task { await createFolder(named: name) } },
                        onRename: { entry, name in Task { await renameEntry(entry, to: name) } },
                        onDelete: { entry in Task { await deleteEntry(entry) } }
                    )
                )
        }
    }

    private var directoryList: some View {
        List {
            ForEach(entries) { entry in
                entryRowView(entry)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !currentPath.isEmpty {
                breadcrumbBar
            }
        }
        .overlay {
            stateOverlay
        }
        .refreshable {
            guard !currentPath.isEmpty else {
                await loadInitialDirectory()
                return
            }
            await loadDirectory(path: currentPath, isRefresh: true)
        }
        .navigationTitle(hostTitle.isEmpty ? "SFTP Files" : hostTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    AppHaptics.impact(.light)
                    newFolderName = ""
                    showingNewFolderAlert = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(currentPath.isEmpty || isLoading || isMutating)

                Button {
                    AppHaptics.impact(.light)
                    showingImporter = true
                } label: {
                    Label("Upload File", systemImage: "arrow.up.doc")
                }
                .disabled(currentPath.isEmpty || isLoading || isMutating)
            }
        }
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await loadInitialDirectory()
        }
    }

    private func entryRowView(_ entry: SFTPEntry) -> some View {
        entryRow(entry)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deletingEntry = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    beginRename(entry)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .contextMenu {
                if !entry.isDirectory {
                    Button("Preview / Download", systemImage: "doc.text.magnifyingglass") {
                        previewEntry = entry
                    }
                }
                Button("Rename", systemImage: "pencil") {
                    beginRename(entry)
                }
                Button("Copy Path", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = entry.path
                    AppHaptics.notify(.success)
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    deletingEntry = entry
                }
            }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if let workingStatus {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(workingStatus)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .padding(22)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else if isLoading && entries.isEmpty {
            ProgressView("Loading directory…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, entries.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Directory", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") {
                    Task {
                        if currentPath.isEmpty {
                            await loadInitialDirectory()
                        } else {
                            await loadDirectory(path: currentPath, isRefresh: false)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if !isLoading && entries.isEmpty && !currentPath.isEmpty {
            ContentUnavailableView {
                Label("Empty Directory", systemImage: "folder")
            } description: {
                Text("There are no files in \(currentPath).")
            }
        }
    }

    private var breadcrumbBar: some View {
        let components = Self.pathComponents(for: currentPath)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if currentPath != "/" {
                    Button {
                        AppHaptics.impact(.light)
                        let parent = SFTPPath.parent(of: currentPath)
                        Task { await loadDirectory(path: parent, isRefresh: false) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.up.left")
                                .font(.caption2.weight(.semibold))
                            Text("..")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(theme.accentColor)
                        .background(
                            theme.accentColor.opacity(theme.isDark ? 0.16 : 0.12),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isMutating)
                    .accessibilityLabel("Parent directory")
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(components.enumerated()), id: \.element.path) { index, component in
                                if index > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }

                                let isCurrent = component.path == currentPath
                                Button {
                                    guard !isCurrent else { return }
                                    AppHaptics.impact(.light)
                                    Task { await loadDirectory(path: component.path, isRefresh: false) }
                                } label: {
                                    Text(component.name)
                                        .font(.system(.caption, design: .monospaced).weight(isCurrent ? .semibold : .regular))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .foregroundStyle(isCurrent ? theme.accentColor : Color.primary)
                                        .background(
                                            isCurrent
                                                ? theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12)
                                                : Color.secondary.opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(isCurrent || isMutating)
                                .id(component.path)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: currentPath) { _, newPath in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(newPath, anchor: .trailing)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(currentPath, anchor: .trailing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(.bar)

            Divider()
        }
    }

    private func entryRow(_ entry: SFTPEntry) -> some View {
        Button {
            AppHaptics.impact(.light)
            if entry.isDirectory {
                Task { await loadDirectory(path: entry.path, isRefresh: false) }
            } else {
                previewEntry = entry
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.iconName(for: entry))
                    .font(.title3)
                    .foregroundStyle(entry.isDirectory ? theme.accentColor : Color.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    let subtitle = entrySubtitle(for: entry)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMutating)
    }

    private func entrySubtitle(for entry: SFTPEntry) -> String {
        var parts: [String] = []
        if !entry.isDirectory {
            parts.append(Self.byteFormatter.string(fromByteCount: Int64(clamping: entry.size)))
        } else {
            parts.append("Folder")
        }
        if entry.isSymlink {
            parts.append("Symlink")
        }
        if let modifiedAt = entry.modifiedAt {
            parts.append(Self.relativeDateFormatter.localizedString(for: modifiedAt, relativeTo: .now))
        }
        return parts.joined(separator: " · ")
    }

    private func beginRename(_ entry: SFTPEntry) {
        renamingEntry = entry
        renameText = entry.name
        showingRenameAlert = true
    }

    private func loadInitialDirectory() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil

        do {
            let resolved = try await connection.sftpResolvePath(".")
            guard generation == loadGeneration else { return }
            currentPath = resolved
            let listing = try await connection.sftpListDirectory(path: resolved)
            guard generation == loadGeneration else { return }
            entries = listing
            isLoading = false
        } catch is CancellationError {
            if generation == loadGeneration {
                isLoading = false
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    private func loadDirectory(path: String, isRefresh: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        let targetPath = path.isEmpty ? "/" : path

        if !isRefresh {
            currentPath = targetPath
            entries = []
        }
        isLoading = true
        loadError = nil

        do {
            let listing = try await connection.sftpListDirectory(path: targetPath)
            guard generation == loadGeneration else { return }
            entries = listing
            isLoading = false
        } catch is CancellationError {
            if generation == loadGeneration {
                isLoading = false
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            if isRefresh && !entries.isEmpty {
                actionError = error.localizedDescription
            } else {
                loadError = error.localizedDescription
            }
        }
    }

    private func handleFileImport(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                let fileName = url.lastPathComponent
                guard !fileName.isEmpty else {
                    actionError = "Selected file has an invalid filename."
                    return
                }
                Task { await uploadFile(data: data, fileName: fileName) }
            } catch {
                actionError = "Could not read selected file: \(error.localizedDescription)"
            }
        case .failure(let error):
            actionError = "Could not import file: \(error.localizedDescription)"
        }
    }

    private func uploadFile(data: Data, fileName: String) async {
        guard !currentPath.isEmpty else { return }
        let targetDir = currentPath
        let remotePath = SFTPPath.join(targetDir, fileName)
        workingStatus = "Uploading \(fileName)…"
        defer { workingStatus = nil }

        do {
            try await connection.sftpUploadFile(data: data, remotePath: remotePath)
            AppHaptics.notify(.success)
            await loadDirectory(path: targetDir, isRefresh: true)
        } catch {
            AppHaptics.notify(.error)
            actionError = "Upload failed: \(error.localizedDescription)"
        }
    }

    private func createFolder(named rawName: String) async {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEntryName(trimmed) else {
            actionError = "Please enter a valid folder name without '/'."
            return
        }
        guard !currentPath.isEmpty else { return }
        let targetDir = currentPath
        let folderPath = SFTPPath.join(targetDir, trimmed)
        workingStatus = "Creating folder…"
        defer { workingStatus = nil }

        do {
            try await connection.sftpMakeDirectory(path: folderPath)
            AppHaptics.notify(.success)
            await loadDirectory(path: targetDir, isRefresh: true)
        } catch {
            AppHaptics.notify(.error)
            actionError = "Could not create folder: \(error.localizedDescription)"
        }
    }

    private func renameEntry(_ entry: SFTPEntry, to rawName: String) async {
        renamingEntry = nil
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEntryName(trimmed) else {
            actionError = "Please enter a valid name without '/'."
            return
        }
        guard trimmed != entry.name else { return }
        let destination = SFTPPath.join(SFTPPath.parent(of: entry.path), trimmed)
        workingStatus = "Renaming…"
        defer { workingStatus = nil }

        do {
            try await connection.sftpRename(from: entry.path, to: destination)
            AppHaptics.notify(.success)
            await loadDirectory(path: currentPath, isRefresh: true)
        } catch {
            AppHaptics.notify(.error)
            actionError = "Rename failed: \(error.localizedDescription)"
        }
    }

    private func deleteEntry(_ entry: SFTPEntry) async {
        workingStatus = "Deleting…"
        defer { workingStatus = nil }

        do {
            try await connection.sftpDelete(path: entry.path, isDirectory: entry.isDirectory)
            AppHaptics.notify(.warning)
            await loadDirectory(path: currentPath, isRefresh: true)
        } catch {
            AppHaptics.notify(.error)
            actionError = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func isValidEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    static func iconName(for entry: SFTPEntry) -> String {
        if entry.isDirectory {
            return "folder.fill"
        }
        let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
        if textExtensions.contains(ext) {
            return "doc.text"
        }
        if archiveExtensions.contains(ext) {
            return "doc.zipper"
        }
        if imageExtensions.contains(ext) {
            return "photo"
        }
        return "doc"
    }

    static func pathComponents(for path: String) -> [(name: String, path: String)] {
        if path == "/" || path.isEmpty {
            return [("/", "/")]
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var components: [(name: String, path: String)] = []
        var running = ""
        if path.hasPrefix("/") {
            components.append(("/", "/"))
            running = "/"
        }
        for part in parts {
            running = running == "/" ? "/\(part)" : (running.isEmpty ? part : "\(running)/\(part)")
            components.append((part, running))
        }
        return components
    }
}

/// Lightweight `FileDocument` wrapper for exporting downloaded SFTP data via `.fileExporter`.
struct SFTPExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// File detail / text preview / export sheet opened when tapping a remote file in `SFTPBrowserView`.
private struct SFTPFileDetailSheet: View {
    private static let previewByteLimit: UInt64 = 512 * 1024

    let entry: SFTPEntry
    let connection: SSHConnection

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var downloadedData: Data?
    @State private var previewText: String?
    @State private var isLoadingPreview = false
    @State private var isDownloadingForExport = false
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var exportDocument: SFTPExportDocument?
    @State private var isExporting = false
    @State private var didStartInitialLoad = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var canPreviewInline: Bool { entry.size <= Self.previewByteLimit }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if let previewText {
                    textPreviewContent(previewText)
                } else {
                    metadataView
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let previewText {
                        Button {
                            copyText(previewText)
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }

                    Button {
                        Task { await exportFile() }
                    } label: {
                        if isDownloadingForExport {
                            ProgressView()
                        } else {
                            Label("Download / Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isLoadingPreview || isDownloadingForExport)
                }
            }
            .task {
                guard !didStartInitialLoad else { return }
                didStartInitialLoad = true
                if canPreviewInline {
                    await loadInlinePreview()
                }
            }
            .onDisappear {
                copyResetTask?.cancel()
                copyResetTask = nil
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .data,
                defaultFilename: entry.name
            ) { result in
                switch result {
                case .success:
                    AppHaptics.notify(.success)
                case .failure(let error):
                    errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func textPreviewContent(_ text: String) -> some View {
        VStack(spacing: 0) {
            metadataBanner
            Divider()
            ScrollView {
                Text(text.isEmpty ? "(Empty file)" : text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(theme.backgroundColor)
        }
    }

    private var metadataBanner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Text(formattedSizeAndDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await exportFile() }
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDownloadingForExport)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var metadataView: some View {
        List {
            Section("File Details") {
                LabeledContent("Name", value: entry.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.path)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Size", value: Self.byteFormatter.string(fromByteCount: Int64(clamping: entry.size)))
                if entry.permissions != 0 {
                    LabeledContent("Permissions", value: String(format: "%04o", entry.permissions & 0o7777))
                }
                if let modifiedAt = entry.modifiedAt {
                    LabeledContent("Modified", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                if isLoadingPreview {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading preview…")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        if canPreviewInline {
                            Button("Retry") {
                                Task { await loadInlinePreview() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else if canPreviewInline {
                    Text("Binary file — inline text preview is not available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Files larger than 512 KB are not previewed inline. Download to view or save to Files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await exportFile() }
                } label: {
                    HStack {
                        Spacer()
                        if isDownloadingForExport {
                            ProgressView()
                                .padding(.trailing, 6)
                            Text("Downloading…")
                        } else {
                            Label("Download / Export…", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                    }
                    .fontWeight(.semibold)
                }
                .disabled(isLoadingPreview || isDownloadingForExport)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var formattedSizeAndDate: String {
        var parts = [Self.byteFormatter.string(fromByteCount: Int64(clamping: entry.size))]
        if let modifiedAt = entry.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private func loadInlinePreview() async {
        isLoadingPreview = true
        errorMessage = nil
        defer { isLoadingPreview = false }

        do {
            let data = try await connection.sftpDownloadFile(
                remotePath: entry.path,
                maxBytes: Int(Self.previewByteLimit)
            )
            downloadedData = data
            if !data.contains(0), let text = String(data: data, encoding: .utf8) {
                previewText = text
            } else {
                previewText = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportFile() async {
        if let downloadedData {
            exportDocument = SFTPExportDocument(data: downloadedData)
            isExporting = true
            return
        }

        isDownloadingForExport = true
        errorMessage = nil
        defer { isDownloadingForExport = false }

        do {
            let data = try await connection.sftpDownloadFile(remotePath: entry.path)
            downloadedData = data
            exportDocument = SFTPExportDocument(data: data)
            isExporting = true
        } catch {
            AppHaptics.notify(.error)
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    private func copyText(_ text: String) {
        UIPasteboard.general.string = text
        AppHaptics.notify(.success)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

private struct SFTPAlertsModifier: ViewModifier {
    let currentPath: String
    @Binding var showingNewFolderAlert: Bool
    @Binding var newFolderName: String
    @Binding var showingRenameAlert: Bool
    @Binding var renamingEntry: SFTPEntry?
    @Binding var renameText: String
    @Binding var deletingEntry: SFTPEntry?
    @Binding var actionError: String?
    let onCreateFolder: (String) -> Void
    let onRename: (SFTPEntry, String) -> Void
    let onDelete: (SFTPEntry) -> Void

    private var deleteConfirmationTitle: String {
        guard let entry = deletingEntry else { return "Delete item?" }
        return "Delete \"\(entry.name)\"?"
    }

    func body(content: Content) -> some View {
        content
            .alert("New Folder", isPresented: $showingNewFolderAlert) {
                TextField("Folder name", text: $newFolderName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Create") { onCreateFolder(newFolderName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Create a new directory inside \(currentPath).")
            }
            .alert(
                "Rename",
                isPresented: $showingRenameAlert,
                presenting: renamingEntry
            ) { entry in
                TextField("New name", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Rename") { onRename(entry, renameText) }
                Button("Cancel", role: .cancel) { renamingEntry = nil }
            } message: { entry in
                Text("Enter a new name for \"\(entry.name)\".")
            }
            .confirmationDialog(
                deleteConfirmationTitle,
                isPresented: Binding(
                    get: { deletingEntry != nil },
                    set: { if !$0 { deletingEntry = nil } }
                ),
                titleVisibility: .visible,
                presenting: deletingEntry
            ) { entry in
                Button("Delete", role: .destructive) { onDelete(entry) }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                if entry.isDirectory {
                    Text("This removes the empty directory \"\(entry.name)\" from the remote server.")
                } else {
                    Text("This permanently deletes \"\(entry.name)\" from the remote server.")
                }
            }
            .alert(
                "SFTP Error",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(actionError ?? "")
            }
    }
}
