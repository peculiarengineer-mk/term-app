import SwiftUI

struct SettingsView: View {
    @AppStorage("sync.enabled") private var syncEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("iCloud sync", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, on in
                        guard !on else { return }
                        SyncCoordinator.syncTurnedOff()
                    }
            } footer: {
                Text("Syncs saved hosts, saved passwords and trusted host keys through iCloud. Takes effect the next time the app opens. Turning sync off keeps everything on this device and leaves what is already in iCloud in place.")
            }
            Section {
                NavigationLink("SSH keys", destination: KeyListView())
            }
            Section {
                NavigationLink("Licences", destination: LicencesView())
            }
            #if DEBUG
            Section("Debug") {
                NavigationLink("Sync tools", destination: DebugSyncTools())
            }
            #endif
            Section {
                Text("To use Caps Lock as a modifier key, open iPadOS Settings › General › Keyboard › Hardware Keyboard › Modifier Keys.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
    }
}
