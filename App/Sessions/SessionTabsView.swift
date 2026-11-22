import SwiftUI
import UIKit
import TermUI

/// The window's content: tabs for its sessions, with the host list as the "new tab" screen.
struct SessionTabsView<HostList: View>: View {
    @ViewBuilder let hostList: () -> HostList
    @Environment(SessionManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    /// Lives as long as this view. If iOS rebuilds a disconnected scene, its sessions stay open and
    /// are reachable from the switcher (accepted for M1).
    @State private var windowID = UUID()
    @State private var tabIDs: [UUID] = []
    /// nil shows the host list.
    @State private var selection: UUID?
    @State private var scene: UIWindowScene?
    @State private var switching = false

    private var tabs: [LiveSession] {
        tabIDs.compactMap { manager.session(id: $0) }.filter { $0.windowID == windowID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.isEmpty { tabBar }
            if let id = selection, let live = tabs.first(where: { $0.id == id }) {
                TerminalPane(live: live)
            } else {
                hostList()
            }
        }
        .environment(\.openSessionTab) { id in addTab(id) }
        .background(SceneReader(scene: $scene))
        .background { if let scene { TabNotifications(scene: scene, model: self) } }
        .onChange(of: tabs.map(\.id)) { _, live in
            tabIDs.removeAll { !live.contains($0) }
            if let s = selection, !live.contains(s) { selection = tabIDs.last }
        }
        .sheet(isPresented: $switching) {
            SessionSwitcher(onSelect: { addTab($0) }, onOpenInWindow: { moveToWindow($0) })
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { live in
                        Button { selection = live.id } label: {
                            Text(live.title).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(selection == live.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                            in: Capsule())
                        }
                        .contextMenu {
                            Button("Move to New Window", systemImage: "macwindow.badge.plus") { moveToWindow(live.id) }
                            Button("Close", systemImage: "xmark", role: .destructive) { manager.close(live.id) }
                        }
                    }
                }.padding(.horizontal, 8)
            }
            Button { selection = nil } label: { Image(systemName: "plus") }.padding(.horizontal, 6)
            Button { switching = true } label: { Image(systemName: "square.on.square") }.padding(.trailing, 10)
        }
        .padding(.vertical, 4)
    }

    func addTab(_ id: UUID) {
        guard manager.session(id: id) != nil else { return }
        manager.show(id, in: windowID)  // moves it out of any other window
        if !tabIDs.contains(id) { tabIDs.append(id) }
        selection = id
    }

    private func moveToWindow(_ id: UUID) {
        manager.detach(id)
        tabIDs.removeAll { $0 == id }
        if selection == id { selection = tabIDs.last }
        openWindow(value: id)
    }

    fileprivate func newTab() { selection = nil }
    fileprivate func closeCurrent() { if let s = selection { manager.close(s) } }
    fileprivate func switchTab(_ index: Int) {
        if tabIDs.indices.contains(index) { selection = tabIDs[index] }
    }
}

/// Observes T6's tab notifications with this window's scene as the object.
private struct TabNotifications<HostList: View>: View {
    let scene: UIWindowScene
    let model: SessionTabsView<HostList>
    private let center = NotificationCenter.default

    var body: some View {
        Color.clear
            .onReceive(center.publisher(for: .termNewTab, object: scene)) { _ in model.newTab() }
            .onReceive(center.publisher(for: .termCloseTab, object: scene)) { _ in model.closeCurrent() }
            .onReceive(center.publisher(for: .termSwitchTab, object: scene)) { note in
                if let i = note.userInfo?[HardwareKeyCommands.tabIndexKey] as? Int { model.switchTab(i) }
            }
            .allowsHitTesting(false)
    }
}

/// Finds the window scene this view lives in.
struct SceneReader: UIViewRepresentable {
    @Binding var scene: UIWindowScene?

    final class Probe: UIView {
        var onScene: ((UIWindowScene?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onScene?(window?.windowScene) }
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe(); v.isUserInteractionEnabled = false
        v.onScene = { s in DispatchQueue.main.async { scene = s } }
        return v
    }
    func updateUIView(_ uiView: Probe, context: Context) {}
}
