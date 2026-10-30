import Foundation
import DailyCore
#if canImport(Security)
import Security
#endif

/// The SecItem calls, behind a protocol so the access-group fallback is testable without
/// touching the host Keychain. Status codes are `OSStatus` values.
public protocol KeychainBackend: Sendable {
    func copy(service: String, account: String, accessGroup: String?) -> (status: Int32, data: Data?)
    func add(service: String, account: String, accessGroup: String?, accessibility: StoreKey.Accessibility, data: Data) -> Int32
    func update(service: String, account: String, accessGroup: String?, accessibility: StoreKey.Accessibility, data: Data) -> Int32
    func delete(service: String, account: String, accessGroup: String?) -> Int32
}

public enum KeychainStatus {
    public static let success: Int32 = 0             // errSecSuccess
    public static let itemNotFound: Int32 = -25300   // errSecItemNotFound
    public static let duplicateItem: Int32 = -25299  // errSecDuplicateItem
    public static let missingEntitlement: Int32 = -34018 // errSecMissingEntitlement
}

/// Keychain store with the shared access group for widget-visible items.
///
/// Re-signed IPAs may lose the `keychain-access-groups` entitlement. When a write with the
/// access group fails, the store falls back to **no access group** (the app's default group)
/// and remembers that for later reads/writes; the widget then simply has no data, and the app
/// keeps working.
public final class KeychainSecureStore: SecureStore, @unchecked Sendable {
    // @unchecked: mutable state guarded by `lock`.
    private let backend: KeychainBackend
    private let accessGroup: String?
    private let lock = NSLock()
    private var groupUnavailable = false

    /// `accessGroup`: the resolved `<TeamPrefix>.com.beamjason.xiaorichang.shared`, or nil.
    public init(backend: KeychainBackend, accessGroup: String?) {
        self.backend = backend
        self.accessGroup = accessGroup
    }

    /// True once a group write failed and the store switched to no access group.
    public var isUsingFallback: Bool { lock.withLock { groupUnavailable } }

    private func group(for key: StoreKey) -> String? {
        guard key.isShared, let accessGroup else { return nil }
        return lock.withLock { groupUnavailable } ? nil : accessGroup
    }

    public func read(_ key: StoreKey) throws -> Data? {
        let group = group(for: key)
        var r = backend.copy(service: key.service, account: StoreKey.account, accessGroup: group)
        if group != nil, r.status == KeychainStatus.itemNotFound || r.status == KeychainStatus.missingEntitlement {
            // An earlier fallback write may have stored it without the group.
            r = backend.copy(service: key.service, account: StoreKey.account, accessGroup: nil)
        }
        switch r.status {
        case KeychainStatus.success: return r.data
        case KeychainStatus.itemNotFound: return nil
        default: throw StorageError(operation: "read \(key.rawValue)", status: r.status)
        }
    }

    public func write(_ data: Data, for key: StoreKey) throws {
        if let group = group(for: key) {
            if upsert(key, data, group) == KeychainStatus.success { return }
            lock.withLock { groupUnavailable = true }
        }
        let status = upsert(key, data, nil)
        guard status == KeychainStatus.success else { throw StorageError(operation: "write \(key.rawValue)", status: status) }
    }

    public func delete(_ key: StoreKey) throws {
        var statuses = [backend.delete(service: key.service, account: StoreKey.account, accessGroup: nil)]
        if key.isShared, let accessGroup {
            statuses.append(backend.delete(service: key.service, account: StoreKey.account, accessGroup: accessGroup))
        }
        if let bad = statuses.first(where: { $0 != KeychainStatus.success && $0 != KeychainStatus.itemNotFound && $0 != KeychainStatus.missingEntitlement }) {
            throw StorageError(operation: "delete \(key.rawValue)", status: bad)
        }
    }

    private func upsert(_ key: StoreKey, _ data: Data, _ group: String?) -> Int32 {
        let status = backend.add(service: key.service, account: StoreKey.account, accessGroup: group,
                                 accessibility: key.accessibility, data: data)
        guard status == KeychainStatus.duplicateItem else { return status }
        return backend.update(service: key.service, account: StoreKey.account, accessGroup: group,
                              accessibility: key.accessibility, data: data)
    }
}

#if canImport(Security)
/// The real SecItem backend (generic passwords). Not used by `swift test`.
public struct SecItemKeychainBackend: KeychainBackend {
    public init() {}

    private func base(_ service: String, _ account: String, _ group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private func accessible(_ a: StoreKey.Accessibility) -> CFString {
        switch a {
        case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    public func copy(service: String, account: String, accessGroup: String?) -> (status: Int32, data: Data?) {
        var q = base(service, account, accessGroup)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return (status, out as? Data)
    }

    public func add(service: String, account: String, accessGroup: String?, accessibility: StoreKey.Accessibility, data: Data) -> Int32 {
        var q = base(service, account, accessGroup)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = accessible(accessibility)
        return SecItemAdd(q as CFDictionary, nil)
    }

    public func update(service: String, account: String, accessGroup: String?, accessibility: StoreKey.Accessibility, data: Data) -> Int32 {
        let q = base(service, account, accessGroup)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible(accessibility)]
        return SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
    }

    public func delete(service: String, account: String, accessGroup: String?) -> Int32 {
        SecItemDelete(base(service, account, accessGroup) as CFDictionary)
    }
}
#endif

/// In-memory store for tests and previews, with injectable write failures.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoreKey: Data] = [:]
    private var failing: Set<StoreKey> = []

    public init() {}

    public func failWrites(to key: StoreKey, _ fail: Bool = true) {
        lock.withLock { if fail { failing.insert(key) } else { failing.remove(key) } }
    }

    public func read(_ key: StoreKey) throws -> Data? { lock.withLock { items[key] } }

    public func write(_ data: Data, for key: StoreKey) throws {
        try lock.withLock {
            if failing.contains(key) { throw StorageError(operation: "write \(key.rawValue)", status: -1) }
            items[key] = data
        }
    }

    public func delete(_ key: StoreKey) throws {
        try lock.withLock {
            if failing.contains(key) { throw StorageError(operation: "delete \(key.rawValue)", status: -1) }
            items[key] = nil
        }
    }
}
