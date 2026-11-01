import CryptoKit
import Foundation

/// A signed, encrypted event ready to append.
public struct SealedEvent: Sendable, Equatable, Codable {
    public var id: UUID
    public var body: Data
    public var blob: Data
}

/// Writes events as one member of one group.
public struct EventWriter: Sendable {
    public let groupID: UUID
    public let author: MemberID
    let encKey: SymmetricKey
    let signer: Curve25519.Signing.PrivateKey

    public init(groupID: UUID, secret: Data, author: MemberID, signer: Curve25519.Signing.PrivateKey) throws {
        self.groupID = groupID
        self.author = author
        self.encKey = try LedgerCrypto.encKey(secret: secret, groupID: groupID)
        self.signer = signer
    }

    public func write(_ data: EventData, seen: EventHeader.Seen, at: Date = .now, id: UUID = .v7()) throws -> SealedEvent {
        let header = EventHeader(v: 1, type: data.type, author: author, at: Self.timestamp(at), seen: seen)
        let body = try EventCoding.encode(header: header, data: data)
        let blob = try LedgerCrypto.seal(body: body, groupID: groupID, eventID: id, key: encKey, signer: signer)
        return SealedEvent(id: id, body: body, blob: blob)
    }

    static func timestamp(_ d: Date) -> String {
        d.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
            .replacingOccurrences(of: "+0000", with: "Z")
    }
}
