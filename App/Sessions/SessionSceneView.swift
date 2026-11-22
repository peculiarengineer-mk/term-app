import SwiftUI
import UIKit
import TermUI

/// A terminal with its extra keys bar and hardware key commands; one per visible session.
/// The controller and bar live on the session; the pane is keyed by the bridge so a replaced
/// bridge rebuilds the terminal view.
struct TerminalPane: View {
    let live: LiveSession

    var body: some View {
        let controller = live.controller
        ZStack {
            // Pass the session's current font size so a rebuilt pane (tab switch, new window,
            // reconnect) keeps what Cmd+= / Cmd+- set.
            TerminalHostView(io: live.bridge, fontSize: controller.fontSize, controller: controller, accessoryView: live.bar,
                             keyCommands: HardwareKeyCommands.commands(action: TerminalHostView.keyCommandAction),
                             onKeyCommand: { [controller] in HardwareKeyCommands.handle($0, controller: controller) })
                .ignoresSafeArea(.container, edges: .bottom)
            if let overlay = live.overlay { overlay }
        }
        .id(ObjectIdentifier(live.bridge))
    }
}

/// Content of a window opened for one session (`WindowGroup(for: UUID.self)`).
struct SessionSceneView: View {
    static let windowGroupID = "session"
    let id: UUID?
    @Environment(SessionManager.self) private var manager
    @State private var windowID = UUID()
    @State private var scene: UIWindowScene?
    /// Set once this window has asked to close; it then never claims a session again.
    @State private var dismissing = false

    var body: some View {
        Group {
            if dismissing {
                Color.clear  // closing: never the terminal, never a placeholder
            } else if let id, let live = manager.session(id: id) {
                Group {
                    // Render only while this window owns the session, so two windows never run
                    // terminals on one bridge (or share its accessory bar), even for a moment.
                    if live.windowID == windowID || live.windowID == nil {
                        TerminalPane(live: live)
                            .overlay(alignment: .topTrailing) {
                                Button("Close", role: .destructive) { closeWindow() }
                                    .buttonStyle(.bordered).padding(8)
                            }
                    } else {
                        ContentUnavailableView {
                            Label("Shown in another window", systemImage: "rectangle.on.rectangle")
                        } actions: {
                            Button("Close Window") { dismissSelf() }
                        }
                    }
                }
                .onAppear { if !dismissing { manager.show(live.id, in: windowID) } }
                .onChange(of: live.windowID) { _, w in
                    if dismissing { return }
                    if w == nil {
                        manager.show(live.id, in: windowID)  // detached to reopen here: claim it
                    } else if w != windowID {
                        dismissSelf()  // another window took the session
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Session ended", systemImage: "terminal")
                } actions: {
                    Button("Close Window") { dismissSelf() }
                }
            }
        }
        .background(SceneReader(scene: $scene))
        .onChange(of: scene) { _, s in
            if dismissing, let s { UIApplication.shared.requestSceneSessionDestruction(s.session, options: nil) }
        }
        .background { if let scene { CloseShortcut(scene: scene) { closeWindow() } } }
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

/// Cmd+W closes this window, and the session too when this window shows it (see closeWindow).
private struct CloseShortcut: View {
    let scene: UIWindowScene
    let action: () -> Void

    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .termCloseTab, object: scene)) { _ in action() }
            .allowsHitTesting(false)
    }
}
