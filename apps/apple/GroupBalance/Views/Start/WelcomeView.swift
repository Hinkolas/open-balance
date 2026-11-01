import Design
import SwiftUI

/// First screen without any group: join with an invite, or create a group on
/// a server you own.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showJoin = false
    @State private var showCreate = false

    var body: some View {
        GBPage {
            GBPageHeader(eyebrow: String(localized: "End-to-end encrypted"), title: "Group", emphasis: "Balance")
                .padding(.top, 40)
            Text("Track money in a group: who received what, whom it belongs to, what has arrived, and who pays whom in the end. Only members can read it, not even the server.")
                .font(GBFont.body)
                .foregroundStyle(GB.ink2)
                .padding(.top, 16)
            VStack(spacing: 12) {
                GBPrimaryButton(String(localized: "Join with an invite"), systemImage: "qrcode.viewfinder") { showJoin = true }
                GBSecondaryButton(String(localized: "Create a group")) { showCreate = true }
            }
            .padding(.top, 40)
            Text("To join, ask the group's admin to add you and show you your invite QR code.")
                .font(GBFont.secondary)
                .foregroundStyle(GB.ink3)
                .padding(.top, 20)
        }
        .sheet(isPresented: $showJoin) { JoinSheet(link: nil) }
        .sheet(isPresented: $showCreate) { CreateGroupSheet() }
    }
}
