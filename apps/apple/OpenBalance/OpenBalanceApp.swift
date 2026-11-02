import LedgerSync
import SwiftUI

@main
struct OpenBalanceApp: App {
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
                    // `simctl launch … -OBOpenURL "openbalance://join?…"` skips the "Open in…" prompt.
                    if let raw = UserDefaults.standard.string(forKey: "OBOpenURL"), let url = URL(string: raw) {
                        model.handle(url: url)
                    }
                    #endif
                }
        }
    }
}
