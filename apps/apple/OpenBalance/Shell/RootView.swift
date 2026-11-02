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
        .sheet(item: $model.pendingLink) { link in
            if case .creation(let c) = link {
                CreateGroupSheet(creation: c)
            } else {
                JoinSheet(link: link)
            }
        }
        .alert(model.toast ?? "", isPresented: Binding(get: { model.toast != nil }, set: { if !$0 { model.toast = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

extension InviteLink: @retroactive Identifiable {
    public var id: String { groupID.uuidString + memberID }
}

extension RecoveryLink: @retroactive Identifiable {
    public var id: String { url.absoluteString }
}

extension CreationLink: @retroactive Identifiable {
    public var id: String { code }
}

extension AppLink: @retroactive Identifiable {
    public var id: String {
        switch self {
        case .invite(let l): "invite" + l.id
        case .recovery(let l): "recovery" + l.id
        case .creation(let l): "creation" + l.id
        }
    }
}
