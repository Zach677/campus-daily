import XCTest
import Core

private final class MemoryPreferences: PreferenceStorage {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// Settings › 外观 › 主题: stored on this phone, 暖橙 until the user picks 清爽.
final class ThemePreferenceTests: XCTestCase {
    func testDefaultIsWarm() {
        XCTAssertEqual(ThemePreference(storage: MemoryPreferences()).theme, .warm)
        XCTAssertEqual(AppTheme.standard, .warm)
    }

    func testChoiceRoundTripsUnderItsOwnKey() {
        let storage = MemoryPreferences()
        storage.values[PreferenceKey.schoolLaundry] = false
        let preference = ThemePreference(storage: storage)
        preference.set(.clear)
        XCTAssertEqual(preference.theme, .clear)
        XCTAssertEqual(ThemePreference(storage: storage).theme, .clear, "a new reader sees it")
        preference.set(.warm)
        XCTAssertEqual(preference.theme, .warm)
        XCTAssertEqual(storage.values[ThemePreference.key] as? String, "warm")
        XCTAssertEqual(storage.values[PreferenceKey.schoolLaundry] as? Bool, false, "other preferences kept")
        XCTAssertEqual(ThemePreference.key, "xrc.theme")
    }

    func testUnknownOrMistypedValueIsWarm() {
        let storage = MemoryPreferences()
        storage.values[ThemePreference.key] = "classic"
        XCTAssertEqual(ThemePreference(storage: storage).theme, .warm)
        storage.values[ThemePreference.key] = ""
        XCTAssertEqual(ThemePreference(storage: storage).theme, .warm)
        storage.values[ThemePreference.key] = 1
        XCTAssertEqual(ThemePreference(storage: storage).theme, .warm)
        storage.values[ThemePreference.key] = "clear"
        XCTAssertEqual(ThemePreference(storage: storage).theme, .clear)
    }

    func testStoredThroughUserDefaults() throws {
        let suite = "ThemePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ThemePreference(storage: defaults).set(.clear)
        XCTAssertEqual(ThemePreference(storage: try XCTUnwrap(UserDefaults(suiteName: suite))).theme, .clear)
    }

    /// No App Group (tests, a re-signed install without one): this process's own preferences.
    func testSharedStorageWithoutAGroupIsTheProcessOwn() {
        XCTAssertTrue(ThemePreference.sharedStorage(appGroup: nil) === UserDefaults.standard)
    }

    func testNamesAndCopy() {
        XCTAssertEqual(AppTheme.allCases, [.warm, .clear])
        XCTAssertEqual(AppTheme.warm.name, "暖橙")
        XCTAssertEqual(AppTheme.clear.name, "清爽")
        XCTAssertEqual(AppTheme.warm.settingsRowLabel, "主题，暖橙")
        XCTAssertEqual(AppTheme.clear.unavailableLabel, "清爽，暂时不能选")
        XCTAssertEqual(AppTheme.warm.summary, "暖色，数字大，一眼看清电量和余额。")
        XCTAssertEqual(AppTheme.clear.summary, "原作者的设计，系统原生的样子。")
        XCTAssertEqual(AppTheme.footer, "只换样子，内容和用法都一样。小组件、锁屏和灵动岛也会跟着换。")
    }
}
