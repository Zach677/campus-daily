import XCTest
@testable import Core

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_300_000)
    var now: Date { lock.withLock { current } }
    func advance(_ s: TimeInterval) { lock.withLock { current = current.addingTimeInterval(s) } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}

final class RefreshLeaseTests: XCTestCase {
    let store = InMemorySecureStore()
    let clock = TestClock()
    func lease(_ owner: String) -> RefreshLease { RefreshLease(store: store, owner: owner, now: clock.function) }

    func testOneHolderAtATime() {
        let app = lease("app-1"), widget = lease("widget-1")
        XCTAssertTrue(app.acquire())
        XCTAssertFalse(widget.acquire())
        XCTAssertTrue(app.holds())
        XCTAssertFalse(widget.holds())
        app.release()
        XCTAssertTrue(widget.acquire())
        XCTAssertFalse(app.acquire())
    }

    /// A holder that died leaves its lease to run out; then the next process takes it.
    func testStaleLeaseExpires() {
        let app = lease("app-1"), widget = lease("widget-1")
        XCTAssertTrue(app.acquire())
        clock.advance(RefreshLease.defaultDuration - 1)
        XCTAssertFalse(widget.acquire())
        clock.advance(1)
        XCTAssertTrue(widget.acquire())
        XCTAssertFalse(app.holds())
        XCTAssertFalse(app.renew(), "the old holder finds out before it mints")
    }

    func testRenewPushesTheExpiry() {
        let app = lease("app-1"), widget = lease("widget-1")
        XCTAssertTrue(app.acquire())
        clock.advance(50)
        XCTAssertTrue(app.renew())
        clock.advance(50)
        XCTAssertFalse(widget.acquire())
        XCTAssertTrue(app.holds())
    }

    func testReleaseNeverRemovesSomeoneElsesLease() {
        let app = lease("app-1"), widget = lease("widget-1")
        XCTAssertTrue(widget.acquire())
        app.release()
        XCTAssertTrue(widget.holds())
    }

    /// An unreadable record or one set far ahead (clock moved back) can't block refreshes.
    func testGarbageOrFarFutureLeaseIsStale() throws {
        try store.write(Data("garbage".utf8), for: .sharedRefreshLease)
        XCTAssertTrue(lease("app-1").acquire())
        let far = try JSONEncoder().encode(RefreshLease.Record(owner: "widget-9", expiresAt: clock.now.addingTimeInterval(3600)))
        try store.write(far, for: .sharedRefreshLease)
        XCTAssertTrue(lease("app-1").acquire())
    }

    /// The Keychain can't be written (locked before the first unlock): no lease, no refresh.
    func testUnwritableStoreGivesNoLease() {
        store.failWrites(to: .sharedRefreshLease)
        XCTAssertFalse(lease("app-1").acquire())
    }

    func testOwnerIdsAreRandomPerProcess() {
        let a = RefreshLease.owner("widget"), b = RefreshLease.owner("widget")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("widget-"))
    }
}

/// Two refreshers (app and widget) over one store.
final class TwoRefresherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)
    let t2 = Date(timeIntervalSince1970: 3_000)

    func refresher(_ reader: SchoolReader, _ mem: InMemorySecureStore, owner: String, wait: TimeInterval = 400) -> SnapshotRefresher {
        SnapshotRefresher(school: reader, store: SharedSnapshotStore(store: mem),
                          lease: RefreshLease(store: mem, owner: owner, now: { Date(timeIntervalSince1970: 0) }),
                          leaseWait: wait, sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000) })
    }

    /// The second process waits for the first one's read to end, then reads itself.
    func testTheOtherProcessWaitsForTheLease() async {
        let mem = InMemorySecureStore()
        let first = GatedSchoolReader()
        let second = ScriptedSchoolReader(SchoolReading(outcome: .ok, checkedAt: t2, balance: .success(Money(fen: 2)), readAt: t2))
        let app = refresher(first, mem, owner: "app-1"), widget = refresher(second, mem, owner: "widget-1")
        async let a = app.refresh(inBackground: false)
        await eventually { first.waitingCount == 1 }
        async let w = widget.refresh(inBackground: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(second.callCount, 0)
        first.release(SchoolReading(outcome: .ok, checkedAt: t1, balance: .success(Money(fen: 1)), readAt: t1))
        let (ra, rw) = await (a, w)
        XCTAssertTrue(ra.snapshotSaved)
        XCTAssertTrue(rw.snapshotSaved)
        XCTAssertEqual(second.callCount, 1)
        XCTAssertEqual(widget.latest().card.value, Money(fen: 2))
        XCTAssertNil(try mem.read(.sharedRefreshLease))
    }

    /// Still held after the wait: no read, nothing written, the stored snapshot is returned.
    func testBusyLeaseReturnsTheStoredSnapshot() async throws {
        let mem = InMemorySecureStore()
        XCTAssertTrue(RefreshLease(store: mem, owner: "app-1", now: { Date(timeIntervalSince1970: 0) }).acquire())
        let reader = ScriptedSchoolReader(SchoolReading(outcome: .ok, checkedAt: t1))
        let report = await refresher(reader, mem, owner: "widget-1", wait: 2).refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .failed(.timedOut))
        XCTAssertFalse(report.snapshotSaved)
        XCTAssertEqual(reader.callCount, 0)
        XCTAssertNil(try mem.read(.sharedSnapshot))
    }

    /// A slow read that finishes after a newer one was stored never overwrites it.
    func testOlderReadingNeverOverwritesANewerSnapshot() async throws {
        let mem = InMemorySecureStore()
        let snapshots = SharedSnapshotStore(store: mem)
        var newer = SchoolSnapshotReducer.reduce(.empty, .livenessOK(at: t2))
        newer = SchoolSnapshotReducer.reduce(newer, .balance(.success(Money(fen: 900)), at: t2))
        try snapshots.saveSnapshot(newer)
        let old = ScriptedSchoolReader(SchoolReading(outcome: .ok, checkedAt: t1, balance: .success(Money(fen: 100)), readAt: t1))
        let report = await refresher(old, mem, owner: "app-1").refresh(inBackground: false)
        XCTAssertFalse(report.snapshotSaved)
        XCTAssertEqual(report.snapshot, newer)
        XCTAssertEqual(try snapshots.loadSnapshot(), newer)
    }

    func testApplyIgnoresAnOlderReadingAndKeepsEmptyWhenSignedOut() {
        var s = SchoolSnapshotReducer.reduce(.empty, .livenessOK(at: t1))
        s = SchoolSnapshotReducer.reduce(s, .balance(.success(Money(fen: 5)), at: t1))
        XCTAssertEqual(SnapshotRefresher.apply(SchoolReading(outcome: .failed(.offline), checkedAt: t0), to: s), s)
        XCTAssertNotEqual(SnapshotRefresher.apply(SchoolReading(outcome: .failed(.offline), checkedAt: t1), to: s), s, "same time is not older")
        XCTAssertEqual(SnapshotRefresher.apply(SchoolReading(outcome: .notSignedIn, checkedAt: t2), to: .empty), .empty)
    }
}
