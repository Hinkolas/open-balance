import Design
import LedgerSync
import SwiftUI
import UniformTypeIdentifiers

/// The admin's recovery kit, shown once (PROTOCOL.md §3.4). This device
/// doesn't keep it, so the screen stays until the admin says it's saved.
struct RecoveryKitView: View {
    let groupName: String
    let link: RecoveryLink
    let onDone: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "key.horizontal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.tint)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Save your recovery kit").font(.title2.bold())
                    Text("If you lose this device, this link makes a new device the admin of \(groupName). Keep it in your password manager: anyone who has it can read the group and act as its admin.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("This is the only time it's shown. This device doesn't keep it.")
                        .font(.subheadline.weight(.semibold))
                }
                .multilineTextAlignment(.center)
                Text(link.url.absoluteString)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 12) {
                    ShareLink(item: link.url) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy link"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                        // Not to other devices via Universal Clipboard, and not for long.
                        UIPasteboard.general.setItems([[UTType.plainText.identifier: link.url.absoluteString]],
                                                      options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(300)])
                        copied = true
                    }
                    .buttonStyle(.bordered)
                }
                Button { onDone() } label: {
                    Text("I saved it").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
    }
}

/// The recovery kit as its own sheet, after "New recovery kit".
struct RecoveryKitSheet: View {
    let groupName: String
    let link: RecoveryLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RecoveryKitView(groupName: groupName, link: link) { dismiss() }
        }
        .interactiveDismissDisabled()
        .tint(Theme.tint)
    }
}
