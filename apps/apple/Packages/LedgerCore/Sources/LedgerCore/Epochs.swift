import CryptoKit
import Foundation

/// Starting epochs and sealing keyrings (PROTOCOL.md §3.5, §7.2).
public enum Epochs {
    /// `group.epoch_started` for `epoch` with a fresh secret sealed to every
    /// reader. Returns the event data and the secret.
    public static func start(epoch: UInt32, readers: Set<Data>, groupID: UUID) throws -> (GroupEpochStarted, Data) {
        let secret = Data.random(32)
        let m = LedgerCrypto.u32(epoch) + secret
        let keys = try readers.sorted { $0.lexicographicallyPrecedes($1) }.map { reader in
            GroupEpochStarted.Entry(key: reader.base64URL,
                                    secret: try LedgerCrypto.seal(m, to: reader, label: LedgerCrypto.labelEpoch, groupID: groupID).base64URL)
        }
        return (GroupEpochStarted(epoch: epoch, keys: keys), secret)
    }

    /// Every epoch secret so far, sealed to a box key (an invite's or the recovery key's).
    public static func sealKeyring(_ secrets: [Data], to box: Data, groupID: UUID) throws -> Data {
        try LedgerCrypto.seal(secrets.reduce(Data(), +), to: box, label: LedgerCrypto.labelKeyring, groupID: groupID)
    }

    /// The epoch secrets in a keyring sealed to `box`.
    public static func openKeyring(_ sealed: Data, box: Curve25519.KeyAgreement.PrivateKey, groupID: UUID) throws -> [Data] {
        let m = try LedgerCrypto.open(sealed: sealed, box: box, label: LedgerCrypto.labelKeyring, groupID: groupID)
        guard !m.isEmpty, m.count % 32 == 0 else { throw LedgerCrypto.Failure.badPlaintext }
        return stride(from: 0, to: m.count, by: 32).map { Data(m[m.startIndex + $0 ..< m.startIndex + $0 + 32]) }
    }
}
