import SwiftUI
import TermUI

struct RootView: View {
    private enum AppTab: Int, CaseIterable, Hashable {
        case hosts = 1
        case agents = 2
        case cloud = 3
        case keys = 4
        case settings = 5

        var title: String {
            switch self {
            case .hosts: "Hosts"
            case .agents: "Agents"
            case .cloud: "Cloud"
            case .keys: "Keys"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .hosts: "server.rack"
            case .agents: "sparkles"
            case .cloud: "cloud.fill"
            case .keys: "key.fill"
            case .settings: "gearshape.fill"
            }
        }
    }

    @Environment(AppLockManager.self) private var appLock
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @State private var selectedTab: AppTab = .hosts
    @State private var showingWelcome = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }

    var body: some View {
        SessionTabsView(onFocusHosts: { selectedTab = .hosts }) { activeSessionPill in // wiring: T8
            TabView(selection: $selectedTab) {
                Tab(AppTab.hosts.title, systemImage: AppTab.hosts.systemImage, value: AppTab.hosts) {
                    tabContent(activeSessionPill: activeSessionPill) {
                        HostListView() // wiring: T7
                            #if DEBUG
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    NavigationLink("Debug", destination: DebugConnectView()) // wiring: T5
                                }
                            }
                            #endif
                    }
                }

                Tab(AppTab.agents.title, systemImage: AppTab.agents.systemImage, value: AppTab.agents) {
                    tabContent(activeSessionPill: activeSessionPill) {
                        AgentsDashboardView()
                    }
                }

                Tab(AppTab.cloud.title, systemImage: AppTab.cloud.systemImage, value: AppTab.cloud) {
                    tabContent(activeSessionPill: activeSessionPill) {
                        CloudTabView()
                    }
                }

                Tab(AppTab.keys.title, systemImage: AppTab.keys.systemImage, value: AppTab.keys) {
                    tabContent(activeSessionPill: activeSessionPill) {
                        KeyListView()
                    }
                }

                Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                    tabContent(activeSessionPill: activeSessionPill) {
                        SettingsView() // wiring: T10
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .background { workspaceKeyboardShortcuts }
        } // wiring: T8
        .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
        .tint(palette.accent)
        .modifier(PrivacyBlurModifier())
        .onAppear {
            if !onboardingCompleted {
                showingWelcome = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TermAppReplayOnboarding"))) { _ in
            showingWelcome = true
        }
        .sheet(isPresented: $showingWelcome, onDismiss: {
            onboardingCompleted = true
        }) {
            WelcomeSheetView()
                .interactiveDismissDisabled(false)
                .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                .tint(palette.accent)
        }
    }

    @ViewBuilder
    private var workspaceKeyboardShortcuts: some View {
        if !showingWelcome && !appLock.isLocked {
            ZStack {
                ForEach(AppTab.allCases, id: \.rawValue) { tab in
                    SessionShortcutButton(
                        "Switch to \(tab.title)",
                        key: KeyEquivalent(Character(String(tab.rawValue))),
                        modifiers: .command
                    ) {
                        if selectedTab != tab {
                            AppHaptics.impact(.light)
                            selectedTab = tab
                        }
                    }
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func tabContent<Content: View>(
        activeSessionPill: ActiveSessionPill?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let activeSessionPill {
                activeSessionPill
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
