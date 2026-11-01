import CryptoKit
import Foundation
import LedgerCore

public struct ServerError: Error, LocalizedError, Sendable {
    public var status: Int
    public var code: String
    public var message: String
    public var errorDescription: String? { "\(message) (\(status))" }
}

public struct ServerInfo: Decodable, Sendable {
    public var name: String
    public var version: String
    public var protocols: [Int]
}

/// The JSON API of PROTOCOL.md §5. Stateless; every call says which key signs.
public struct ServerClient: Sendable {
    public let base: URL
    let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func info() async throws -> ServerInfo {
        try await send("GET", "/v1/info", auth: .none)
    }

    public func createGroup(ownerToken: String, groupID: UUID, adminKey: Data) async throws {
        let _: Empty = try await send("POST", "/v1/groups", auth: .owner(ownerToken),
                                      body: ["groupId": groupID.lower, "adminKey": adminKey.base64URL])
    }

    public func createInvite(signer: Curve25519.Signing.PrivateKey, groupID: UUID, inviteKey: Data) async throws {
        let _: Empty = try await send("POST", "/v1/groups/\(groupID.lower)/invites", auth: .key(signer),
                                      body: ["inviteKey": inviteKey.base64URL])
    }

    public func revokeInvite(signer: Curve25519.Signing.PrivateKey, groupID: UUID, inviteKey: Data) async throws {
        let _: Empty = try await send("DELETE", "/v1/groups/\(groupID.lower)/invites/\(inviteKey.base64URL)", auth: .key(signer))
    }

    /// Register `member` using the one-time invite key.
    public func claim(invite: Curve25519.Signing.PrivateKey, member: Curve25519.Signing.PrivateKey, groupID: UUID) async throws {
        let proof = try member.signature(for: LedgerCrypto.claimInput(groupID: groupID, key: invite.publicKey.rawRepresentation))
        let _: Empty = try await send("POST", "/v1/groups/\(groupID.lower)/claim", auth: .key(invite),
                                      body: ["memberKey": member.publicKey.rawRepresentation.base64URL, "proof": proof.base64URL])
    }

    public func append(signer: Curve25519.Signing.PrivateKey, groupID: UUID, events: [SealedEvent]) async throws -> [UUID: UInt64] {
        struct Out: Decodable { var events: [Item]; struct Item: Decodable { var id: UUID; var seq: UInt64 } }
        let out: Out = try await send("POST", "/v1/groups/\(groupID.lower)/events", auth: .key(signer),
                                      body: ["events": events.map { ["id": $0.id.lower, "blob": $0.blob.base64URL] }])
        return Dictionary(out.events.map { ($0.id, $0.seq) }, uniquingKeysWith: { a, _ in a })
    }

    public func read(signer: Curve25519.Signing.PrivateKey, groupID: UUID, after: UInt64, limit: Int = 1000) async throws -> (events: [RawEvent], head: UInt64) {
        struct Out: Decodable {
            var events: [Item]
            var head: UInt64
            struct Item: Decodable { var seq: UInt64; var id: UUID; var blob: String }
        }
        let out: Out = try await send("GET", "/v1/groups/\(groupID.lower)/events?after=\(after)&limit=\(limit)", auth: .key(signer))
        let events = try out.events.map {
            guard let blob = Data(base64URL: $0.blob) else { throw ServerError(status: 0, code: "bad_blob", message: "Server sent an invalid blob") }
            return RawEvent(seq: $0.seq, id: $0.id, blob: blob)
        }
        return (events, out.head)
    }

    /// Heads announced by the server-sent event stream. Ends when the connection drops.
    public func heads(signer: Curve25519.Signing.PrivateKey, groupID: UUID) -> AsyncThrowingStream<UInt64, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request("GET", "/v1/groups/\(groupID.lower)/stream", auth: .key(signer), body: nil)
                    req.timeoutInterval = 90
                    let (bytes, res) = try await session.bytes(for: req)
                    guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
                        throw ServerError(status: (res as? HTTPURLResponse)?.statusCode ?? 0, code: "stream", message: "Live updates unavailable")
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        struct Head: Decodable { var seq: UInt64 }
                        if let h = try? JSONDecoder().decode(Head.self, from: Data(line.dropFirst(5).utf8)) {
                            continuation.yield(h.seq)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transport

    enum Auth {
        case none
        case owner(String)
        case key(Curve25519.Signing.PrivateKey)
    }

    struct Empty: Decodable {}

    struct ErrorBody: Decodable {
        var error: Inner
        struct Inner: Decodable { var code: String; var message: String }
    }

    func request(_ method: String, _ pathAndQuery: String, auth: Auth, body: Data?) throws -> URLRequest {
        let prefix = base.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = (prefix.isEmpty ? "" : "/" + prefix) + pathAndQuery
        guard let url = URL(string: full, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        switch auth {
        case .none: break
        case .owner(let token): req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .key(let signer):
            let ts = Int64(Date.now.timeIntervalSince1970)
            req.setValue(try LedgerCrypto.authorization(signer: signer, method: method, pathAndQuery: full, ts: ts, body: body ?? Data()),
                         forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func send<T: Decodable>(_ method: String, _ path: String, auth: Auth, body: Any? = nil) async throws -> T {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (out, res) = try await session.data(for: request(method, path, auth: auth, body: data))
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let e = try? JSONDecoder().decode(ErrorBody.self, from: out)
            throw ServerError(status: status, code: e?.error.code ?? "http_\(status)", message: e?.error.message ?? "Server error")
        }
        if T.self == Empty.self || out.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: out)
    }
}
