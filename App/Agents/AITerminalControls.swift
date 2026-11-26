import PhotosUI
import SwiftUI
import SSHKit
import Store
import TermUI

/// Docked mobile AI controls shown over/below the terminal for AI agent sessions or when toggled via Session Tools.
struct AITerminalControlsOverlay: View {
    @Bindable var live: LiveSession
    let theme: TerminalTheme
    var onOpenGitDiff: (() -> Void)? = nil
    var onOpenDevPreview: (() -> Void)? = nil

    @State private var isComposerExpanded = false
    @State private var isUploadingPhoto = false
    @State private var photoUploadError: String?
    @State private var showingGitDiff = false
    @State private var showingDevPreview = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var isComposerAwaitingInitialFocus = false
    @State private var composerFocusTask: Task<Void, Never>?
    @FocusState private var isComposerFocused: Bool

    private var palette: ProDesign.Palette {
        ProDesign.Palette(theme: theme)
    }

    private var accentTint: Color {
        if let context = live.aiAgentContext {
            return AgentVisuals.agentTint(for: context.agent)
        }
        return AgentVisuals.appleProAmber
    }

    private var isConnected: Bool {
        live.connectionStatus == .connected
    }

    private var canUseSSH: Bool {
        isConnected && live.session is SSHConnection
    }

