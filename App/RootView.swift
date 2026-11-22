import SwiftUI

struct RootView: View {
    var body: some View {
        SessionTabsView { // wiring: T8
        NavigationStack {
            HostListView()  // wiring: T7
                .toolbar { NavigationLink(destination: SettingsView()) { Image(systemName: "gear") }.accessibilityLabel("Settings") }  // wiring: T10
                #if DEBUG
                .toolbar { NavigationLink("Debug", destination: DebugConnectView()) }  // wiring: T5
                #endif
        }
        } // wiring: T8
    }
}
