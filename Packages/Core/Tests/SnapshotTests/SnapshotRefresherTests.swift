import XCTest
@testable import Core

/// Snapshot store that records every write.
final class RecordingSnapshotStore: SnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HomeSnapshot?
    private(set) var writes: [HomeSnapshot] = []
    init(_ initial: HomeSnapshot? = nil) { stored = initial }
    func loadSnapshot() throws -> HomeSnapshot? { lock.withLock { stored } }
    func saveSnapshot(_ snapshot: HomeSnapshot) throws { lock.withLock { stored = snapshot; writes.append(snapshot) } }
    var writeCount: Int { lock.withLock { writes.count } }
}

/// School reader that answers a scripted reading and counts calls.
final class ScriptedSchoolReader: SchoolReader, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: SchoolReading
    private(set) var calls = 0
    init(_ reading: SchoolReading) { self.reading = reading }
    func refresh(inBackground: Bool) async -> SchoolReading {
        lock.withLock { calls += 1; return reading }
    }
    var callCount: Int { lock.withLock { calls } }
}

final class SnapshotRefresherTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)
    let meter = Meter(comAddress: "000000000199", name: "9栋199")

    func goodSnapshot() -> HomeSnapshot {
        var s = SchoolSnapshotReducer.reduce(.empty, .balance(.success(Money(fen: 790)), at: t0))
        s = SchoolSnapshotReducer.reduce(s, .meter(.success(meter), at: t0))
        return s
    }

    func testRefreshReducesTheReadingAndWritesOnce() async {
        let store = RecordingSnapshotStore()
        let reader = ScriptedSchoolReader(SchoolReading(outcome: .ok, checkedAt: t1, balance: .success(Money(fen: 500)),
                                                        meter: .success(meter), roomLabel: "9栋 199", readAt: t1))
        let refresher = SnapshotRefresher(school: reader, store: store)
        let report = await refresher.refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertTrue(report.snapshotSaved)
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(refresher.latest(), report.snapshot)
        XCTAssertEqual(report.snapshot.card.value, Money(fen: 500))
        XCTAssertEqual(report.snapshot.card.fetchedAt, t1)
        XCTAssertEqual(report.snapshot.power.value, meter)
        XCTAssertEqual(report.snapshot.roomLabel, "9栋 199")
        XCTAssertEqual(report.snapshot.checkedAt, t1)
    }

    func testFailedReadKeepsLastValuesAndRecordsTheFailure() async {
        let store = RecordingSnapshotStore(goodSnapshot())
        let refresher = SnapshotRefresher(school: ScriptedSchoolReader(SchoolReading(outcome: .failed(.offline), checkedAt: t1)),
                                          store: store)
        let report = await refresher.refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .failed(.offline))
        let saved = refresher.latest()
        XCTAssertEqual(saved, report.snapshot)
        XCTAssertEqual(saved.card.value, Money(fen: 790))
        XCTAssertEqual(saved.card.fetchedAt, t0)
        XCTAssertEqual(saved.card.error, .offline)
        XCTAssertEqual(saved.card.errorAt, t1)
        XCTAssertEqual(saved.power.value, meter)
        XCTAssertEqual(saved.power.fetchedAt, t0)
        XCTAssertEqual(saved.power.error, .offline)
        XCTAssertFalse(saved.needsLogin)
        XCTAssertEqual(store.writeCount, 1, "the failure is written so the app and widget can show it")
    }

    func testOneSourceFailingKeepsItsOldValueWhileTheOtherUpdates() async {
        let store = RecordingSnapshotStore(goodSnapshot())
        let newer = Meter(comAddress: "000000000199", name: "9栋199", leftMoney: Money(fen: 1200))
        let reading = SchoolReading(outcome: .ok, checkedAt: t1, balance: .failure(.timedOut), meter: .success(newer),
                                    roomLabel: "9栋 199", readAt: t1)
        let report = await SnapshotRefresher(school: ScriptedSchoolReader(reading), store: store).refresh(inBackground: false)
        XCTAssertEqual(report.snapshot.card.value, Money(fen: 790))
        XCTAssertEqual(report.snapshot.card.fetchedAt, t0)
        XCTAssertEqual(report.snapshot.card.error, .timedOut)
        XCTAssertEqual(report.snapshot.card.errorAt, t1)
        XCTAssertEqual(report.snapshot.power.value, newer)
        XCTAssertEqual(report.snapshot.power.fetchedAt, t1)
        XCTAssertNil(report.snapshot.power.error)
    }

    func testNeedsLoginKeepsValuesAndFlagsTheSnapshot() async {
        let store = RecordingSnapshotStore(goodSnapshot())
        let reading = SchoolReading(outcome: .needsLogin(.sessionExpired(.ecykt)), checkedAt: t1)
        let report = await SnapshotRefresher(school: ScriptedSchoolReader(reading), store: store).refresh(inBackground: true)
        XCTAssertTrue(report.snapshot.needsLogin)
        XCTAssertEqual(report.snapshot.card.value, Money(fen: 790))
        XCTAssertEqual(report.snapshot.card.error, .sessionExpired(.ecykt))
        XCTAssertEqual(store.writeCount, 1)
    }

    func testClearWritesEmpty() async throws {
        let store = RecordingSnapshotStore(goodSnapshot())
        let refresher = SnapshotRefresher(school: ScriptedSchoolReader(SchoolReading(outcome: .ok, checkedAt: t1)), store: store)
        try await refresher.clear()
        XCTAssertEqual(refresher.latest(), .empty)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testStoreWriteFailureIsReported() async {
        let mem = InMemorySecureStore()
        mem.failWrites(to: .sharedSnapshot)
        let refresher = SnapshotRefresher(school: ScriptedSchoolReader(SchoolReading(outcome: .failed(.offline), checkedAt: t1)),
                                          store: SharedSnapshotStore(store: mem))
        let report = await refresher.refresh(inBackground: false)
        XCTAssertFalse(report.snapshotSaved)
        XCTAssertEqual(report.snapshot.card.error, .offline)
    }
}