    private var hasDraft: Bool {
        !live.aiPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showNoTmuxNotice: Bool {
        live.aiAgentContext != nil && !live.isTmuxBacked && !live.tmuxNoticeDismissed
    }

    var body: some View {
        VStack(spacing: 0) {
            if showNoTmuxNotice {
                noTmuxNoticeStrip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isComposerExpanded {
                AIPromptComposerView(
                    prompt: $live.aiPromptDraft,
                    isFieldFocused: $isComposerFocused,
                    agentName: live.aiAgentContext?.agent.name,
                    accentTint: accentTint,
                    isConnected: isConnected,
                    canUploadPhoto: canUseSSH,
                    isUploadingPhoto: isUploadingPhoto,
                    photoUploadError: photoUploadError,
                    theme: theme,
                    onPickPhoto: { item in
                        uploadPhoto(item)
                    },
                    onDismissPhotoError: {
                        photoUploadError = nil
                    },
                    onSend: {
                        sendBracketedPrompt(submit: true)
                    },
                    onPaste: {
                        sendBracketedPrompt(submit: false)
                    },
                    onDismissComposer: {
                        collapseComposer()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            AIQuickActionBar(
                accentTint: accentTint,
                isComposerExpanded: isComposerExpanded,
                hasDraft: hasDraft,
                isConnected: isConnected,
                canPreview: canUseSSH,
                theme: theme,
                onSendText: { sequence in
                    sendRaw(sequence)
                },
                onOpenGitDiff: {
                    AppHaptics.impact(.light)
                    if let onOpenGitDiff {
                        onOpenGitDiff()
                    } else {
                        showingGitDiff = true
                    }
                },
                onOpenPreview: {
                    AppHaptics.impact(.light)
                    if let onOpenDevPreview {
                        onOpenDevPreview()
                    } else {
                        showingDevPreview = true
                    }
                },
                onToggleComposer: {
                    AppHaptics.impact(.light)
                    if isComposerExpanded {
                        collapseComposer()
                    } else {
                        expandComposer()
                    }
                }
            )
        }
        .sheet(isPresented: $showingGitDiff) {
            GitDiffInspectorSheet(live: live)
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
        }
        .sheet(isPresented: $showingDevPreview) {
            DevServerPreviewSheet(live: live)
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(theme.accentColor)
        }
        .onChange(of: isComposerFocused) { _, focused in
            if focused {
                isComposerAwaitingInitialFocus = false
                composerFocusTask?.cancel()
                composerFocusTask = nil
            }
        }
        .onChange(of: live.terminalFocusSequence) { _, _ in
            if isComposerExpanded && !isComposerAwaitingInitialFocus {
                collapseComposer()
            }
        }
        .onChange(of: live.directInputSequence) { _, _ in
            if isComposerExpanded && !isComposerFocused {
                collapseComposer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            collapseIfTerminalKeyboardActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            collapseIfTerminalKeyboardActive()
        }
        .onChange(of: showingGitDiff || showingDevPreview) { _, isPresented in
            live.hasInlineModalPresented = isPresented
        }
        .onDisappear {
            uploadTask?.cancel()
            uploadTask = nil
            composerFocusTask?.cancel()
            composerFocusTask = nil
            live.hasInlineModalPresented = false
        }
    }

    private func expandComposer() {
        isComposerAwaitingInitialFocus = true
        withAnimation(.easeInOut(duration: 0.18)) {
            isComposerExpanded = true
        }
        composerFocusTask?.cancel()
        composerFocusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isComposerAwaitingInitialFocus = false
            composerFocusTask = nil
            if isComposerExpanded && !isComposerFocused && live.bar.window != nil {
                collapseComposer()
            }
        }
    }

    private func collapseComposer() {
        composerFocusTask?.cancel()
        composerFocusTask = nil
        isComposerAwaitingInitialFocus = false
        isComposerFocused = false
        withAnimation(.easeInOut(duration: 0.18)) {
            isComposerExpanded = false
        }
    }

    private func collapseIfTerminalKeyboardActive() {
        guard isComposerExpanded, !isComposerAwaitingInitialFocus else { return }
        DispatchQueue.main.async {
            guard isComposerExpanded, !isComposerAwaitingInitialFocus, !isComposerFocused else { return }
            if live.bar.window != nil {
                collapseComposer()
            }
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem) {
        guard !isUploadingPhoto else { return }
        uploadTask?.cancel()
        isUploadingPhoto = true
        photoUploadError = nil

        let session = live.session
        uploadTask = Task { @MainActor in
            defer {
                isUploadingPhoto = false
                uploadTask = nil
            }
            do {
                let remotePath = try await PhotoAttachmentUploader.upload(item: item, session: session)
                guard !Task.isCancelled else { return }
                live.aiPromptDraft = RemoteAttachmentHelper.promptInsertion(
                    forRemotePath: remotePath,
                    existingPrompt: live.aiPromptDraft
                )
                AppHaptics.notify(.success)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                photoUploadError = error.localizedDescription
                AppHaptics.notify(.error)
            }
        }
    }

    private func sendRaw(_ sequence: String) {
        guard isConnected else { return }
        AppHaptics.impact(.light)
        live.sendQuickAction(Array(sequence.utf8))
    }

    private func sendBracketedPrompt(submit: Bool) {
        guard isConnected else { return }
        let payload = TMuxSessionHelper.bracketedPastePayload(for: live.aiPromptDraft, submit: submit)
        live.bridge.send(Array(payload))
        live.aiPromptDraft = ""
        if submit {
            AppHaptics.notify(.success)
        } else {
            AppHaptics.impact(.medium)
        }
        collapseComposer()
    }

    private var noTmuxNoticeStrip: some View {
        let amber = palette.proBrandAmber

        return VStack(spacing: 0) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 0.5)

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(amber)
                    .accessibilityHidden(true)

                Text("No tmux · This agent session will end if you close TermApp.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button {
                    AppHaptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        live.tmuxNoticeDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(theme.secondaryForegroundColor)
                        .minTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss tmux persistence warning")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background {
                ZStack {
                    theme.backgroundColor.opacity(0.86)
                    Rectangle().fill(.ultraThinMaterial)
                    amber.opacity(theme.isDark ? 0.14 : 0.10)
                }
            }
        }
    }
}

/// Sleek horizontal frosted chip bar providing 1-tap AI coding CLI actions and a pinned Compose CTA.
struct AIQuickActionBar: View {
    let accentTint: Color
    let isComposerExpanded: Bool
    let hasDraft: Bool
    let isConnected: Bool
    let canPreview: Bool
    let theme: TerminalTheme
    let onSendText: (String) -> Void
    let onOpenGitDiff: () -> Void
    let onOpenPreview: () -> Void
    let onToggleComposer: () -> Void

    private var palette: ProDesign.Palette {
        ProDesign.Palette(theme: theme)
    }

    private var expandedComposeForeground: Color {
        let uiColor = UIColor(accentTint)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return .black
        }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < 0.42 ? .white : .black
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 0.5)

            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        actionChip(
                            title: "Approve",
                            systemImage: "checkmark.circle.fill",
                            tint: palette.healthy,
                            accessibilityLabel: "Approve prompt, sends y and Return"
                        ) {
                            onSendText("y\r")
                        }

                        actionChip(
                            title: "Deny",
                            systemImage: "xmark.circle.fill",
                            tint: palette.critical,
                            accessibilityLabel: "Deny prompt, sends n and Return"
                        ) {
                            onSendText("n\r")
                        }

                        actionChip(
                            title: "Ctrl+C",
                            systemImage: "stop.circle",
                            tint: palette.warning,
                            accessibilityLabel: "Control C, interrupts current action"
                        ) {
                            onSendText("\u{03}")
                        }

                        actionChip(
                            title: "Shift+Tab",
                            systemImage: "arrow.left.to.line",
                            tint: nil,
                            accessibilityLabel: "Shift Tab, cycles agent mode"
                        ) {
                            onSendText("\u{1B}[Z")
                        }

                        actionChip(
                            title: "/compact",
                            systemImage: "arrow.down.right.and.arrow.up.left",
                            tint: nil,
                            accessibilityLabel: "Send slash compact command"
                        ) {
                            onSendText("/compact\r")
                        }

                        actionChip(
                            title: "Diff",
                            systemImage: "doc.text.magnifyingglass",
                            tint: nil,
                            accessibilityLabel: "Inspect Git diff and changed files"
                        ) {
                            onOpenGitDiff()
                        }

                        actionChip(
                            title: "Preview",
                            systemImage: "safari",
                            tint: nil,
                            isEnabled: canPreview,
                            accessibilityLabel: "Preview remote dev server"
                        ) {
                            onOpenPreview()
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 18)
                    .padding(.vertical, 7)
                }
                .mask(
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 18)
                    }
                )

