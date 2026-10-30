import XCTest
@testable import Core

/// The reset marker: starts refused while a reset runs, never for good, and a reset the app was
/// killed in finished (or stopped by the same locks) at the next launch.
final class ResetMarkerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testStartsAreRefusedOnlyWhileTheMarkerIsFresh() throws {
        let store = InMemorySecureStore()
        let marker = ResetMarker(store: store)
        XCTAssertFalse(marker.refusesStarts(at: t0), "no marker")
        XCTAssertNoThrow(try marker.checkStart(at: t0))
        try marker.begin(at: t0)
        XCTAssertTrue(marker.refusesStarts(at: t0))
        XCTAssertTrue(marker.refusesStarts(at: t0.addingTimeInterval(ResetMarker.staleAfter - 1)))
        XCTAssertThrowsError(try marker.checkStart(at: t0)) { XCTAssertEqual($0 as? AppReset.InProgress, AppReset.InProgress()) }
        XCTAssertFalse(marker.refusesStarts(at: t0.addingTimeInterval(ResetMarker.staleAfter)), "stale: never blocks for good")
        XCTAssertFalse(marker.refusesStarts(at: t0.addingTimeInterval(-ResetMarker.staleAfter - 1)), "clock set back far")
        try marker.end()
        XCTAssertFalse(marker.refusesStarts(at: t0))
    }

    func testAnUnreadableMarkerRefusesNothingAndResumesNothing() async throws {
        let store = InMemorySecureStore()
        try ResetMarker(store: store).begin(at: t0)
        store.failReads()
        XCTAssertFalse(ResetMarker(store: store).refusesStarts(at: t0))
        XCTAssertNil(ResetMarker(store: store).startedAt())
    }

    /// What the in-app button and the shortcut both show.
    func testTheRefusalSaysResetting() {
        XCTAssertEqual(AppReset.InProgress().localizedDescription, "正在重置")
    }

    func testStoredRecordsLock() throws {
        let store = InMemorySecureStore()
        XCTAssertNil(AppReset.storedLock(store: store))
        try StoredShowerVault(store: store).saveShowerState(ShowerState(phase: .running))
        XCTAssertNotNil(AppReset.storedLock(store: store))
        try StoredShowerVault(store: store).saveShowerState(nil)
        try store.write(Data("not json".utf8), for: .laundryCheckout)
        XCTAssertEqual(AppReset.storedLock(store: store), .recordsUnreadable)
    }

    @MainActor func resume(_ store: InMemorySecureStore, at now: Date, steps: inout [String]) async throws -> AppReset.Resumed? {
        let suite = "reset-resume-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var log: [String] = []
        let result = try await AppReset.resume(
            marker: ResetMarker(store: store), now: now,
            lock: { AppReset.storedLock(store: store) },
            signOut: { log.append("signOut") },
            clear: { log.append("clear"); try AppReset.clear(store: store, preferences: defaults, preferencesDomain: suite, files: []) },
            reload: { log.append("reload") })
        steps = log
        return result
    }

    /// Killed after the marker (part of the clear done or not): the next launch finishes it.
    @MainActor func testAnInterruptedResetCompletesOnRelaunch() async throws {
        let store = InMemorySecureStore()
        try ResetMarker(store: store).begin(at: t0)
        try StoredSchoolVault(store: store).saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try store.write(Data("x".utf8), for: .sharedSnapshot)
        var steps: [String] = []
        let resumed = try await resume(store, at: t0.addingTimeInterval(30), steps: &steps)
        XCTAssertEqual(resumed, .completed)
        XCTAssertEqual(steps, ["signOut", "clear", "reload"])
        for key in StoreKey.allCases { XCTAssertNil(try store.read(key), key.rawValue) }
    }

    /// The marker went stale and a shortcut started a shower; then the app is relaunched: the
    /// shower is left alone, the marker goes, and the caller is told why (「没有重置」).
    @MainActor func testAStaleMarkerAndAStartedShowerClearNothingOnRelaunch() async throws {
        let store = InMemorySecureStore()
        let marker = ResetMarker(store: store)
        try marker.begin(at: t0)
        let later = t0.addingTimeInterval(ResetMarker.staleAfter + 60)
        XCTAssertNoThrow(try marker.checkStart(at: later), "stale: the shortcut may start")
        let running = ShowerState(phase: .running, machineID: "11223344")
        try StoredShowerVault(store: store).saveShowerState(running)
        try StoredShowerVault(store: store).saveBinding(ShowerBinding(studentId: "S1234567", schoolId: "20021", machineId: "11223344", roomId: "R1", roomLabel: "99栋 991"))
        var steps: [String] = []
        let resumed = try await resume(store, at: later, steps: &steps)
        guard case .stopped(let lock)? = resumed else { return XCTFail("\(String(describing: resumed))") }
        XCTAssertNotNil(AppReset.storedLock(store: store))
        XCTAssertEqual(lock, AppReset.storedLock(store: store))
        XCTAssertEqual(steps, [], "nothing signed out, cleared or reloaded")
        XCTAssertEqual(try StoredShowerVault(store: store).showerState(), running)
        XCTAssertNotNil(try StoredShowerVault(store: store).binding())
        XCTAssertNil(marker.startedAt())
    }

    @MainActor func testNoMarkerNothingToResume() async throws {
        let store = InMemorySecureStore()
        try store.write(Data("x".utf8), for: .sharedSnapshot)
        var steps: [String] = []
        let resumed = try await resume(store, at: t0, steps: &steps)
        XCTAssertNil(resumed)
        XCTAssertEqual(steps, [])
        XCTAssertNotNil(try store.read(.sharedSnapshot))
    }
}
