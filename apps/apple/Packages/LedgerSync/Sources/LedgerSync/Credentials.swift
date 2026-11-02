import CryptoKit
import Foundation
import LedgerCore
import Security

/// Everything a device needs to act as one member of one group. Stored in the
/// Keychain, synced through iCloud Keychain to the person's other devices.
public struct GroupCredentials: Codable, Sendable, Equatable, Identifiable {
    public var server: URL
    public var groupID: UUID
    public var secret: Data
    public var memberID: MemberID
    public var memberSeed: Data
    /// Invite seeds of members this device (as admin) added and that have not
    /// claimed yet, so their QR can be shown again.
    public var invites: [MemberID: Data] = [:]
    /// Seed of the pending invite this device made for a further device of
    /// its own member, so its QR can be shown again.
    public var deviceInvite: Data?
    /// The server accepted our member key (claim done or we created the group).
    public var registered: Bool
    public var addedAt: Date

    public var id: UUID { groupID }

    public var signer: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: memberSeed) }
    }

    public init(server: URL, groupID: UUID, secret: Data, memberID: MemberID, memberSeed: Data, registered: Bool) {
        self.server = server
        self.groupID = groupID
        self.secret = secret
        self.memberID = memberID
        self.memberSeed = memberSeed
        self.registered = registered
        self.addedAt = .now
    }
}

/// Generic-password Keychain items holding JSON. Items are synchronizable
/// (iCloud Keychain, end-to-end encrypted) and readable after first unlock.
public struct KeychainStore: Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error \(status)" }
    }

    let service: String

    public static let groups = KeychainStore(service: "io.github.hinkolas.openbalance.group")
    public static let servers = KeychainStore(service: "io.github.hinkolas.openbalance.server-owner")

    public init(service: String) { self.service = service }

    private func base(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        var s = SecItemAdd(add as CFDictionary, nil)
        if s == errSecMissingEntitlement || s == -34018 {
            // No iCloud Keychain (e.g. unsigned simulator builds): keep it on this device.
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            s = SecItemAdd(add as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw Failure(status: s) }
    }

    public func load<T: Decodable>(_: T.Type, account: String) -> T? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func all<T: Decodable>(_: T.Type) -> [T] {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [Data] else { return [] }
        return items.compactMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

/// A server this device may create groups on.
public struct ServerOwnership: Codable, Sendable, Equatable, Identifiable {
    public var server: URL
    public var token: String
    public var name: String
    public var id: URL { server }
    public init(server: URL, token: String, name: String) {
        self.server = server
        self.token = token
        self.name = name
    }
}

/// Where group credentials live. The app uses the Keychain; tests keep them in memory.
public protocol CredentialStore: Sendable {
    func save(_ credentials: GroupCredentials) throws
    func delete(_ groupID: UUID)
    func all() -> [GroupCredentials]
}

public struct KeychainCredentialStore: CredentialStore {
    public init() {}
    public func save(_ c: GroupCredentials) throws { try KeychainStore.groups.save(c, account: c.groupID.lower) }
    public func delete(_ id: UUID) { KeychainStore.groups.delete(account: id.lower) }
    public func all() -> [GroupCredentials] { KeychainStore.groups.all(GroupCredentials.self) }
}

public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: GroupCredentials] = [:]
    public init() {}
    public func save(_ c: GroupCredentials) throws { lock.withLock { items[c.groupID] = c } }
    public func delete(_ id: UUID) { _ = lock.withLock { items.removeValue(forKey: id) } }
    public func all() -> [GroupCredentials] { lock.withLock { Array(items.values) } }
}
