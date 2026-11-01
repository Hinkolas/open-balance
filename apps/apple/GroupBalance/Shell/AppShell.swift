import Design
import LedgerSync
import SwiftUI

/// Three sections as tabs (side rail on iPhone Duo and iPad). Adding a
/// payment is an action, so it lives in the toolbar, not in the tab bar.
struct AppShell: View {
    let session: GroupSession

    var body: some View {
        TabView {
            Tab("Overview", systemImage: "chart.bar.xaxis") {
                NavigationStack { OverviewView(session: session) }
            }
            Tab("History", systemImage: "clock.arrow.circlepath") {
                NavigationStack { HistoryView(session: session) }
            }
            Tab("Group", systemImage: "person.2") {
                NavigationStack { GroupView(session: session) }
            }
        }
        .tint(Theme.tint)
    }
}
