import Foundation
import LedgerCore

/// `openbalance://recover?v=1&s=<server>&g=<group>&m=<admin>#k=<secret>&r=<recovery seed>`
/// (PROTOCOL.md §4.2). The admin keeps it outside the app; it is as powerful
/// as the admin's devices.
public struct RecoveryLink: Sendable, Equatable {
    public var server: URL
    public var groupID: UUID
    public var adminID: MemberID
    public var secret: Data
    public var recoverySeed: Data

    public init(server: URL, groupID: UUID, adminID: MemberID, secret: Data, recoverySeed: Data) {
        self.server = server
        self.groupID = groupID
        self.adminID = adminID
        self.secret = secret
        self.recoverySeed = recoverySeed
    }

    public var url: URL {
        LinkCoding.url(host: "recover", query: [("s", server.absoluteString), ("g", groupID.lower), ("m", adminID)],
                       fragment: "k=\(secret.base64URL)&r=\(recoverySeed.base64URL)")
    }

    public init?(_ url: URL) {
        guard let (q, f) = LinkCoding.parse(url, host: "recover"), let server = LinkCoding.server(q["s"]),
              let g = q["g"], let group = UUID(uuidString: g), let m = q["m"], UUID(uuidString: m) != nil,
              let k = LinkCoding.bytes32(f["k"]), let r = LinkCoding.bytes32(f["r"])
        else { return nil }
        self.init(server: server, groupID: group, adminID: m.lowercased(), secret: k, recoverySeed: r)
    }

    public init?(text: String) {
        guard let url = LinkCoding.url(text) else { return nil }
        self.init(url)
    }
}

/// `openbalance://create?v=1&s=<server>#c=<code>` (PROTOCOL.md §4.3): the
/// server owner lets someone create one group.
public struct CreationLink: Sendable, Equatable {
    public var server: URL
    public var code: String

    public init(server: URL, code: String) {
        self.server = server
        self.code = code
    }

    public var url: URL {
        LinkCoding.url(host: "create", query: [("s", server.absoluteString)], fragment: "c=\(code)")
    }

    public init?(_ url: URL) {
        guard let (q, f) = LinkCoding.parse(url, host: "create"), let server = LinkCoding.server(q["s"]),
              let c = f["c"], LinkCoding.bytes32(c) != nil
        else { return nil }
        self.init(server: server, code: c)
    }

    public init?(text: String) {
        guard let url = LinkCoding.url(text) else { return nil }
        self.init(url)
    }
}

/// Any link the app opens.
public enum AppLink: Sendable, Equatable {
    case invite(InviteLink)
    case recovery(RecoveryLink)
    case creation(CreationLink)

    public init?(_ url: URL) {
        if let l = InviteLink(url) { self = .invite(l) }
        else if let l = RecoveryLink(url) { self = .recovery(l) }
        else if let l = CreationLink(url) { self = .creation(l) }
        else { return nil }
    }

    public init?(text: String) {
        guard let url = LinkCoding.url(text) else { return nil }
        self.init(url)
    }
}

enum LinkCoding {
    static func url(host: String, query: [(String, String)], fragment: String) -> URL {
        var c = URLComponents()
        c.scheme = "openbalance"
        c.host = host
        c.queryItems = [.init(name: "v", value: "1")] + query.map { .init(name: $0.0, value: $0.1) }
        c.fragment = fragment
        return c.url!
    }

    /// Query and fragment of a v1 link for `host`.
    static func parse(_ url: URL, host: String) -> ([String: String], [String: String])? {
        guard url.scheme == "openbalance", url.host() == host,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.queryItems, let fragment = c.fragment
        else { return nil }
        var q: [String: String] = [:]
        for item in items where q[item.name] == nil { q[item.name] = item.value }
        var f: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { f[String(kv[0])] = String(kv[1]) }
        }
        guard q["v"] == "1" else { return nil }
        return (q, f)
    }

    static func server(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s), ["https", "http"].contains(url.scheme) else { return nil }
        return url
    }

    static func bytes32(_ s: String?) -> Data? {
        guard let d = s.flatMap(Data.init(base64URL:)), d.count == 32 else { return nil }
        return d
    }

    /// The link pasted as text, with whitespace around it.
    static func url(_ text: String) -> URL? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
