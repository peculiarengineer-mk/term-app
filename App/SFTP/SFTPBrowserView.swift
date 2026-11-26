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

    @State private var rootPath = ""
    @State private var navigationPath: [String] = []
    @State private var directoryRefreshTokens: [String: Int] = [:]
    @State private var workingStatus: String?
    @State private var activeTransferTask: Task<Void, Never>?
    @State private var mutationGeneration = 0
    @State private var previewEntry: SFTPEntry?
    @State private var showingImporter = false
    @State private var importerTargetDirectory = ""
    @State private var showingNewFolderAlert = false
    @State private var newFolderTargetDirectory = ""
    @State private var newFolderName = ""
    @State private var renamingEntry: SFTPEntry?
    @State private var renameSourceDirectory = ""
    @State private var renameText = ""
    @State private var showingRenameAlert = false
    @State private var deletingEntry: SFTPEntry?
    @State private var deleteSourceDirectory = ""
    @State private var actionError: String?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }
    private var isMutating: Bool { workingStatus != nil }

    private static let textExtensions: Set<String> = [
        "log", "txt", "md", "markdown", "json", "yml", "yaml", "swift", "py", "sh",
        "bash", "zsh", "js", "ts", "jsx", "tsx", "html", "css", "xml", "toml", "ini",
        "conf", "cfg", "env", "c", "h", "cpp", "hpp", "rs", "go", "rb", "java", "kt",
        "sql", "csv",
    ]

    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz4", "dmg", "pkg", "deb", "rpm",
    ]

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "bmp", "tiff", "ico", "raw",
    ]

    var body: some View {
        NavigationStack(path: $navigationPath) {
            directoryScreen(path: rootPath, isRoot: true)
                .navigationDestination(for: String.self) { path in
                    directoryScreen(path: path, isRoot: false)
                }
        }
        .overlay {
            workingStatusOverlay
        }
        .sheet(item: $previewEntry) { entry in
            SFTPFileDetailSheet(entry: entry, connection: connection)
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(palette.accent)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item]
        ) { result in
            handleFileImport(result, targetDirectory: importerTargetDirectory)
        }
        .modifier(
            SFTPAlertsModifier(
                currentPath: newFolderTargetDirectory,
                showingNewFolderAlert: $showingNewFolderAlert,
                newFolderName: $newFolderName,
                showingRenameAlert: $showingRenameAlert,
                renamingEntry: $renamingEntry,
                renameText: $renameText,
                deletingEntry: $deletingEntry,
                actionError: $actionError,
                onCreateFolder: { name in createFolder(named: name, in: newFolderTargetDirectory) },
                onRename: { entry, name in renameEntry(entry, to: name, in: renameSourceDirectory) },
                onDelete: { entry in deleteEntry(entry, in: deleteSourceDirectory) }
            )
        )
        .onDisappear {
            activeTransferTask?.cancel()
            activeTransferTask = nil
        }
    }

    private func directoryScreen(path: String, isRoot: Bool) -> some View {
        SFTPDirectoryView(
            directoryPath: path,
            isRoot: isRoot,
            hostTitle: hostTitle,
            connection: connection,
            theme: theme,
            isMutating: isMutating,
            refreshToken: directoryRefreshTokens[path] ?? 0,
            onResolvedRootPath: { resolved in
                rootPath = resolved
            },
            onNavigateToDirectory: { targetPath in
                navigateToDirectory(targetPath)
            },
            onPreviewFile: { entry in
                previewEntry = entry
            },
            onNewFolder: { targetDir in
                newFolderTargetDirectory = targetDir
                newFolderName = ""
                showingNewFolderAlert = true
            },
            onUploadFile: { targetDir in
                importerTargetDirectory = targetDir
                showingImporter = true
            },
            onRenameEntry: { entry, currentDir in
                renameSourceDirectory = currentDir
                renamingEntry = entry
                renameText = entry.name
                showingRenameAlert = true
            },
            onDeleteEntry: { entry, currentDir in
                deleteSourceDirectory = currentDir
                deletingEntry = entry
            },
            onActionError: { message in
                actionError = message
            },
            onDismiss: {
                dismiss()
            }
        )
    }

    @ViewBuilder
    private var workingStatusOverlay: some View {
        if let workingStatus {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text(workingStatus)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Button("Cancel", role: .cancel) {
                        cancelActiveTransfer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .minTapTarget()
                }
                .padding(22)
                .frame(maxWidth: ProDesign.Layout.readableOverlayWidth)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: ProDesign.Radius.card, style: .continuous)
                )
                .padding(.horizontal, 24)
            }
        }
    }

    private func navigateToDirectory(_ targetPath: String) {
        let normalized = targetPath.isEmpty ? "/" : targetPath
        if normalized == rootPath {
            navigationPath.removeAll()
        } else if let index = navigationPath.firstIndex(of: normalized) {
            navigationPath = Array(navigationPath.prefix(index + 1))
        } else {
            rootPath = normalized
            navigationPath.removeAll()
        }
    }

    private func triggerRefresh(for directory: String) {
        directoryRefreshTokens[directory, default: 0] += 1
    }

    private func cancelActiveTransfer() {
        AppHaptics.impact(.light)
        mutationGeneration += 1
        activeTransferTask?.cancel()
        activeTransferTask = nil
        workingStatus = nil
    }

    private func startMutation(
        status: String,
        failurePrefix: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        activeTransferTask?.cancel()
        mutationGeneration += 1
        let generation = mutationGeneration
        workingStatus = status

        activeTransferTask = Task { @MainActor in
            defer {
                if generation == mutationGeneration {
                    workingStatus = nil
                    activeTransferTask = nil
                }
            }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == mutationGeneration else { return }
                AppHaptics.notify(.error)
                actionError = "\(failurePrefix): \(error.localizedDescription)"
            }
        }
    }

    private func handleFileImport(_ result: Result<URL, any Error>, targetDirectory: String) {
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
                uploadFile(data: data, fileName: fileName, in: targetDirectory)
            } catch {
                actionError = "Could not read selected file: \(error.localizedDescription)"
            }
        case .failure(let error):
            actionError = "Could not import file: \(error.localizedDescription)"
        }
    }

    private func uploadFile(data: Data, fileName: String, in targetDir: String) {
        guard !targetDir.isEmpty else { return }
        let remotePath = SFTPPath.join(targetDir, fileName)
        startMutation(status: "Uploading \(fileName)…", failurePrefix: "Upload failed") {
            try await connection.sftpUploadFile(data: data, remotePath: remotePath)
            guard !Task.isCancelled else { return }
            AppHaptics.notify(.success)
            triggerRefresh(for: targetDir)
        }
    }

    private func createFolder(named rawName: String, in targetDir: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEntryName(trimmed) else {
            actionError = "Please enter a valid folder name without '/'."
            return
        }
        guard !targetDir.isEmpty else { return }
        let folderPath = SFTPPath.join(targetDir, trimmed)
        startMutation(status: "Creating folder…", failurePrefix: "Could not create folder") {
            try await connection.sftpMakeDirectory(path: folderPath)
            guard !Task.isCancelled else { return }
            AppHaptics.notify(.success)
            triggerRefresh(for: targetDir)
        }
    }

    private func renameEntry(_ entry: SFTPEntry, to rawName: String, in targetDir: String) {
        renamingEntry = nil
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEntryName(trimmed) else {
            actionError = "Please enter a valid name without '/'."
            return
        }
        guard trimmed != entry.name else { return }
        let destination = SFTPPath.join(SFTPPath.parent(of: entry.path), trimmed)
        startMutation(status: "Renaming…", failurePrefix: "Rename failed") {
            try await connection.sftpRename(from: entry.path, to: destination)
            guard !Task.isCancelled else { return }
            AppHaptics.notify(.success)
            triggerRefresh(for: targetDir)
        }
    }

    private func deleteEntry(_ entry: SFTPEntry, in targetDir: String) {
        startMutation(status: "Deleting…", failurePrefix: "Delete failed") {
            try await connection.sftpDelete(path: entry.path, isDirectory: entry.isDirectory)
            guard !Task.isCancelled else { return }
            AppHaptics.notify(.warning)
            triggerRefresh(for: targetDir)
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

/// Directory listing page pushed on `SFTPBrowserView`'s `NavigationStack` for native swipe-back navigation.
private struct SFTPDirectoryView: View {
    let directoryPath: String
    let isRoot: Bool
    let hostTitle: String
    let connection: SSHConnection
    let theme: TerminalTheme
    let isMutating: Bool
    let refreshToken: Int
    let onResolvedRootPath: (String) -> Void
    let onNavigateToDirectory: (String) -> Void
    let onPreviewFile: (SFTPEntry) -> Void
    let onNewFolder: (String) -> Void
    let onUploadFile: (String) -> Void
    let onRenameEntry: (SFTPEntry, String) -> Void
    let onDeleteEntry: (SFTPEntry, String) -> Void
    let onActionError: (String) -> Void
    let onDismiss: () -> Void

    @State private var loadedPath = ""
    @State private var entries: [SFTPEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadGeneration = 0
    @State private var searchQuery = ""

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

    private var palette: ProDesign.Palette {
        ProDesign.Palette(theme: theme)
    }

    private var displayPath: String {
        if !directoryPath.isEmpty {
            return directoryPath
        }
        return loadedPath
    }

    private var navigationTitleText: String {
        if isRoot {
            return hostTitle.isEmpty ? "SFTP Files" : hostTitle
        }
        let leaf = URL(fileURLWithPath: displayPath).lastPathComponent
        return leaf.isEmpty ? "/" : leaf
    }

    private var filteredEntries: [SFTPEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(filteredEntries) { entry in
                entryRowView(entry)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchQuery, prompt: "Filter files")
        .safeAreaInset(edge: .top, spacing: 0) {
            if !displayPath.isEmpty {
                breadcrumbBar(for: displayPath)
            }
        }
        .overlay {
            stateOverlay
        }
        .refreshable {
            if displayPath.isEmpty {
                await loadInitialDirectory()
            } else {
                await loadDirectory(path: displayPath, isRefresh: true)
            }
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    AppHaptics.impact(.light)
                    onNewFolder(displayPath)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(displayPath.isEmpty || isLoading || isMutating)

                Button {
                    AppHaptics.impact(.light)
                    onUploadFile(displayPath)
                } label: {
                    Label("Upload File", systemImage: "arrow.up.doc")
                }
                .disabled(displayPath.isEmpty || isLoading || isMutating)
            }
        }
        .task(id: directoryPath) {
            if directoryPath.isEmpty {
                guard loadedPath.isEmpty else { return }
                await loadInitialDirectory()
            } else {
                guard loadedPath != directoryPath else { return }
                await loadDirectory(path: directoryPath, isRefresh: false)
            }
        }
        .onChange(of: refreshToken) { _, _ in
            guard !displayPath.isEmpty else { return }
            Task { await loadDirectory(path: displayPath, isRefresh: true) }
        }
    }

    private func entryRowView(_ entry: SFTPEntry) -> some View {
        entryRow(entry)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    onDeleteEntry(entry, displayPath)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    onRenameEntry(entry, displayPath)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.blue)
            }
            .contextMenu {
                if !entry.isDirectory {
                    Button("Preview / Download", systemImage: "doc.text.magnifyingglass") {
                        onPreviewFile(entry)
                    }
                }
                Button("Rename", systemImage: "pencil") {
                    onRenameEntry(entry, displayPath)
                }
                Button("Copy Path", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = entry.path
                    AppHaptics.notify(.success)
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    onDeleteEntry(entry, displayPath)
                }
            }
    }

    @ViewBuilder
    private func entryRow(_ entry: SFTPEntry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: entry.path) {
                entryLabelContent(entry)
            }
            .disabled(isMutating)
        } else {
            Button {
                AppHaptics.impact(.light)
                onPreviewFile(entry)
            } label: {
                entryLabelContent(entry)
            }
            .buttonStyle(.plain)
            .disabled(isMutating)
        }
    }

    private func entryLabelContent(_ entry: SFTPEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: SFTPBrowserView.iconName(for: entry))
                .font(.title3)
                .foregroundStyle(entry.isDirectory ? palette.accent : Color.secondary)
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
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if isLoading && entries.isEmpty {
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
                        if displayPath.isEmpty {
                            await loadInitialDirectory()
                        } else {
                            await loadDirectory(path: displayPath, isRefresh: false)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
            }
        } else if !isLoading && entries.isEmpty && !displayPath.isEmpty {
            ContentUnavailableView {
                Label("Empty Directory", systemImage: "folder")
            } description: {
                Text("There are no files in \(displayPath).")
            }
        } else if !isLoading && !entries.isEmpty && filteredEntries.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
        }
    }

    private func breadcrumbBar(for path: String) -> some View {
        let components = SFTPBrowserView.pathComponents(for: path)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if path != "/" {
                    Button {
                        AppHaptics.impact(.light)
                        let parent = SFTPPath.parent(of: path)
                        onNavigateToDirectory(parent)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.up.left")
                                .font(.caption2.weight(.semibold))
                            Text("..")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(palette.accent)
                        .background(
                            palette.pillFill(for: palette.accent),
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

                                let isCurrent = component.path == path
                                Button {
                                    guard !isCurrent else { return }
                                    AppHaptics.impact(.light)
                                    onNavigateToDirectory(component.path)
                                } label: {
                                    Text(component.name)
                                        .font(.system(.caption, design: .monospaced).weight(isCurrent ? .semibold : .regular))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .foregroundStyle(isCurrent ? palette.accent : Color.primary)
                                        .background(
                                            isCurrent
                                                ? palette.pillFill(for: palette.accent)
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
                    .onChange(of: path) { _, newPath in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(newPath, anchor: .trailing)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(path, anchor: .trailing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(.bar)

            Divider()
        }
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

    private func loadInitialDirectory() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil

        do {
            let resolved = try await connection.sftpResolvePath(".")
            guard !Task.isCancelled, generation == loadGeneration else { return }
            let listing = try await connection.sftpListDirectory(path: resolved)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            loadedPath = resolved
            entries = listing
            isLoading = false
            onResolvedRootPath(resolved)
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
            loadedPath = targetPath
            entries = []
        }
        isLoading = true
        loadError = nil

        do {
            let listing = try await connection.sftpListDirectory(path: targetPath)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            loadedPath = targetPath
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
                onActionError(error.localizedDescription)
            } else {
                loadError = error.localizedDescription
            }
        }
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

/// File detail / image & text preview / export sheet opened when tapping a remote file in `SFTPBrowserView`.
private struct SFTPFileDetailSheet: View {
    private static let textPreviewByteLimit: UInt64 = 512 * 1024
    private static let imagePreviewByteLimit: UInt64 = 5 * 1024 * 1024

    let entry: SFTPEntry
    let connection: SSHConnection

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var downloadedData: Data?
    @State private var previewImage: UIImage?
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
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }
    private var fileExtension: String { URL(fileURLWithPath: entry.name).pathExtension.lowercased() }
    private var isImageFile: Bool { SFTPBrowserView.imageExtensions.contains(fileExtension) }
    private var previewByteLimit: UInt64 { isImageFile ? Self.imagePreviewByteLimit : Self.textPreviewByteLimit }
    private var canPreviewInline: Bool { entry.size <= previewByteLimit }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if let previewImage {
                    imagePreviewContent(previewImage)
                } else if let previewText {
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

    private func imagePreviewContent(_ image: UIImage) -> some View {
        VStack(spacing: 0) {
            metadataBanner
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: ProDesign.Radius.innerCard, style: .continuous))
                        .padding(14)
                        .background(
                            Color(red: 0x0E / 255.0, green: 0x10 / 255.0, blue: 0x15 / 255.0),
                            in: RoundedRectangle(cornerRadius: ProDesign.Radius.card, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ProDesign.Radius.card, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )

                    Text("\(Int((image.size.width * image.scale).rounded())) × \(Int((image.size.height * image.scale).rounded())) px")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
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
                            .foregroundStyle(palette.critical)
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
                    Text("Files larger than \(Self.byteFormatter.string(fromByteCount: Int64(previewByteLimit))) are not previewed inline. Download to view or save to Files.")
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
                maxBytes: Int(previewByteLimit)
            )
            downloadedData = data
            if isImageFile, let image = UIImage(data: data) {
                previewImage = image
                previewText = nil
            } else if !data.contains(0), let text = String(data: data, encoding: .utf8) {
                previewImage = nil
                previewText = text
            } else {
                previewImage = nil
                previewText = nil
            }
        } catch is CancellationError {
            return
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
