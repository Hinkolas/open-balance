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
            Form {
                if let link {
                    Section {
                        LabeledContent("Server", value: link.server.host() ?? link.server.absoluteString)
                    } footer: {
                        Text("You join as the member this invite is for. Your key stays on your devices and in your iCloud Keychain.")
                    }
                } else {
                    #if canImport(VisionKit) && os(iOS)
                    if DataScannerViewController.isSupported {
                        Section("Scan the QR code") {
                            QRScanner { scanned in
                                if let l = InviteLink(text: scanned) { link = l } else { error = String(localized: "That QR code is not a Group Balance invite.") }
                            }
                            .frame(height: 260)
                            .listRowInsets(EdgeInsets())
                        }
                    }
                    #endif
                    Section {
                        TextField("groupbalance://join?…", text: $pasted, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: pasted) { _, v in
                                if let l = InviteLink(text: v) { link = l; error = nil }
                            }
                        PasteButton(payloadType: String.self) { strings in
                            if let s = strings.first { pasted = s }
                        }
                    } header: {
                        Text("Or paste the invite link")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.negative) }
                }
            }
            .navigationTitle("Join a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if joining {
                        ProgressView()
                    } else {
                        Button("Join") { if let link { join(link) } }.disabled(link == nil)
                    }
                }
            }
        }
        .tint(Theme.tint)
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
