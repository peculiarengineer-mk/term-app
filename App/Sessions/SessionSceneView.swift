import SwiftUI
import SwiftData
import UIKit
import SSHKit
import TermUI

/// A terminal with its extra keys bar and hardware key commands; one per visible session.
/// The controller and bar live on the session; the pane is keyed by the bridge so a replaced
/// bridge rebuilds the terminal view.
struct TerminalPane: View {
    let live: LiveSession
    var onOpenGitDiff: (() -> Void)? = nil
    var onOpenDevPreview: (() -> Void)? = nil
    @Environment(ProStore.self) private var proStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @AppStorage(AppearanceSettings.fontSizeKey) private var fontSize = AppearanceSettings.defaultFontSize
    @AppStorage(AppearanceSettings.fontFamilyKey) private var fontFamilyRaw = AppearanceSettings.defaultFontFamilyRaw
    @AppStorage(AppearanceSettings.cursorStyleKey) private var cursorStyleRaw = AppearanceSettings.defaultCursorStyleRaw
    @AppStorage(AppearanceSettings.hapticsKey) private var hapticsEnabled = AppearanceSettings.defaultHapticsEnabled
    @State private var isVisible = false
    @State private var inspectingSecurity = false
    @State private var zoomHUDText: String?
    @State private var zoomHUDTask: Task<Void, Never>?

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var fontFamily: TerminalFontFamily { TerminalFontFamily(rawValue: fontFamilyRaw) ?? .sfMono }
    private var cursorStyle: TerminalCursorStyle { TerminalCursorStyle(rawValue: cursorStyleRaw) ?? .block }

    var body: some View {
        let controller = live.controller
        ZStack {
            VStack(spacing: 0) {
                if live.overlay == nil, let a = live.algorithms, a.isPostQuantum == false, !live.quantumNoticeDismissed {
                    quantumNoticeBanner(algorithms: a)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: live.id) {
                            try? await Task.sleep(for: .seconds(4))
                            while inspectingSecurity && !Task.isCancelled {
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                            guard !Task.isCancelled, !live.quantumNoticeDismissed else { return }
                            if reduceMotion {
                                live.quantumNoticeDismissed = true
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    live.quantumNoticeDismissed = true
                                }
                            }
                        }
                }

                TerminalHostView(
                    io: live.bridge,
                    theme: theme,
                    fontSize: CGFloat(fontSize),
                    fontFamily: fontFamily,
                    cursorStyle: cursorStyle,
                    controller: controller,
                    accessoryView: live.bar,
                    keyCommands: HardwareKeyCommands.commands(action: TerminalHostView.keyCommandAction),
                    autoFocus: live.shouldAutoFocus && live.overlay == nil,
                    hapticsEnabled: hapticsEnabled,
                    onKeyCommand: { [controller] in HardwareKeyCommands.handle($0, controller: controller) },
                    onFontSizeChange: { newSize in
                        let updated = Double(newSize)
                        fontSize = updated
                        showZoomHUD(for: updated)
                    }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        live.recordTerminalFocusInteraction()
                    }
                )

                if proStore.isProUnlocked, live.showAIAgentControls, live.overlay == nil {
                    AITerminalControlsOverlay(
                        live: live,
                        theme: theme,
                        onOpenGitDiff: onOpenGitDiff,
                        onOpenDevPreview: onOpenDevPreview
                    )
                }
            }

