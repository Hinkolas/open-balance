import Design
import LedgerCore
import LedgerSync
import SwiftUI

enum AppTab: Hashable { case overview, history, group, add }

/// Three tabs plus the detached "+" (search role on iOS 26). The "+" is an
/// action: it opens the payment editor and snaps back to the previous tab.
struct AppShell: View {
    let session: GroupSession
    @State private var tab: AppTab = .overview
    @State private var lastTab: AppTab = .overview
    @State private var newPayment = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Overview", systemImage: "house", value: .overview) {
                NavigationStack { OverviewView(session: session) }
            }
            Tab("History", systemImage: "clock", value: .history) {
                NavigationStack { HistoryView(session: session) }
            }
            Tab("Group", systemImage: "person.2", value: .group) {
                NavigationStack { GroupView(session: session) }
            }
            Tab("Add", systemImage: "plus", value: .add, role: .search) {
                GB.paper.ignoresSafeArea()
            }
        }
        .tint(GB.ink)
        .onChange(of: tab) { old, new in
            if new == .add {
                tab = old == .add ? lastTab : old
                newPayment = true
            } else {
                lastTab = new
            }
        }
        .sheet(isPresented: $newPayment) {
            PaymentEditor(session: session, draft: .new(session: session))
        }
    }
}
