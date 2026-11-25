import SwiftUI
import Store
import TermUI

/// Docked mobile AI controls shown over/below the terminal for AI agent sessions or when toggled via Session Tools.
struct AITerminalControlsOverlay: View {
    @Bindable var live: LiveSession
    let theme: TerminalTheme

    @State private var isComposerExpanded = false

    private var accentTint: Color {
        if let context = live.aiAgentContext {
            return AgentVisuals.agentTint(for: context.agent)
        }
        return AgentVisuals.appleProAmber
    }

    private var isConnected: Bool {
        live.connectionStatus == .connected
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
                    agentName: live.aiAgentContext?.agent.name,
                    accentTint: accentTint,
                    isConnected: isConnected,
                    theme: theme,
                    onSend: {
                        sendBracketedPrompt(submit: true)
                    },
                    onPaste: {
                        sendBracketedPrompt(submit: false)
                    },
                    onDismissComposer: {
                        isComposerExpanded = false
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            AIQuickActionBar(
                accentTint: accentTint,
                isComposerExpanded: isComposerExpanded,
                isConnected: isConnected,
                theme: theme,
                onSendText: { sequence in
                    sendRaw(sequence)
                },
                onToggleComposer: {
                    AppHaptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isComposerExpanded.toggle()
                    }
                }
            )
        }
    }

    private func sendRaw(_ sequence: String) {
        guard isConnected else { return }
        AppHaptics.impact(.light)
        live.bridge.send(Array(sequence.utf8))
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
        withAnimation(.easeInOut(duration: 0.18)) {
            isComposerExpanded = false
        }
    }

    private var noTmuxNoticeStrip: some View {
        let amber = AgentVisuals.appleProAmber
        let border = theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)

        return VStack(spacing: 0) {
            Rectangle()
                .fill(border)
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
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss tmux persistence warning")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
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

/// Sleek horizontal frosted chip bar providing 1-tap AI coding CLI actions.
struct AIQuickActionBar: View {
    let accentTint: Color
    let isComposerExpanded: Bool
    let isConnected: Bool
    let theme: TerminalTheme
    let onSendText: (String) -> Void
    let onToggleComposer: () -> Void

    private var surfaceBorder: Color {
        theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(surfaceBorder)
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    actionChip(
                        title: "Approve",
                        systemImage: "checkmark.circle.fill",
                        tint: AgentVisuals.activeGreen,
                        accessibilityLabel: "Approve prompt, sends y and Return"
                    ) {
                        onSendText("y\r")
                    }

                    actionChip(
                        title: "Deny",
                        systemImage: "xmark.circle.fill",
                        tint: Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0),
                        accessibilityLabel: "Deny prompt, sends n and Return"
                    ) {
                        onSendText("n\r")
                    }

                    actionChip(
                        title: "Esc",
                        systemImage: "escape",
                        tint: nil,
                        accessibilityLabel: "Escape key"
                    ) {
                        onSendText("\u{1B}")
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
                        title: "Ctrl+C",
                        systemImage: "stop.circle",
                        tint: .orange,
                        accessibilityLabel: "Control C, interrupts current action"
                    ) {
                        onSendText("\u{03}")
                    }

                    composeButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
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
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let chipFill = tint.map { $0.opacity(theme.isDark ? 0.16 : 0.12) }
            ?? (theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        let chipStroke = tint.map { $0.opacity(0.36) } ?? surfaceBorder
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
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
    }

    private var composeButton: some View {
        Button(action: onToggleComposer) {
            HStack(spacing: 5) {
                Image(systemName: isComposerExpanded ? "chevron.down" : "text.bubble.fill")
                    .font(.caption.weight(.semibold))
                Text("Compose")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isComposerExpanded ? Color.black : accentTint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                isComposerExpanded
                    ? accentTint
                    : accentTint.opacity(theme.isDark ? 0.22 : 0.15),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(accentTint.opacity(0.65), lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isComposerExpanded ? "Collapse Prompt Composer" : "Open Prompt Composer")
        .accessibilityAddTraits(isComposerExpanded ? .isSelected : [])
    }
}

/// Docked expandable multi-line prompt composer with native autocorrect, cursor drag, and voice dictation.
struct AIPromptComposerView: View {
    @Binding var prompt: String
    let agentName: String?
    let accentTint: Color
    let isConnected: Bool
    let theme: TerminalTheme
    let onSend: () -> Void
    let onPaste: () -> Void
    let onDismissComposer: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var hasText: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        hasText && isConnected
    }

    private var surfaceBorder: Color {
        theme.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(surfaceBorder)
                .frame(height: 0.5)

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
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Prompt Composer")
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            TextField("Write or dictate a prompt…", text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .textInputAutocapitalization(.sentences)
                .focused($isFieldFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isFieldFocused ? accentTint.opacity(0.75) : surfaceBorder,
                            lineWidth: 1
                        )
                )
                .padding(.horizontal, 12)

            HStack(spacing: 10) {
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
                .accessibilityLabel("Send prompt to agent")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background {
            ZStack {
                theme.backgroundColor.opacity(0.90)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
    }
}
