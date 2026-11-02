import Design
import LedgerSync
import SwiftUI

/// Four sections as tabs (side rail on iPhone Duo and iPad). Adding a
/// payment is an action, so it lives in the toolbar, not in the tab bar.
struct AppShell: View {
    let session: GroupSession
    @State private var tab: AppTab = .overview
    @State private var historyFilter: HistoryFilter = .all

    var body: some View {
        TabView(selection: $tab) {
            Tab("Overview", systemImage: "chart.bar.xaxis", value: .overview) {
                NavigationStack {
                    OverviewView(session: session) {
                        historyFilter = .payments
                        tab = .history
                    }
                }
            }
            Tab("Settle up", systemImage: "arrow.left.arrow.right", value: .settle) {
                NavigationStack { SettleView(session: session) }
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: .history) {
                NavigationStack { HistoryView(session: session, filter: $historyFilter) }
            }
            Tab("Group", systemImage: "person.2", value: .group) {
                NavigationStack { GroupView(session: session) }
            }
        }
        .tint(Theme.tint)
    }
}

enum AppTab: Hashable { case overview, settle, history, group }
