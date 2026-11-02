import Design
import LedgerSync
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let session = model.active {
                AppShell(session: session).id(session.id)
            } else {
                NavigationStack { WelcomeView() }
            }
        }
        .tint(Theme.tint)
        .sheet(item: $model.pendingInvite) { JoinSheet(link: $0) }
        .alert(model.toast ?? "", isPresented: Binding(get: { model.toast != nil }, set: { if !$0 { model.toast = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

extension InviteLink: @retroactive Identifiable {
    public var id: String { groupID.uuidString + memberID }
}
