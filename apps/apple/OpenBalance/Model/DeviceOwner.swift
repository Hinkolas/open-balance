import Foundation
import LocalAuthentication

/// Asks for Face ID, Touch ID or the device passcode before showing an invite,
/// so someone holding an unlocked phone can't hand themselves access to a group.
/// A UI gate only: group secrets and member keys stay readable after first
/// unlock so sync and iCloud Keychain keep working (PROTOCOL §3.2).
enum DeviceOwner {
    /// True when the owner confirmed, or the device has no passcode to check against.
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.domain == LAErrorDomain && error?.code == LAError.Code.passcodeNotSet.rawValue
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
