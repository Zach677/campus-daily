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
        defaults.set(true, forKey: "didSeeQuickSetup")
        let otherSuite = suite + "-other"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        otherDefaults.set("kept", forKey: "unrelated")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let water = folder.appendingPathComponent("Water", isDirectory: true)
        try FileManager.default.createDirectory(at: water, withIntermediateDirectories: true)
        try Data("imported".utf8).write(to: water.appendingPathComponent("imported.waterconfig"))
        let other = folder.appendingPathComponent("bundled-like.waterconfig")
        try Data("bundled".utf8).write(to: other)
        defer { try? FileManager.default.removeItem(at: folder) }

        try AppReset.clear(store: store, preferences: defaults, preferencesDomain: suite, files: [water, folder.appendingPathComponent("missing")])

        for key in StoreKey.allCases { XCTAssertNil(try store.read(key), key.rawValue) }
        XCTAssertNil(try school.account(), "the saved password is gone")
        XCTAssertNil(defaults.object(forKey: PreferenceKey.schoolLaundry))
        XCTAssertNil(defaults.object(forKey: PreferenceKey.reminder("cardLine")))
        XCTAssertNil(defaults.object(forKey: PreferenceKey.prefix + "laundry.machines"))
        XCTAssertNil(defaults.object(forKey: "didSeeQuickSetup"), "a preference without the xrc. prefix goes too")
        XCTAssertEqual(otherDefaults.string(forKey: "unrelated"), "kept")
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
        let suite = "reset-fail-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertThrowsError(try AppReset.clear(store: store, preferences: defaults, preferencesDomain: suite, files: [])) {
            XCTAssertEqual(($0 as? AppReset.Failure)?.items, ["school.password"])
        }
        for key in StoreKey.allCases where key != .schoolPassword { XCTAssertNil(try store.read(key), key.rawValue) }
    }

    /// An unfinished laundry order locks reset too; the shower reasons come first.
    func testResetWaitsForAnUnfinishedLaundryOrder() {
        XCTAssertNil(AppReset.lock(shower: .idle, laundry: LaundryPhase.none))
        XCTAssertNil(AppReset.lock(shower: nil, laundry: nil))
        for phase in LaundryPhase.allCases where phase != .none {
            XCTAssertEqual(AppReset.lock(shower: .idle, laundry: phase), .laundry, "\(phase)")
        }
        XCTAssertEqual(AppReset.lock(shower: nil, laundry: LaundryPhase.none, laundryBusy: true), .laundry)
        XCTAssertEqual(AppReset.lock(shower: ShowerState(phase: .running), laundry: .active), .showering)
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

    func testUnreadableRecordsAndAControllerCheckLockReset() {
        XCTAssertEqual(AppReset.lock(shower: .idle, recordsUnreadable: true), .recordsUnreadable)
        XCTAssertEqual(AppReset.lock(shower: ShowerState(phase: .running), recordsUnreadable: true), .recordsUnreadable)
        XCTAssertEqual(AppReset.lock(shower: .idle, checkingController: true), .checkingController)
        XCTAssertEqual(AppReset.lock(shower: ShowerState(phase: .running), checkingController: true), .showering)
        XCTAssertNil(AppReset.lock(shower: .idle, recordsUnreadable: false, checkingController: false))
    }

    /// lock → sign out → lock again → clear → reload.
    @MainActor func testResetRunsItsStepsInOrder() async throws {
        var steps: [String] = []
        let stopped = try await AppReset.run(lock: { steps.append("lock"); return nil },
                                             signOut: { steps.append("signOut") },
                                             clear: { steps.append("clear") },
                                             reload: { steps.append("reload") })
        XCTAssertNil(stopped)
        XCTAssertEqual(steps, ["lock", "signOut", "lock", "clear", "reload"])
    }

    @MainActor func testALockFirstDoesNothing() async throws {
        var steps: [String] = []
        let stopped = try await AppReset.run(lock: { .laundry }, signOut: { steps.append("signOut") },
                                             clear: { steps.append("clear") }, reload: { steps.append("reload") })
        XCTAssertEqual(stopped, .laundry)
        XCTAssertEqual(steps, [])
    }

    /// A shower started while sign-out waited: nothing is cleared.
    @MainActor func testALockAfterSignOutStopsBeforeClearing() async throws {
        var steps: [String] = []
        var showering = false
        let stopped = try await AppReset.run(lock: { showering ? .showering : nil },
                                             signOut: { steps.append("signOut"); showering = true },
                                             clear: { steps.append("clear") }, reload: { steps.append("reload") })
        XCTAssertEqual(stopped, .showering)
        XCTAssertEqual(steps, ["signOut", "reload"])
    }

    @MainActor func testAFailedClearStillReloadsAndReports() async {
        var reloaded = false
        do {
            _ = try await AppReset.run(lock: { nil }, signOut: {}, clear: { throw AppReset.Failure(items: ["x"]) },
                                       reload: { reloaded = true })
            XCTFail("expected the failure")
        } catch { XCTAssertEqual(error as? AppReset.Failure, AppReset.Failure(items: ["x"])) }
        XCTAssertTrue(reloaded)
    }
}
