import LedgerSync
import SwiftUI

@main
struct GroupBalanceApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: phase, initial: true) { _, p in model.setForeground(p == .active) }
                .task {
                    #if DEBUG
                    // `simctl launch … -GBOpenURL "groupbalance://join?…"` skips the "Open in…" prompt.
                    if let raw = UserDefaults.standard.string(forKey: "GBOpenURL"), let url = URL(string: raw) {
                        model.handle(url: url)
                    }
                    #endif
                }
        }
    }
}
