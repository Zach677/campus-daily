import XCTest
@testable import Core

/// Back on the timer from the unsure face: the old 「不确定」 lock screen result goes at once
/// (no second activity beside the new 洗澡中), and the reminder counts from the return, not
/// from a water start that may be long past.
final class ShowerBackToTimerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    var running: ShowerState { ShowerState(phase: .running, machineID: "11223344", startedAt: t0) }
    var unsure: ShowerState {
        ShowerState(phase: .failed, machineID: "11223344", startedAt: t0, failure: ShowerFailure(reason: .closeUnconfirmed, needsReview: true))
    }

    func testTheReminderCountsFromTheWaterStart() {
        let start = ShowerReminderStart.next(running, after: ShowerState(phase: .authorizing), current: nil, now: t0.addingTimeInterval(5))
        XCTAssertEqual(start, t0)
        XCTAssertEqual(ShowerReminderStart.next(running, after: running, current: start, now: t0.addingTimeInterval(600)), t0)
        XCTAssertNil(ShowerReminderStart.next(unsure, after: running, current: t0, now: t0.addingTimeInterval(600)))
    }

    func testBackFromTheUnsureFaceTheReminderCountsFromNow() {
        let back = t0.addingTimeInterval(40 * 60)
        let start = ShowerReminderStart.next(running, after: unsure, current: nil, now: back)
        XCTAssertEqual(start, back)
        // It stays there while the water runs.
        XCTAssertEqual(ShowerReminderStart.next(running, after: running, current: start, now: back.addingTimeInterval(60)), back)
    }

    func testANewTimerEndsTheEarlierResultAtOnce() {
        XCTAssertTrue(ShowerActivityAction(running, now: t0).endsEarlierResult)
        XCTAssertFalse(ShowerActivityAction(unsure, now: t0).endsEarlierResult)
        XCTAssertFalse(ShowerActivityAction(ShowerState(phase: .settling, startedAt: t0), now: t0).endsEarlierResult)
    }
}
