import XCTest
import Core

/// When the automatic meter lookup starts by itself: launch, back in the foreground, after a
/// home refresh read the card; at most once in ten minutes for the last two, never once a meter
/// is bound. 「再找一次电表」 is not held back.
final class MeterAutoFindTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_300_000)

    func start(_ f: inout MeterAutoFind, _ trigger: MeterAutoFind.Trigger, after seconds: TimeInterval,
               signedIn: Bool = true, meterBound: Bool = false, addressKnown: Bool = true) -> Bool {
        f.start(trigger, signedIn: signedIn, meterBound: meterBound, addressKnown: addressKnown, now: t0.addingTimeInterval(seconds))
    }

    func testForegroundAndRefreshShareOneTenMinuteLimit() {
        var f = MeterAutoFind()
        XCTAssertEqual(MeterAutoFind.interval, 600)
        XCTAssertTrue(start(&f, .foreground, after: 0))
        XCTAssertFalse(start(&f, .refreshed, after: 60), "a refresh a minute later waits")
        XCTAssertFalse(start(&f, .foreground, after: 599))
        XCTAssertTrue(start(&f, .refreshed, after: 600))
        XCTAssertFalse(start(&f, .foreground, after: 1_000))
        XCTAssertTrue(start(&f, .foreground, after: 1_200))
    }

    func testManualIsNotHeldBackAndCounts() {
        var f = MeterAutoFind()
        XCTAssertTrue(start(&f, .refreshed, after: 0))
        XCTAssertTrue(start(&f, .manual, after: 10))
        XCTAssertTrue(start(&f, .manual, after: 20))
        XCTAssertFalse(start(&f, .foreground, after: 500), "ten minutes from the last start, the manual one")
        XCTAssertTrue(start(&f, .foreground, after: 620))
    }

    func testOnlySignedInWithoutAMeter() {
        var f = MeterAutoFind()
        for trigger in [MeterAutoFind.Trigger.launch, .foreground, .refreshed, .manual, .signedIn] {
            XCTAssertFalse(start(&f, trigger, after: 0, signedIn: false), "\(trigger)")
            XCTAssertFalse(start(&f, trigger, after: 0, meterBound: true), "\(trigger)")
        }
        XCTAssertTrue(start(&f, .foreground, after: 1), "nothing refused above was counted")
    }

    /// Re-finding needs the dorm: without it the school has nothing to match. Launch and the
    /// manual button still look (the lookup reads the dorm first).
    func testRefindNeedsTheDormAddress() {
        var f = MeterAutoFind()
        XCTAssertFalse(start(&f, .foreground, after: 0, addressKnown: false))
        XCTAssertFalse(start(&f, .refreshed, after: 0, addressKnown: false))
        XCTAssertTrue(start(&f, .launch, after: 0, addressKnown: false))
        XCTAssertTrue(start(&f, .manual, after: 1, addressKnown: false))
    }

    func testLaunchCountsTowardsTheLimit() {
        var f = MeterAutoFind()
        XCTAssertTrue(start(&f, .launch, after: 0))
        XCTAssertFalse(start(&f, .foreground, after: 1), "the launch's own foreground")
    }

    /// Every sign-in starts it, whichever screen it came from: right after another start, and
    /// before the dorm is known (the lookup reads it first). It counts like any start.
    func testASignInIsNotHeldBack() {
        var f = MeterAutoFind()
        XCTAssertTrue(start(&f, .foreground, after: 0))
        XCTAssertTrue(start(&f, .signedIn, after: 60))
        XCTAssertTrue(start(&f, .signedIn, after: 70, addressKnown: false))
        XCTAssertFalse(start(&f, .signedIn, after: 80, meterBound: true), "the same person's meter was kept")
        XCTAssertFalse(start(&f, .signedIn, after: 90, signedIn: false))
        XCTAssertFalse(start(&f, .refreshed, after: 100), "the sign-in's own refresh")
    }

    /// The clock set back: the limit does not hold the lookup off until it catches up.
    func testAClockSetBackDoesNotHoldItOff() {
        var f = MeterAutoFind()
        XCTAssertTrue(start(&f, .foreground, after: 0))
        XCTAssertTrue(start(&f, .foreground, after: -3_600))
    }
}
