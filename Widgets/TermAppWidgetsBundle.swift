import SwiftUI
import WidgetKit

@main
struct TermAppWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickConnectHostsWidget()
        ActiveAgentsWidget()
        AgentLiveActivityWidget()
    }
}
