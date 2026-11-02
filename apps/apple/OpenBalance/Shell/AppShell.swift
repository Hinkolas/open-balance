import Design
import LedgerCore
import LedgerSync
import SwiftUI

/// Four sections as tabs (side rail on iPhone Duo and iPad). Adding a
/// payment is an action, so it lives in the toolbar, not in the tab bar.
struct AppShell: View {
    let session: GroupSession
    @State private var tab: AppTab = .overview
    @State private var historyFilter: HistoryFilter = .all

    var body: some View {
        if session.isRemoved {
            RemovedView(session: session)
        } else {
            tabs
        }
    }

    private var tabs: some View {
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

/// This device's key was removed from the group, or the server refuses it.
struct RemovedView: View {
    let session: GroupSession
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("This device was removed", systemImage: "iphone.slash")
            } description: {
                Text("It no longer has access to \(session.state.name). To come back, ask the admin or one of your other devices for a new invite.")
            } actions: {
                Button("Remove from this device", role: .destructive) { model.forget(session) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.negative)
                let others = model.sessions.filter { $0.id != session.id }
                if !others.isEmpty {
                    Menu("Your groups") {
                        ForEach(others) { s in
                            Button(s.state.name) { model.activate(s.id) }
                        }
                    }
                }
            }
        }
        .tint(Theme.tint)
    }
}
