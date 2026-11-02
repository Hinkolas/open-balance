import CryptoKit
import Foundation

/// A signed, encrypted event ready to append.
public struct SealedEvent: Sendable, Equatable, Codable {
    public var id: UUID
    public var body: Data
    public var blob: Data
    /// The epoch it is sealed with.
    public var epoch: UInt32? { LedgerCrypto.blobEpoch(blob) }
}

/// Writes events as one member of one group.
public struct EventWriter: Sendable {
    public let groupID: UUID
    public let author: MemberID
    /// The epoch this writer seals with.
    public let epoch: UInt32
    let encKey: SymmetricKey
    let signer: Curve25519.Signing.PrivateKey

    /// `secret` is the secret of `epoch`, the current epoch (§7.2).
    public init(groupID: UUID, secret: Data, epoch: UInt32 = 0, author: MemberID, signer: Curve25519.Signing.PrivateKey) throws {
        self.groupID = groupID
        self.author = author
        self.epoch = epoch
        self.encKey = try LedgerCrypto.encKey(secret: secret, groupID: groupID, epoch: epoch)
        self.signer = signer
    }

    public func write(_ data: EventData, seen: EventHeader.Seen, at: Date = .now, id: UUID = .v7()) throws -> SealedEvent {
        let header = EventHeader(v: 1, type: data.type, author: author, at: Self.timestamp(at), seen: seen)
        let body = try EventCoding.encode(header: header, data: data)
        let blob = try LedgerCrypto.seal(body: body, groupID: groupID, eventID: id, epoch: epoch, key: encKey, signer: signer)
        return SealedEvent(id: id, body: body, blob: blob)
    }

    /// The same event (id and body) sealed with this writer's epoch, for an
    /// unsent event written before a new epoch started (§5.4 step 10).
    public func reseal(_ e: SealedEvent) throws -> SealedEvent {
        let blob = try LedgerCrypto.seal(body: e.body, groupID: groupID, eventID: e.id, epoch: epoch, key: encKey, signer: signer)
        return SealedEvent(id: e.id, body: e.body, blob: blob)
    }

    static func timestamp(_ d: Date) -> String {
        d.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
            .replacingOccurrences(of: "+0000", with: "Z")
    }
}
