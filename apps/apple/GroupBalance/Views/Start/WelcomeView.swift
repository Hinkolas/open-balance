import Design
import SwiftUI

/// First screen without any group: join with an invite, or create a group on
/// a server you own.
struct WelcomeView: View {
    @State private var showJoin = false
    @State private var showCreate = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "scalemass.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.tint)
                    .accessibilityHidden(true)
                Text("Group Balance").font(.largeTitle.bold())
                Text("Who received what, whom it belongs to, what has arrived, and who pays whom. Only members can read it, not even the server.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
            Spacer()
            VStack(spacing: 12) {
                Button { showJoin = true } label: {
                    Label("Join with an invite", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button { showCreate = true } label: {
                    Text("Create a group").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Text("To join, ask the group's admin to add you and show you your invite QR code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 420)
        }
        .padding(24)
        .tint(Theme.tint)
        .sheet(isPresented: $showJoin) { JoinSheet(link: nil) }
        .sheet(isPresented: $showCreate) { CreateGroupSheet() }
    }
}
