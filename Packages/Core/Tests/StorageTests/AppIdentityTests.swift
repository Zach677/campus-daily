import XCTest
import Core

/// The App Group, the keychain groups and the background task id follow `APP_BUNDLE_IDENTIFIER`
/// (Info.plist and the entitlements are filled from it at build time) instead of being written
/// into the code.
final class AppIdentityTests: XCTestCase {
    func testIdentityComesFromTheInfoPlistKeys() {
        let identity = AppIdentity(info: ["AppGroupIdentifier": "group.org.example.daily",
                                          "KeychainGroupIdentifier": "org.example.daily"])
        XCTAssertEqual(identity.appGroup, "group.org.example.daily")
        XCTAssertEqual(identity.keychainGroup, "org.example.daily")
    }

    /// No keys (or empty ones): no App Group and no shared keychain group, never a guessed one.
    func testMissingKeysGiveNoGroups() {
        for info in [nil, [:], ["AppGroupIdentifier": "", "KeychainGroupIdentifier": ""]] as [[String: Any]?] {
            let identity = AppIdentity(info: info)
            XCTAssertNil(identity.appGroup)
            XCTAssertNil(identity.keychainGroup)
        }
    }

    /// The App Group is the one Info.plist names; without its container there is none, never
    /// one derived from the bundle id the process runs under.
    func testTheAppGroupIsOnlyTheNamedOne() {
        XCTAssertEqual(AppIdentity.usable("group.org.zaxh.xiaorichang") { _ in true }, "group.org.zaxh.xiaorichang")
        XCTAssertNil(AppIdentity.usable("group.org.zaxh.xiaorichang") { $0 != "group.org.zaxh.xiaorichang" })
        XCTAssertNil(AppIdentity.usable(nil) { _ in true })
    }

    /// With the bundle id in Base.xcconfig, every identifier is the one architecture §4.2 lists
    /// (org.zaxh.xiaorichang; Android keeps its own com.beamjason.xiaorichang).
    func testDefaultBundleIdGivesTheListedIdentifiers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let xcconfig = try String(contentsOf: root.appendingPathComponent("Configuration/Base.xcconfig"), encoding: .utf8)
        let line = try XCTUnwrap(xcconfig.split(separator: "\n").first { $0.hasPrefix("APP_BUNDLE_IDENTIFIER") })
        let bundleID = line.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        func plist(_ path: String) throws -> [String: Any] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .replacingOccurrences(of: "$(APP_BUNDLE_IDENTIFIER)", with: bundleID)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any], path)
        }
        let appInfo = try plist("App/Resources/Info.plist"), widgetInfo = try plist("Widget/Info.plist")
        let appEntitlements = try plist("App/Resources/App.entitlements")
        let widgetEntitlements = try plist("Widget/Widget.entitlements")

        let app = AppIdentity(info: appInfo)
        XCTAssertEqual(app.appGroup, "group.org.zaxh.xiaorichang")
        XCTAssertEqual(app.keychainGroup, "org.zaxh.xiaorichang")
        XCTAssertEqual(AppIdentity(info: widgetInfo), app, "the widget reads the app's groups, not its own bundle id")
        XCTAssertEqual(appInfo["BGTaskSchedulerPermittedIdentifiers"] as? [String], ["org.zaxh.xiaorichang.refresh"])

        for entitlements in [appEntitlements, widgetEntitlements] {
            XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String], ["group.org.zaxh.xiaorichang"])
        }
        XCTAssertEqual(appEntitlements["keychain-access-groups"] as? [String],
                       ["$(AppIdentifierPrefix)org.zaxh.xiaorichang", "$(AppIdentifierPrefix)org.zaxh.xiaorichang.shared"])
        XCTAssertEqual(widgetEntitlements["keychain-access-groups"] as? [String],
                       ["$(AppIdentifierPrefix)org.zaxh.xiaorichang.shared"])
    }

    /// Nothing in these files names the default identity: they carry only the build setting,
    /// neither today's bundle id nor the one iOS builds used before (still Android's).
    func testIdentifiersAreFilledFromTheBuildSetting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["App/Resources/Info.plist", "Widget/Info.plist", "App/Resources/App.entitlements", "Widget/Widget.entitlements"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for id in ["org.zaxh.xiaorichang", "com.beamjason.xiaorichang"] {
                XCTAssertFalse(text.contains(id), "\(path) names \(id)")
            }
        }
    }
}
