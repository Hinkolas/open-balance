import CryptoKit
import Foundation
import LedgerCore

/// `openbalance://join?v=1&s=<server>&g=<group>&m=<member>#k=<secret>&i=<invite seed>` (PROTOCOL.md §4).
public struct InviteLink: Sendable, Equatable {
    public var server: URL
    public var groupID: UUID
    public var memberID: MemberID
    public var secret: Data
    public var inviteSeed: Data

    public init(server: URL, groupID: UUID, memberID: MemberID, secret: Data, inviteSeed: Data) {
        self.server = server
        self.groupID = groupID
        self.memberID = memberID
        self.secret = secret
        self.inviteSeed = inviteSeed
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "openbalance"
        c.host = "join"
        c.queryItems = [
            .init(name: "v", value: "1"),
            .init(name: "s", value: server.absoluteString),
            .init(name: "g", value: groupID.lower),
            .init(name: "m", value: memberID),
        ]
        c.fragment = "k=\(secret.base64URL)&i=\(inviteSeed.base64URL)"
        return c.url!
    }

    public init?(_ url: URL) {
        guard url.scheme == "openbalance", url.host() == "join",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.queryItems, let fragment = c.fragment
        else { return nil }
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        var f: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { f[String(kv[0])] = String(kv[1]) }
        }
        guard q("v") == "1", let s = q("s"), let server = URL(string: s), ["https", "http"].contains(server.scheme),
              let g = q("g"), let group = UUID(uuidString: g), let m = q("m"), UUID(uuidString: m) != nil,
              let k = f["k"].flatMap(Data.init(base64URL:)), k.count == 32,
              let i = f["i"].flatMap(Data.init(base64URL:)), i.count == 32
        else { return nil }
        self.init(server: server, groupID: group, memberID: m.lowercased(), secret: k, inviteSeed: i)
    }

    /// Also accept the link pasted as text, with whitespace around it.
    public init?(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url)
    }
}