            if let zoomHUDText, live.overlay == nil {
                Text(zoomHUDText)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(theme.isDark ? 0.16 : 0.12), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.35 : 0.12), radius: 10, x: 0, y: 4)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityLabel("Font size \(zoomHUDText)")
            }

            if let overlay = live.overlay { overlay }
        }
        .background(theme.backgroundColor.ignoresSafeArea(.container, edges: .bottom))
        .id(ObjectIdentifier(live.bridge))
        .onAppear {
            isVisible = true
            live.terminalAppeared()
            live.hasInlineModalPresented = inspectingSecurity
            syncExtraKeysBar()
        }
        .onDisappear {
            isVisible = false
            live.terminalDisappeared()
            live.hasInlineModalPresented = false
            zoomHUDTask?.cancel()
            zoomHUDTask = nil
        }
        .onChange(of: inspectingSecurity) { _, isPresented in
            live.hasInlineModalPresented = isPresented
        }
        .onChange(of: themeName) { _, _ in syncExtraKeysBar() }
        .onChange(of: hapticsEnabled) { _, _ in syncExtraKeysBar() }
        .onChange(of: live.connectionStatus) { _, status in
            if status == .connected {
                live.dispatchPendingLaunchCommandIfReady()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            DispatchQueue.main.async {
                if isVisible, live.overlay == nil, !inspectingSecurity, live.bar.window != nil {
                    live.recordTerminalFocusInteraction()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            if isVisible, live.overlay == nil, !inspectingSecurity {
                live.shouldAutoFocus = true
                if live.bar.window != nil {
                    live.recordTerminalFocusInteraction()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            DispatchQueue.main.async {
                guard isVisible, live.overlay == nil, !inspectingSecurity, !hasPresentedModal else { return }
                live.shouldAutoFocus = false
            }
        }
    }

    private func quantumNoticeBanner(algorithms: NegotiatedAlgorithms) -> some View {
        HStack(spacing: 8) {
            Button {
                AppHaptics.impact(.light)
                inspectingSecurity = true
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)

                    Text("Not quantum-safe. Server offered \(algorithms.kex).")
                        .font(.footnote)
                        .foregroundStyle(theme.foregroundColor)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 4)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection security warning: Not quantum-safe. Tap for algorithm details.")
            .popover(isPresented: $inspectingSecurity) {
                ConnectionSecuritySheet(title: live.title, algorithms: algorithms)
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
            }

            Button {
                AppHaptics.impact(.light)
                live.quantumNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.secondaryForegroundColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss quantum-safety warning")
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .background(
            Color.orange.opacity(theme.isDark ? 0.14 : 0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.38), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var hasPresentedModal: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }

    private func syncExtraKeysBar() {
        let controller = live.controller
        live.bar.apply(theme: theme)
        live.bar.hapticsEnabled = hapticsEnabled
        live.bar.onDismissKeyboard = { [weak controller, weak live] in
            live?.shouldAutoFocus = false
            controller?.dismissKeyboard()
        }
    }

    private func showZoomHUD(for size: Double) {
        zoomHUDTask?.cancel()
        let formatted = AppearanceSettings.formattedFontSize(size)
        if reduceMotion {
            zoomHUDText = formatted
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                zoomHUDText = formatted
            }
        }
        zoomHUDTask = Task {
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                zoomHUDText = nil
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    zoomHUDText = nil
                }
            }
        }
    }
}

/// Content of a window opened for one session (`WindowGroup(for: UUID.self)`).
struct SessionSceneView: View {
    static let windowGroupID = "session"
    let id: UUID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(SessionManager.self) private var manager
    @Environment(ProStore.self) private var proStore
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @AppStorage(AppearanceSettings.fontSizeKey) private var fontSize = AppearanceSettings.defaultFontSize
    @State private var windowID = UUID()
    @State private var scene: UIWindowScene?
    /// Set once this window has asked to close; it then never claims a session again.
    @State private var dismissing = false
    @State private var inspectingSecurity = false
    @State private var activeToolSheet: SessionToolSheet?
    @State private var confirmingClose = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    private var ownedLiveSession: LiveSession? {
        guard !dismissing, let id, let live = manager.session(id: id),
              live.windowID == windowID || live.windowID == nil else {
            return nil
        }
        return live
    }

    private var isModalOverTerminal: Bool {
        activeToolSheet != nil || inspectingSecurity
    }

    var body: some View {
        Group {
            if dismissing {
                Color.clear // closing: never the terminal, never a placeholder
            } else if let id, let live = manager.session(id: id) {
                Group {
                    // Render only while this window owns the session, so two windows never run
                    // terminals on one bridge (or share its accessory bar), even for a moment.
                    if live.windowID == windowID || live.windowID == nil {
                        VStack(spacing: 0) {
                            windowHeaderBar(for: live)
                            TerminalPane(
                                live: live,
                                onOpenGitDiff: { openGitDiffShortcut(for: live) },
                                onOpenDevPreview: { openDevServerPreviewShortcut(for: live) }
                            )
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Shown in another window", systemImage: "rectangle.on.rectangle")
                        } actions: {
                            Button("Close Window") { dismissSelf() }
                        }
                    }
                }
                .onAppear {
                    if !dismissing {
                        manager.show(live.id, in: windowID)
                        live.hasModalSheetPresented = isModalOverTerminal
                    }
                }
                .onDisappear {
                    if live.windowID == windowID {
                        live.hasModalSheetPresented = false
                    }
                }
                .onChange(of: live.windowID) { _, w in
                    if dismissing { return }
                    if w == nil {
                        manager.show(live.id, in: windowID) // detached to reopen here: claim it
                    } else if w != windowID {
                        live.hasModalSheetPresented = false
                        dismissSelf() // another window took the session
                    }
                }
                .onChange(of: isModalOverTerminal) { _, isPresented in
                    if !dismissing, live.windowID == windowID {
                        live.hasModalSheetPresented = isPresented
                    }
                }
                .confirmationDialog(
                    "Close active session?",
                    isPresented: $confirmingClose,
                    titleVisibility: .visible
                ) {
                    if live.ephemeralHost != nil {
                        Button("Save Host", systemImage: "bookmark.badge.plus") {
                            manager.saveEphemeralHost(for: live.id, in: modelContext)
                        }
                    }
                    Button("Close Session", role: .destructive) { closeWindow() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Closing this window will disconnect the active SSH session for \(live.title).")
                }
            } else {
                ContentUnavailableView {
                    Label("Session ended", systemImage: "terminal")
                } actions: {
                    Button("Close Window") { dismissSelf() }
                }
            }
        }
        .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
        .tint(theme.accentColor)
        .modifier(PrivacyBlurModifier())
        .sessionToolSheets(item: $activeToolSheet, theme: theme)
        .background(SceneReader(scene: $scene))
        .onChange(of: scene) { _, s in
            if dismissing, let s { UIApplication.shared.requestSceneSessionDestruction(s.session, options: nil) }
        }
        .background {
            if let scene {
                SceneNotifications(
                    scene: scene,
                    onNewTab: { requestNewTabInMainWindow() },
                    onCloseTab: { requestCloseWindow() }
                )
            }
        }
        .background { keyboardShortcutsLayer }
    }

    private func windowHeaderBar(for live: LiveSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    ConnectionStatusDot(status: live.connectionStatus, size: 8, glow: live.connectionStatus == .connected)
                    Text(live.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.foregroundColor)
                        .lineLimit(1)
                    AgentActivityBadge(state: live.agentActivityState)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    theme.accentColor.opacity(theme.isDark ? 0.22 : 0.16),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(theme.accentColor.opacity(0.45), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(live.title)
                .accessibilityValue(live.connectionStatus.accessibilityLabel)

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    SessionToolsMenu(
                        live: live,
                        isProUnlocked: proStore.isProUnlocked,
                        foregroundColor: theme.foregroundColor
                    ) { tool in
                        activeToolSheet = tool
                    }

                    if horizontalSizeClass != .compact, let algorithms = live.algorithms {
                        Button {
                            AppHaptics.impact(.light)
                            inspectingSecurity = true
                        } label: {
                            Image(systemName: algorithms.isPostQuantum ? "lock.shield.fill" : "lock.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(algorithms.isPostQuantum ? Color.green : Color.orange)
                                .minTapTarget()
                        }
                        .accessibilityLabel(algorithms.isPostQuantum ? "Connection security: Post-quantum" : "Connection security: Classical")
                        .popover(isPresented: $inspectingSecurity) {
                            ConnectionSecuritySheet(title: live.title, algorithms: algorithms)
                                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                        }
                    }

                    Button {
                        mergeBackToMainWindow()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.foregroundColor)
                            .minTapTarget()
                    }
                    .accessibilityLabel("Merge Back to Main Window")

                    Button {
                        AppHaptics.impact(.light)
                        requestCloseWindow()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.secondaryForegroundColor)
                            .minTapTarget()
                    }
                    .accessibilityLabel("Close \(live.title)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12))
                .frame(height: 1)
        }
        .background(theme.backgroundColor.ignoresSafeArea(.container, edges: .top))
    }

    private func mergeBackToMainWindow() {
        guard !dismissing, let id else { return }
        AppHaptics.impact(.light)
        manager.session(id: id)?.hasModalSheetPresented = false
        dismissSelf()
        manager.requestMergeBack(id)
    }

    private func requestNewTabInMainWindow() {
        guard activeToolSheet == nil, !inspectingSecurity, !confirmingClose else { return }
        AppHaptics.impact(.light)
        manager.requestNewTabInMainWindow()
        let hasOtherScene = UIApplication.shared.connectedScenes.contains { $0 !== scene }
        if !hasOtherScene {
            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
        }
    }

    private func adjustFontSize(by delta: Double) {
        fontSize = SessionFontShortcuts.adjustedFontSize(from: fontSize, delta: delta)
        AppHaptics.impact(.light)
    }

    private func resetFontSize() {
        fontSize = AppearanceSettings.defaultFontSize
        AppHaptics.impact(.light)
    }

    private func openGitDiffShortcut(for live: LiveSession) {
        guard activeToolSheet == nil,
              !inspectingSecurity,
              !confirmingClose,
              let sheet = SessionToolSheet.gitDiff(for: live, isProUnlocked: proStore.isProUnlocked) else {
            return
        }
        AppHaptics.impact(.light)
        activeToolSheet = sheet
    }

    private func openDevServerPreviewShortcut(for live: LiveSession) {
        guard activeToolSheet == nil,
              !inspectingSecurity,
              !confirmingClose,
              let sheet = SessionToolSheet.devServerPreview(for: live, isProUnlocked: proStore.isProUnlocked) else {
            return
        }
        AppHaptics.impact(.light)
        activeToolSheet = sheet
    }

    @ViewBuilder
    private var keyboardShortcutsLayer: some View {
        let modalFree = activeToolSheet == nil && !inspectingSecurity && !confirmingClose
        ZStack {
            if let live = ownedLiveSession, modalFree {
                SessionShortcutButton("Hosts Quick Connect", key: "t", modifiers: .command) {
                    requestNewTabInMainWindow()
                }
                SessionShortcutButton("Close Window", key: "w", modifiers: .command) {
                    requestCloseWindow()
                }
                SessionShortcutButton("Increase Font Size", key: "=", modifiers: .command) {
                    adjustFontSize(by: 1)
                }
                SessionShortcutButton("", key: "+", modifiers: .command) {
                    adjustFontSize(by: 1)
                }
                SessionShortcutButton("", key: "+", modifiers: [.command, .shift]) {
                    adjustFontSize(by: 1)
                }
                SessionShortcutButton("Decrease Font Size", key: "-", modifiers: .command) {
                    adjustFontSize(by: -1)
                }
                SessionShortcutButton("Reset Font Size", key: "0", modifiers: .command) {
                    resetFontSize()
                }
                SessionShortcutButton("Git Diff Inspector", key: "d", modifiers: [.command, .shift]) {
                    openGitDiffShortcut(for: live)
                }
                SessionShortcutButton("Dev Server Preview", key: "p", modifiers: [.command, .shift]) {
                    openDevServerPreviewShortcut(for: live)
                }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func requestCloseWindow() {
        if let id, let live = manager.session(id: id), live.connectionStatus == .connected {
            confirmingClose = true
        } else {
            closeWindow()
        }
    }

    private func closeWindow() {
        // The window that owns the session (or renders it unclaimed) ends it; a non-owner just closes itself.
        if !dismissing, let id, let live = manager.session(id: id), live.windowID == windowID || live.windowID == nil { manager.close(id) }
        dismissSelf()
    }

    /// Closes exactly this window by destroying its own scene. Never closes by value: another
    /// window can show the same session id. If the scene is not known yet, the close happens as
    /// soon as it is (see `onChange(of: scene)`).
    private func dismissSelf() {
        dismissing = true
        if let scene { UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) }
    }
}

/// Observes HardwareKeyCommands window-scoped notifications (`Cmd+T` / `Cmd+W`) for this secondary scene.
private struct SceneNotifications: View {
    let scene: UIWindowScene
    let onNewTab: () -> Void
    let onCloseTab: () -> Void
    private let center = NotificationCenter.default

    var body: some View {
        Color.clear
            .onReceive(center.publisher(for: .termNewTab, object: scene)) { _ in onNewTab() }
            .onReceive(center.publisher(for: .termCloseTab, object: scene)) { _ in onCloseTab() }
            .allowsHitTesting(false)
    }
}
