import Foundation
import Security

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

/// Keychain store with two access groups: the shared group the widget can read, for keys whose
/// `isShared` is true, and the app's private group for everything else.
///
/// Re-signed IPAs may lose the `keychain-access-groups` entitlement. When a write with a group
/// fails with `errSecMissingEntitlement`, the store falls back to **no access group** (the
/// default group) for that group and remembers it for later reads/writes; the widget then simply
/// has no data, and the app keeps working. Any other write failure (a locked device, say) is
/// thrown and changes nothing for later writes.
public final class KeychainSecureStore: SecureStore, @unchecked Sendable {
    // @unchecked: mutable state guarded by `lock`.
    private let backend: KeychainBackend
    private let groups: @Sendable () -> (shared: String?, private: String?)
    private let lock = NSLock()
    private var unavailable: Set<String> = []

    /// `accessGroup`: the resolved `<TeamPrefix>.<bundle id>.shared`, or nil.
    /// `privateGroup`: the resolved app-only group, or nil (the widget, or unknown): private items
    /// then use the default group.
    public init(backend: KeychainBackend, accessGroup: String?, privateGroup: String? = nil) {
        self.backend = backend
        let resolved = (shared: accessGroup, private: privateGroup == accessGroup ? nil : privateGroup)
        self.groups = { resolved }
    }

    /// Groups resolved on each use from `probe`, so a probe that failed early (before the first
    /// unlock) is retried instead of fixing the groups for the whole process.
    public init(backend: KeychainBackend, groups probe: KeychainGroupProbe) {
        self.backend = backend
        self.groups = {
            let shared = probe.sharedGroup, own = probe.privateGroup
            return (shared, own == shared ? nil : own)
        }
    }

    private var sharedGroup: String? { groups().shared }
    private var privateGroup: String? { groups().private }

    private func usable(_ group: String?) -> String? {
        guard let group else { return nil }
        return lock.withLock { unavailable.contains(group) } ? nil : group
    }

    private func group(for key: StoreKey) -> String? {
        usable(key.isShared ? sharedGroup : privateGroup)
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
            let status = upsert(key, data, group)
            if status == KeychainStatus.success { return }
            guard status == KeychainStatus.missingEntitlement else {
                throw StorageError(operation: "write \(key.rawValue)", status: status)
            }
            lock.withLock { _ = unavailable.insert(group) }
        }
        let status = upsert(key, data, nil)
        guard status == KeychainStatus.success else { throw StorageError(operation: "write \(key.rawValue)", status: status) }
    }

    public func delete(_ key: StoreKey) throws {
        var statuses = [backend.delete(service: key.service, account: StoreKey.account, accessGroup: nil)]
        for group in [sharedGroup, privateGroup].compactMap({ $0 }) {
            statuses.append(backend.delete(service: key.service, account: StoreKey.account, accessGroup: group))
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
