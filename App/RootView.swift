import SwiftUI
import TermUI

struct RootView: View {
    private enum AppTab: Hashable {
        case hosts
        case cloud
        case keys
        case settings
    }

    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @State private var selectedTab: AppTab = .hosts
    @State private var showingWelcome = false

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }

    var body: some View {
        SessionTabsView(onFocusHosts: { selectedTab = .hosts }) { activeSessionPill in // wiring: T8
            TabView(selection: $selectedTab) {
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
                .tabItem { Label("Hosts", systemImage: "server.rack") }
                .tag(AppTab.hosts)

                tabContent(activeSessionPill: activeSessionPill) {
                    CloudTabView()
                }
                .tabItem { Label("Cloud", systemImage: "cloud.fill") }
                .tag(AppTab.cloud)

                tabContent(activeSessionPill: activeSessionPill) {
                    KeyListView()
                }
                .tabItem { Label("Keys", systemImage: "key.fill") }
                .tag(AppTab.keys)

                tabContent(activeSessionPill: activeSessionPill) {
                    SettingsView() // wiring: T10
                }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
            }
        } // wiring: T8
        .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
        .tint(theme.accentColor)
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
                .tint(theme.accentColor)
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
