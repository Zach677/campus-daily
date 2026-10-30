import XCTest
import Core

final class SnapshotReducerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)

    func testSessionExpiryKeepsValuesAndTheirFetchedAt() {
        var s = SchoolSnapshotReducer.reduce(.empty, .balance(.success(Money(fen: 790)), at: t0))
        s = SchoolSnapshotReducer.reduce(s, .sessionExpired(.sessionExpired(.ecykt), at: t1))
        XCTAssertTrue(s.needsLogin)
        XCTAssertEqual(s.card.value, Money(fen: 790))
        XCTAssertEqual(s.card.fetchedAt, t0)
        XCTAssertEqual(s.card.error, .sessionExpired(.ecykt))
        s = SchoolSnapshotReducer.reduce(s, .livenessOK(at: t1))
        XCTAssertFalse(s.needsLogin)
    }

    func testFailureKeepsOldValue() {
        var s = SchoolSnapshotReducer.reduce(.empty, .balance(.success(Money(fen: 100)), at: t0))
        s = SchoolSnapshotReducer.reduce(s, .balance(.failure(.offline), at: t1))
        XCTAssertEqual(s.card.value, Money(fen: 100))
        XCTAssertEqual(s.card.fetchedAt, t0)
        XCTAssertEqual(s.card.errorAt, t1)
        s = SchoolSnapshotReducer.reduce(s, .balance(.success(Money(fen: 50)), at: t1))
        XCTAssertNil(s.card.error)
    }

    func testMeterNotFoundIsNotAnError() {
        let s = SchoolSnapshotReducer.reduce(.empty, .meter(.success(nil), at: t0))
        XCTAssertTrue(s.power.notFound)
        XCTAssertNil(s.power.error)
        XCTAssertEqual(SchoolSnapshotReducer.reduce(s, .signedOut), .empty)
    }
}
