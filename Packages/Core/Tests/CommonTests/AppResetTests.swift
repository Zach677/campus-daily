import XCTest
@testable import Core

final class AppResetTests: XCTestCase {
    /// Every stored item, the saved school password included, is gone after a reset; files the
    /// app wrote are deleted and other files are left alone.
    func testResetClearsEverySeededItem() throws {
        let store = InMemorySecureStore()
        let school = StoredSchoolVault(store: store)
        try school.savePortalToken(PortalToken("PORTAL", expiresAt: Date(timeIntervalSince1970: 1_800_000_000)))
        try school.saveEcyktSession(EcyktSession(token: "t", syscustid: "s"))
        try school.saveProfile(SchoolProfile(residence: PortalResidence(raw: "示例校区99栋9号1层991房")))
        try school.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try school.saveLoginDeviceID("99000000000000000000000000000991")
        for key in StoreKey.allCases where try store.read(key) == nil { try store.write(Data(key.rawValue.utf8), for: key) }
        for key in StoreKey.allCases { XCTAssertNotNil(try store.read(key), "seeded \(key.rawValue)") }

        let suite = "reset-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PreferenceKey.schoolLaundry)
        defaults.set(20, forKey: PreferenceKey.reminder("cardLine"))
        defaults.set("x", forKey: PreferenceKey.prefix + "laundry.machines")
        defaults.set("kept", forKey: "AppleLanguages-test")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let water = folder.appendingPathComponent("Water", isDirectory: true)
        try FileManager.default.createDirectory(at: water, withIntermediateDirectories: true)
        try Data("imported".utf8).write(to: water.appendingPathComponent("imported.waterconfig"))
        let other = folder.appendingPathComponent("bundled-like.waterconfig")
        try Data("bundled".utf8).write(to: other)
        defer { try? FileManager.default.removeItem(at: folder) }

        try AppReset.clear(store: store, preferences: defaults, files: [water, folder.appendingPathComponent("missing")])

        for key in StoreKey.allCases { XCTAssertNil(try store.read(key), key.rawValue) }
        XCTAssertNil(try school.account(), "the saved password is gone")
        XCTAssertNil(defaults.object(forKey: PreferenceKey.schoolLaundry))
        XCTAssertNil(defaults.object(forKey: PreferenceKey.reminder("cardLine")))
        XCTAssertNil(defaults.object(forKey: PreferenceKey.prefix + "laundry.machines"))
        XCTAssertEqual(defaults.string(forKey: "AppleLanguages-test"), "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: water.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    /// A new Keychain item is cleared by reset too; this count makes adding one a conscious step.
    func testResetCoversEveryKeychainItem() {
        XCTAssertEqual(Set(AppReset.keychainItems), Set(StoreKey.allCases))
        XCTAssertEqual(AppReset.keychainItems.count, 11, "a new item: check reset clears it, then update this count")
    }

    func testFailedDeleteIsReportedAndTheRestStillCleared() throws {
        let store = InMemorySecureStore()
        for key in StoreKey.allCases { try store.write(Data("x".utf8), for: key) }
        store.failWrites(to: .schoolPassword)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reset-fail-" + UUID().uuidString))
        XCTAssertThrowsError(try AppReset.clear(store: store, preferences: defaults, files: [])) {
            XCTAssertEqual(($0 as? AppReset.Failure)?.items, ["school.password"])
        }
        for key in StoreKey.allCases where key != .schoolPassword { XCTAssertNil(try store.read(key), key.rawValue) }
    }

    func testResetWaitsForTheShowerAndItsSettlement() {
        XCTAssertNil(AppReset.lock(shower: nil))
        XCTAssertNil(AppReset.lock(shower: .idle))
        XCTAssertNil(AppReset.lock(shower: ShowerState(phase: .done)))
        XCTAssertNil(AppReset.lock(shower: ShowerState(phase: .failed, failure: ShowerFailure(reason: .deviceUnavailable, needsReview: false))))
        for phase in [ShowerPhase.authorizing, .writePending, .running, .closing, .settling] {
            XCTAssertEqual(AppReset.lock(shower: ShowerState(phase: phase)), .showering, "\(phase)")
        }
        XCTAssertEqual(AppReset.lock(shower: ShowerState(phase: .failed, failure: ShowerFailure(reason: .settleUncertain, needsReview: true))),
                       .unsettled)
        XCTAssertEqual(AppReset.lock(shower: ShowerState(phase: .running, stateReviewRequired: true)), .unsettled)
    }
}