                Rectangle()
                    .fill(palette.hairline)
                    .frame(width: 1, height: 22)
                    .padding(.trailing, 8)

                composeButton
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
            }
        }
        .background {
            ZStack {
                theme.backgroundColor.opacity(0.84)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }

    private func actionChip(
        title: String,
        systemImage: String,
        tint: Color?,
        isEnabled: Bool? = nil,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let enabled = isEnabled ?? isConnected
        let chipFill = tint.map { palette.pillFill(for: $0) } ?? palette.cardFill
        let chipStroke = tint.map { $0.opacity(0.36) } ?? palette.borderSubtle
        let fgColor = tint ?? theme.foregroundColor

        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(fgColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chipFill, in: Capsule())
            .overlay(Capsule().strokeBorder(chipStroke, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
    }

    private var composeButton: some View {
        let showDraftBadge = !isComposerExpanded && hasDraft
        return Button(action: onToggleComposer) {
            HStack(spacing: 5) {
                if showDraftBadge {
                    Circle()
                        .fill(accentTint)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: isComposerExpanded ? "chevron.down" : "text.bubble.fill")
                        .font(.caption.weight(.semibold))
                }
                Text("Compose")
                    .font(.caption.weight(.semibold))
                if showDraftBadge {
                    Text("Draft")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(palette.badgeFill(for: accentTint), in: Capsule())
                }
            }
            .foregroundStyle(isComposerExpanded ? expandedComposeForeground : accentTint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isComposerExpanded
                    ? accentTint
                    : palette.pillFill(for: accentTint),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(accentTint.opacity(0.65), lineWidth: 0.9)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isComposerExpanded ? "Collapse Prompt Composer" : "Open Prompt Composer")
        .accessibilityValue(showDraftBadge ? "Draft saved" : "")
        .accessibilityAddTraits(isComposerExpanded ? .isSelected : [])
    }
}

/// Docked expandable multi-line prompt composer with native autocorrect, cursor drag, photo attach, and dictation.
struct AIPromptComposerView: View {
    @Binding var prompt: String
    @FocusState.Binding var isFieldFocused: Bool
    let agentName: String?
    let accentTint: Color
    let isConnected: Bool
    let canUploadPhoto: Bool
    let isUploadingPhoto: Bool
    let photoUploadError: String?
    let theme: TerminalTheme
    let onPickPhoto: (PhotosPickerItem) -> Void
    let onDismissPhotoError: () -> Void
    let onSend: () -> Void
    let onPaste: () -> Void
    let onDismissComposer: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?

    private var palette: ProDesign.Palette {
        ProDesign.Palette(theme: theme)
    }

    private var hasText: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        hasText && isConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 0.5)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accentTint)
                            .accessibilityHidden(true)

                        Text(agentName.map { "\($0) Prompt" } ?? "AI Prompt Composer")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.foregroundColor)
                    }

                    Spacer()

                    if !prompt.isEmpty {
                        Button("Clear") {
                            AppHaptics.impact(.light)
                            prompt = ""
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: ProDesign.Layout.minTapTarget)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                    }

                    Button {
                        AppHaptics.impact(.light)
                        isFieldFocused = false
                        onDismissComposer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .minTapTarget()
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Close Prompt Composer")
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)

                TextField("Write or dictate a prompt…", text: $prompt, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.sentences)
                    .focused($isFieldFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        palette.inputFill,
                        in: RoundedRectangle(cornerRadius: ProDesign.Radius.innerCard, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ProDesign.Radius.innerCard, style: .continuous)
                            .strokeBorder(
                                isFieldFocused ? accentTint.opacity(0.75) : palette.borderSubtle,
                                lineWidth: isFieldFocused ? 1.5 : 1
                            )
                    )
                    .padding(.horizontal, 12)

                if isUploadingPhoto {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Uploading image to /tmp via SFTP…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.secondaryForegroundColor)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                } else if let photoUploadError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(palette.critical)
                        Text(photoUploadError)
                            .font(.caption)
                            .foregroundStyle(palette.critical)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button {
                            onDismissPhotoError()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .minTapTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss upload error")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                }

                HStack(spacing: 10) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Group {
                            if isUploadingPhoto {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "photo.badge.plus")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .frame(width: 24, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!canUploadPhoto || isUploadingPhoto)
                    .accessibilityLabel("Attach screenshot or photo via SFTP")

                    Button {
                        isFieldFocused = false
                        onPaste()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!canSubmit)
                    .accessibilityLabel("Paste prompt without submitting")

                    Button {
                        isFieldFocused = false
                        onSend()
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(accentTint)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send prompt to agent")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background {
            ZStack {
                theme.backgroundColor.opacity(0.90)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            selectedPhotoItem = nil
            AppHaptics.impact(.light)
            onPickPhoto(newItem)
        }
        .onAppear {
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
    }
}
