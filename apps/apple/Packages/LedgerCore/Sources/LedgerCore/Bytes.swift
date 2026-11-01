import Foundation

public extension Data {
    /// base64url without padding (PROTOCOL.md §2).
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.contains("=") else { return nil }
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}

public extension UUID {
    /// The 16 raw bytes.
    var bytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    /// Lowercase hyphenated form, the only form used in events.
    var lower: String { uuidString.lowercased() }

    /// A new UUIDv7 (RFC 9562): 48-bit Unix milliseconds, version, random.
    static func v7(now: Date = .now) -> UUID {
        var b = [UInt8](Data.random(16))
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        for i in 0..<6 { b[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        b[6] = (b[6] & 0x0F) | 0x70
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
