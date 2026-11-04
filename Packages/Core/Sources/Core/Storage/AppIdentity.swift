import Foundation

/// The identifiers this build is signed for: the App Group both targets share and the keychain
/// group name (after the team prefix). Both come from Info.plist keys that the build fills from
/// `APP_BUNDLE_IDENTIFIER`, the same setting the entitlements use, so a build under another
/// bundle id finds its own groups. The widget carries the app's values, not its own bundle id.
public struct AppIdentity: Sendable, Equatable {
    public static let appGroupKey = "AppGroupIdentifier"
    public static let keychainGroupKey = "KeychainGroupIdentifier"

    /// `group.<bundle id>`, or nil when Info.plist has no such key (tests, previews).
    public let appGroup: String?
    /// The app's private keychain group without the team prefix: `<bundle id>`. The code
    /// takes the groups from the signature.
    public let keychainGroup: String?

    public init(info: [String: Any]?) {
        func value(_ key: String) -> String? { (info?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        appGroup = value(Self.appGroupKey)
        keychainGroup = value(Self.keychainGroupKey)
    }

    /// This process's identity, from its own Info.plist.
    public static let main = AppIdentity(info: Bundle.main.infoDictionary)

    /// True in the widget extension (its bundle is an `.appex`), false in the app.
    public static let inExtension = Bundle.main.bundleURL.pathExtension == "appex"

    /// The named App Group when this process has a container for it, else nil.
    public static func usable(_ named: String?, hasContainer: (String) -> Bool) -> String? {
        named.flatMap { hasContainer($0) ? $0 : nil }
    }

    /// The App Group this process can open (its container exists), or nil when it has none.
    public static let usableAppGroup: String? = usable(main.appGroup) {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }
}
