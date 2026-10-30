import Foundation
import Security

/// The one Keychain store the app and the widget share (no App Group).
public enum SharedKeychain {
    /// `<TeamPrefix>.com.beamjason.xiaorichang.shared`, resolved from this build's own signature.
    /// Nil when the prefix can't be read (re-signed without keychain groups): the store then keeps
    /// everything in the default group and the widget simply has no data.
    public static let accessGroup: String? = {
        let probe: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
                                   kSecAttrService as String:StoreKey.servicePrefix + "probe",
                                   kSecAttrAccount as String:StoreKey.account,
                                   kSecUseDataProtectionKeychain as String:true]
        var add = probe
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
        var query = probe
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let group = (out as? [String:Any])?[kSecAttrAccessGroup as String] as? String else { return nil }
        return accessGroup(teamPrefixedFrom:group)
    }()

    /// The group name after the team prefix, as listed in App.entitlements and Widget.entitlements
    /// (`$(AppIdentifierPrefix)com.beamjason.xiaorichang.shared`).
    public static let groupIdentifier = "com.beamjason.xiaorichang.shared"

    /// `<TeamPrefix>.` + `groupIdentifier`, taking the team prefix from any group this build wrote to.
    public static func accessGroup(teamPrefixedFrom group: String) -> String? {
        guard let dot = group.firstIndex(of:"."), dot != group.startIndex else { return nil }
        return String(group[..<dot]) + "." + groupIdentifier
    }

    public static let store: SecureStore = KeychainSecureStore(backend:SecItemKeychainBackend(), accessGroup:accessGroup)
}
