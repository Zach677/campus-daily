import Foundation
import Security

/// The Keychain store of this process (no App Group). The app lists two groups in App.entitlements:
/// its private group first (the default for writes without a group), then the shared group, which
/// is the only one Widget.entitlements lists.
public enum SharedKeychain {
    /// The group a write without a group lands in, read from this build's own signature: the
    /// private group in the app, the shared group in the widget. Nil when it can't be read.
    public static let defaultGroup: String? = {
        let probe: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
                                   kSecAttrService as String:StoreKey.servicePrefix + "probe",
                                   kSecAttrAccount as String:StoreKey.account,
                                   kSecUseDataProtectionKeychain as String:true]
        // Older builds left a probe in the shared group; start clean so the answer is today's default.
        SecItemDelete(probe as CFDictionary)
        var add = probe
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemAdd(add as CFDictionary, &out) == errSecSuccess else { return nil }
        return (out as? [String:Any])?[kSecAttrAccessGroup as String] as? String
    }()

    /// `<TeamPrefix>.com.beamjason.xiaorichang.shared`. Nil when the prefix can't be read
    /// (re-signed without keychain groups): the store then keeps everything in the default group
    /// and the widget simply has no data.
    public static let accessGroup: String? = defaultGroup.flatMap { accessGroup(teamPrefixedFrom:$0) }

    /// The app's private group, or nil in the widget (its default group is the shared one).
    public static let privateGroup: String? = defaultGroup.flatMap { privateGroup(defaultGroup:$0) }

    /// The group names after the team prefix, as listed in App.entitlements and Widget.entitlements.
    public static let groupIdentifier = "com.beamjason.xiaorichang.shared"
    public static let privateGroupIdentifier = "com.beamjason.xiaorichang"

    /// `<TeamPrefix>.` + `groupIdentifier`, taking the team prefix from any group this build wrote to.
    public static func accessGroup(teamPrefixedFrom group: String) -> String? {
        guard let dot = group.firstIndex(of:"."), dot != group.startIndex else { return nil }
        return String(group[..<dot]) + "." + groupIdentifier
    }

    /// The default group is private unless it is the shared group itself.
    public static func privateGroup(defaultGroup group: String) -> String? {
        group == accessGroup(teamPrefixedFrom:group) ? nil : group
    }

    public static let keychainStore = KeychainSecureStore(backend:SecItemKeychainBackend(), accessGroup:accessGroup,
                                                          privateGroup:privateGroup)
    public static var store: SecureStore { keychainStore }

    /// Moves private items an older build left in the shared group; call once at app launch.
    @discardableResult
    public static func migratePrivateItems() -> [StoreKey] { keychainStore.migratePrivateItems() }
}
