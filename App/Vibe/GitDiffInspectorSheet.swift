import SwiftUI
import UIKit
import SSHKit
import Store
import TermUI

/// Sheet inspecting remote `git status` and unified diffs without interrupting the active terminal PTY.
struct GitDiffInspectorSheet: View {
    let live: LiveSession

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var directoryInput: String
    @State private var activeDirectory: String
    @State private var snapshot: GitRepoSnapshot?
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var expandedDiffPaths: Set<String> = []
    @State private var expandedUntrackedPaths: Set<String> = []
    @State private var copiedDiff = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var discardingFile: GitChangedFile?
    @State private var showingCommitSheet = false
    @State private var commitMessage = ""
    @State private var commitError: String?
    @State private var loadGeneration = 0
    @State private var didInitialLoad = false
    @FocusState private var isDirectoryFieldFocused: Bool

    init(live: LiveSession) {
        self.live = live
        let rawWorkingDir = live.aiAgentContext?.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialDir = rawWorkingDir.isEmpty ? "~" : rawWorkingDir
        _directoryInput = State(initialValue: initialDir)
        _activeDirectory = State(initialValue: initialDir)
    }

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    private var diffsByPath: [String: GitFileDiff] {
        guard let snapshot else { return [:] }
        return Dictionary(snapshot.diffs.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var totalAdditions: Int {
        snapshot?.diffs.reduce(0) { $0 + $1.additions } ?? 0
    }

    private var totalDeletions: Int {
        snapshot?.diffs.reduce(0) { $0 + $1.deletions } ?? 0
    }

    private var repoActionDirectory: String {
        if let root = snapshot?.repoRoot.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            return root
        }
        return activeDirectory
    }

    private var hasDirectoryEdits: Bool {
        normalizedDirectory(directoryInput) != activeDirectory
    }

    private var canCommit: Bool {
        guard let snapshot, snapshot.isGitRepo, !snapshot.files.isEmpty else { return false }
        return !isLoading && !isMutating
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let snapshot, snapshot.isGitRepo {
                        repoSummarySection(snapshot)

                        if !snapshot.files.isEmpty {
                            changedFilesSection(snapshot, scrollProxy: proxy)
                            diffViewerSection(snapshot)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaInset(edge: .top, spacing: 0) {
                    directoryBar
                }
                .overlay {
                    stateOverlay
                }
                .refreshable {
                    await reloadSnapshot(preserveExpansions: true)
                }
            }
            .navigationTitle("Git Diff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        AppHaptics.impact(.light)
                        Task { await reloadSnapshot(preserveExpansions: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || isMutating)

                    Button {
                        copyRawDiff()
                    } label: {
                        Label(
                            copiedDiff ? "Copied" : "Copy Diff",
                            systemImage: copiedDiff ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled((snapshot?.rawDiff.isEmpty ?? true) || isLoading)
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        AppHaptics.impact(.light)
                        commitError = nil
                        showingCommitSheet = true
                    } label: {
                        Label("Commit All…", systemImage: "checkmark.circle.fill")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(!canCommit)
                }
            }
            .task {
                guard !didInitialLoad else { return }
                didInitialLoad = true
                await reloadSnapshot(preserveExpansions: false)
            }
            .onDisappear {
                copyResetTask?.cancel()
                copyResetTask = nil
            }
            .sheet(isPresented: $showingCommitSheet) {
                commitSheet
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                    .tint(theme.accentColor)
            }
            .confirmationDialog(
                "Discard file changes?",
                isPresented: Binding(get: { discardingFile != nil }, set: { if !$0 { discardingFile = nil } }),
                titleVisibility: .visible,
                presenting: discardingFile
            ) { file in
                Button(file.isUntracked ? "Delete Untracked File" : "Discard Changes", role: .destructive) {
                    Task { await discardChanges(for: file) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { file in
                if file.isUntracked {
                    Text("This permanently deletes untracked file \"\(file.path)\" on the remote host.")
                } else {
                    Text("This reverts all uncommitted changes to \"\(file.path)\" back to HEAD.")
                }
            }
            .alert(
                "Git Action Failed",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    // MARK: - Directory Bar & Summary

    private var directoryBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)

                TextField("Repository path (e.g. ~/projects/app)", text: $directoryInput)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isDirectoryFieldFocused)
                    .onSubmit {
                        applyDirectoryChange()
                    }

                if hasDirectoryEdits {
                    Button("Load") {
                        applyDirectoryChange()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(palette.accent)
                    .disabled(isLoading || isMutating)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()
        }
    }

    private func repoSummarySection(_ snapshot: GitRepoSnapshot) -> some View {
        Section {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption.weight(.semibold))
                    Text(snapshot.branch.isEmpty ? "HEAD" : snapshot.branch)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    palette.pillFill(for: palette.accent),
                    in: Capsule()
                )

                if totalAdditions > 0 || totalDeletions > 0 {
                    HStack(spacing: 6) {
                        Text("+\(totalAdditions)")
                            .foregroundStyle(palette.healthy)
                        Text("-\(totalDeletions)")
                            .foregroundStyle(palette.critical)
                    }
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                }

                Spacer()

                Text("\(snapshot.files.count) \(snapshot.files.count == 1 ? "file" : "files")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            if !snapshot.repoRoot.isEmpty {
                Text(snapshot.repoRoot)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    // MARK: - Changed Files & Diff Viewer

    private func changedFilesSection(_ snapshot: GitRepoSnapshot, scrollProxy: ScrollViewProxy) -> some View {
        Section("Changed Files (\(snapshot.files.count))") {
            ForEach(snapshot.files) { file in
                let matchingDiff = diffsByPath[file.path]
                let isUntrackedExpanded = expandedUntrackedPaths.contains(file.path)

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        AppHaptics.impact(.light)
                        if matchingDiff != nil {
                            expandedDiffPaths.insert(file.path)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo(diffAnchorID(for: file.path), anchor: .top)
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if isUntrackedExpanded {
                                    expandedUntrackedPaths.remove(file.path)
                                } else {
                                    expandedUntrackedPaths.insert(file.path)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            statusBadge(for: file)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if file.isStaged {
                                    Text("Staged")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 6)

                            if let matchingDiff {
                                HStack(spacing: 5) {
                                    if matchingDiff.additions > 0 {
                                        Text("+\(matchingDiff.additions)")
                                            .foregroundStyle(palette.healthy)
                                    }
                                    if matchingDiff.deletions > 0 {
                                        Text("-\(matchingDiff.deletions)")
                                            .foregroundStyle(palette.critical)
                                    }
                                }
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                            } else if file.isUntracked {
                                Text("New")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(palette.healthy)
                            }

                            Image(systemName: matchingDiff != nil ? "arrow.down.to.line.compact" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isMutating)

                    if isUntrackedExpanded && matchingDiff == nil {
                        Text(file.isUntracked
                             ? "Untracked file — included when you tap Commit All."
                             : "No line diff available against HEAD.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 34)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        insertPathInPrompt(file.path)
                    } label: {
                        Label("Prompt", systemImage: "text.badge.plus")
                    }
                    .tint(palette.accent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        discardingFile = file
                    } label: {
                        Label("Discard", systemImage: "arrow.uturn.backward")
                    }
                }
                .contextMenu {
                    if matchingDiff != nil {
                        Button("Jump to Diff", systemImage: "doc.text.magnifyingglass") {
                            expandedDiffPaths.insert(file.path)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo(diffAnchorID(for: file.path), anchor: .top)
                            }
                        }
                    }
                    Button("Insert Path in Agent Prompt", systemImage: "text.badge.plus") {
                        insertPathInPrompt(file.path)
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = file.path
                        AppHaptics.notify(.success)
                    }
                    Divider()
                    Button(
                        file.isUntracked ? "Delete File" : "Discard Changes",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        discardingFile = file
                    }
                }
            }
        }
    }

    private func diffViewerSection(_ snapshot: GitRepoSnapshot) -> some View {
        Section("Unified Diff") {
            if snapshot.diffs.isEmpty {
                Text("No tracked diff lines against HEAD. Untracked files can still be committed with Commit All.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.diffs) { fileDiff in
                    fileDiffRow(fileDiff)
                        .id(diffAnchorID(for: fileDiff.path))
                }
            }
        }
    }

    private func fileDiffRow(_ fileDiff: GitFileDiff) -> some View {
        let isExpanded = expandedDiffPaths.contains(fileDiff.path)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                AppHaptics.impact(.light)
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedDiffPaths.remove(fileDiff.path)
                    } else {
                        expandedDiffPaths.insert(fileDiff.path)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(fileDiff.path)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    HStack(spacing: 5) {
                        if fileDiff.additions > 0 {
                            Text("+\(fileDiff.additions)")
                                .foregroundStyle(palette.healthy)
                        }
                        if fileDiff.deletions > 0 {
                            Text("-\(fileDiff.deletions)")
                                .foregroundStyle(palette.critical)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Insert Path in Agent Prompt", systemImage: "text.badge.plus") {
                    insertPathInPrompt(fileDiff.path)
                }
                Button("Copy Path", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = fileDiff.path
                    AppHaptics.notify(.success)
                }
            }

            if isExpanded {
                diffLinesBlock(fileDiff.lines)
            }
        }
        .padding(.vertical, 2)
    }

    private func diffLinesBlock(_ lines: [GitDiffLine]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(diffLineForeground(for: line.kind))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(diffLineBackground(for: line.kind))
                }
            }
            .textSelection(.enabled)
        }
        .background(
            palette.isDark ? Color.black.opacity(0.32) : Color.black.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    palette.borderSubtle,
                    lineWidth: 0.75
                )
        )
    }

    private func statusBadge(for file: GitChangedFile) -> some View {
        let tint = badgeColor(for: file)
        return Text(file.displayBadge)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .foregroundStyle(tint)
            .frame(minWidth: 24)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(palette.badgeFill(for: tint), in: RoundedRectangle(cornerRadius: ProDesign.Radius.tagChip, style: .continuous))
    }

    private func badgeColor(for file: GitChangedFile) -> Color {
        switch file.displayBadge {
        case "A", "??": palette.healthy
        case "D": palette.critical
        case "R": palette.running
        default: palette.accent
        }
    }

    private func diffLineForeground(for kind: GitDiffLineKind) -> Color {
        switch kind {
        case .added: palette.healthy
        case .removed: palette.critical
        case .hunk: palette.running
        case .header: .secondary
        case .context: .primary
        }
    }

    private func diffLineBackground(for kind: GitDiffLineKind) -> Color {
        switch kind {
        case .added: palette.healthy.opacity(palette.isDark ? 0.16 : 0.11)
        case .removed: palette.critical.opacity(palette.isDark ? 0.16 : 0.11)
        case .hunk: palette.running.opacity(palette.isDark ? 0.14 : 0.09)
        case .header: Color.secondary.opacity(palette.isDark ? 0.10 : 0.06)
        case .context: .clear
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if isMutating {
            ZStack {
                Color.black.opacity(0.24).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Updating repository…")
                        .font(.subheadline.weight(.medium))
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        } else if isLoading && snapshot == nil {
            ProgressView("Loading git status…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, snapshot == nil {
            ContentUnavailableView {
                Label("Could Not Inspect Repository", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") {
                    Task { await reloadSnapshot(preserveExpansions: false) }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
            }
        } else if let snapshot, !snapshot.isGitRepo {
            ContentUnavailableView {
                Label("Not a Git Repository", systemImage: "folder.badge.questionmark")
            } description: {
                Text("No Git repository was found at \"\(activeDirectory)\".")
            } actions: {
                Button("Retry") {
                    Task { await reloadSnapshot(preserveExpansions: false) }
                }
                .buttonStyle(.bordered)
            }
        } else if let snapshot, snapshot.isGitRepo, snapshot.files.isEmpty {
            ContentUnavailableView {
                Label("Working Tree Clean", systemImage: "checkmark.circle")
            } description: {
                Text("No uncommitted changes on branch \"\(snapshot.branch.isEmpty ? "HEAD" : snapshot.branch)\".")
            }
        }
    }

    // MARK: - Commit Sheet

    private var commitSheet: some View {
        let trimmedMessage = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileCount = snapshot?.files.count ?? 0
        let branchLabel = snapshot?.branch.isEmpty == false ? snapshot!.branch : "HEAD"

        return NavigationStack {
            Form {
                Section {
                    TextField("Describe your changes…", text: $commitMessage, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("Commit Message")
                } footer: {
                    Text("Runs git add -A && git commit for \(fileCount) \(fileCount == 1 ? "file" : "files") on \(branchLabel).")
                }

                if let commitError {
                    Section {
                        Text(commitError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Commit All")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCommitSheet = false }
                        .disabled(isMutating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await commitAll(message: trimmedMessage) }
                    } label: {
                        if isMutating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Commit")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(trimmedMessage.isEmpty || isMutating)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Actions

    private func diffAnchorID(for path: String) -> String {
        "diff-\(path)"
    }

    private func normalizedDirectory(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    private func applyDirectoryChange() {
        isDirectoryFieldFocused = false
        let next = normalizedDirectory(directoryInput)
        directoryInput = next
        activeDirectory = next
        snapshot = nil
        expandedDiffPaths = []
        expandedUntrackedPaths = []
        loadError = nil
        Task { await reloadSnapshot(preserveExpansions: false) }
    }

    private func reloadSnapshot(preserveExpansions: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil

        let targetDir = activeDirectory
        do {
            let result = try await live.session.exec(
                GitDiffHelper.statusAndDiffCommand(in: targetDir),
                timeout: .seconds(15)
            )
            guard !Task.isCancelled, generation == loadGeneration else { return }

            let parsed = GitDiffHelper.parseSnapshot(from: result.stdout)
            snapshot = parsed
            isLoading = false

            let validPaths = Set(parsed.diffs.map(\.path))
            if preserveExpansions {
                expandedDiffPaths.formIntersection(validPaths)
                if expandedDiffPaths.isEmpty {
                    expandedDiffPaths = defaultExpandedPaths(for: parsed.diffs)
                }
            } else {
                expandedDiffPaths = defaultExpandedPaths(for: parsed.diffs)
                expandedUntrackedPaths = []
            }
        } catch is CancellationError {
            if generation == loadGeneration {
                isLoading = false
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            if !preserveExpansions || snapshot == nil {
                snapshot = nil
                loadError = error.localizedDescription
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    private func insertPathInPrompt(_ path: String) {
        live.aiPromptDraft = RemoteAttachmentHelper.promptInsertion(
            forRemotePath: path,
            existingPrompt: live.aiPromptDraft
        )
        if !live.showAIAgentControls {
            live.showAIAgentControls = true
        }
        AppHaptics.notify(.success)
        dismiss()
    }

    private func defaultExpandedPaths(for diffs: [GitFileDiff]) -> Set<String> {
        if diffs.count <= 6 {
            return Set(diffs.map(\.path))
        }
        return diffs.first.map { Set([$0.path]) } ?? []
    }

    private func copyRawDiff() {
        guard let rawDiff = snapshot?.rawDiff, !rawDiff.isEmpty else { return }
        UIPasteboard.general.string = rawDiff
        AppHaptics.notify(.success)
        copiedDiff = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedDiff = false
        }
    }

    private func discardChanges(for file: GitChangedFile) async {
        discardingFile = nil
        isMutating = true
        defer { isMutating = false }

        do {
            let result = try await live.session.exec(
                GitDiffHelper.discardFileCommand(
                    in: repoActionDirectory,
                    path: file.path,
                    isUntracked: file.isUntracked
                ),
                timeout: .seconds(15)
            )
            guard result.exitCode == 0 else {
                AppHaptics.notify(.error)
                actionError = conciseCommandError(from: result, fallback: "Could not discard \(file.path).")
                return
            }
            AppHaptics.notify(.warning)
            await reloadSnapshot(preserveExpansions: true)
        } catch {
            AppHaptics.notify(.error)
            actionError = error.localizedDescription
        }
    }

    private func commitAll(message: String) async {
        guard !message.isEmpty else { return }
        isMutating = true
        commitError = nil
        defer { isMutating = false }

        do {
            let result = try await live.session.exec(
                GitDiffHelper.stageAndCommitCommand(in: repoActionDirectory, message: message),
                timeout: .seconds(20)
            )
            guard result.exitCode == 0 else {
                AppHaptics.notify(.error)
                commitError = conciseCommandError(from: result, fallback: "Commit failed (exit code \(result.exitCode)).")
                return
            }
            AppHaptics.notify(.success)
            commitMessage = ""
            showingCommitSheet = false
            await reloadSnapshot(preserveExpansions: false)
        } catch {
            AppHaptics.notify(.error)
            commitError = error.localizedDescription
        }
    }

    private func conciseCommandError(from result: SSHExecResult, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return fallback
    }
}
