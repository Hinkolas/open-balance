import Design
import LedgerSync
import SwiftUI
#if canImport(VisionKit)
import Vision
import VisionKit
#endif

/// Join a group with an invite: scan the QR code or paste the link.
struct JoinSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var link: InviteLink?
    @State private var pasted = ""
    @State private var joining = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            GBPage {
                GBPageHeader(eyebrow: String(localized: "Invite"), title: String(localized: "Join a group"))
                    .padding(.top, 8)
                if let link {
                    GBSectionLabel(String(localized: "Server"))
                    Text(link.server.host() ?? link.server.absoluteString).font(GBFont.mono(15)).foregroundStyle(GB.ink)
                    Text("You join as the member the admin created for you. Your key stays on your devices and in your iCloud Keychain.")
                        .font(GBFont.secondary).foregroundStyle(GB.ink2).padding(.top, 12)
                    GBPrimaryButton(joining ? String(localized: "Joining…") : String(localized: "Join group")) { join(link) }
                        .disabled(joining)
                        .padding(.top, 28)
                } else {
                    #if canImport(VisionKit) && os(iOS)
                    if DataScannerViewController.isSupported {
                        GBSectionLabel(String(localized: "Scan"))
                        QRScanner { scanned in
                            if let l = InviteLink(text: scanned) { link = l } else { error = String(localized: "That QR code is not a Group Balance invite.") }
                        }
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    #endif
                    GBSectionLabel(String(localized: "Or paste the invite link"))
                    GBTextField("groupbalance://join?…", text: $pasted, mono: true)
                    GBSecondaryButton(String(localized: "Continue")) {
                        if let l = InviteLink(text: pasted) { link = l } else { error = String(localized: "That is not a valid invite link.") }
                    }
                    .padding(.top, 12)
                }
                if let error {
                    Text(error).font(GBFont.secondary).foregroundStyle(GB.red).padding(.top, 16)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func join(_ link: InviteLink) {
        joining = true
        error = nil
        Task {
            defer { joining = false }
            do {
                try await model.join(link)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#if canImport(VisionKit) && os(iOS)
/// Live QR scanning with VisionKit. Not available in the simulator.
struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue {
                    scanner.stopScanning()
                    onScan(text)
                    return
                }
            }
        }
    }
}
#endif
