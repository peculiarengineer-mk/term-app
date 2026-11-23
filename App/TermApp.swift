import SwiftUI
import SwiftData

@main
struct TermApp: App {
    private let container = AppContainer.make() // wiring: T3
    private let sync: SyncCoordinator // wiring: T10

    init() {
        let coordinator = SyncCoordinator(modelContainer: container) // wiring: T10
        sync = coordinator // wiring: T10
        Task { await coordinator.start() } // wiring: T10
    }

    @State private var sessions = SessionManager() // wiring: T8
    @State private var appLock = AppLockManager()
    @State private var proStore = ProStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { ReconnectCoordinator.startShared(manager: sessions, container: container) } // wiring: T9
        }
        .modelContainer(container) // wiring: T3
        .environment(sessions) // wiring: T8
        .environment(appLock)
        .environment(proStore)

        WindowGroup(id: SessionSceneView.windowGroupID, for: UUID.self) { $id in // wiring: T8
            SessionSceneView(id: id) // wiring: T8
                .environment(sessions) // wiring: T8
                .environment(appLock)
                .environment(proStore)
        } // wiring: T8
        .modelContainer(container) // wiring: T8
    }
}
