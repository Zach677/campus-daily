import XCTest
@testable import Core

final class ShowerPageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func failed(_ reason: ShowerFailureReason, review: Bool, error: ServiceError? = nil) -> ShowerState {
        ShowerState(phase: .failed, machineID: "11223344", startedAt: t0,
                    failure: ShowerFailure(reason: reason, needsReview: review, error: error))
    }

    func reduce(_ flow: inout ShowerPageFlow, _ event: ShowerPageEvent) -> [ShowerPageEffect] {
        let (next, effects) = ShowerPageFlow.reduce(flow, event)
        flow = next
        return effects
    }

    // MARK: Faces

    func testEachRecordShowsItsFace() {
        XCTAssertNil(ShowerPage(.idle))
        let cases: [(ShowerState, ShowerPagePhase, [ShowerStepMark])] = [
            (ShowerState(phase: .authorizing), .connecting, [.current, .future, .future]),
            (ShowerState(phase: .writePending, startedAt: t0), .running, [.done, .current, .future]),
            (ShowerState(phase: .running, startedAt: t0), .running, [.done, .current, .future]),
            (ShowerState(phase: .closing, startedAt: t0), .settling, [.done, .done, .current]),
            (ShowerState(phase: .settling, startedAt: t0), .settling, [.done, .done, .current]),
            (ShowerState(phase: .done, startedAt: t0), .done, [.done, .done, .done]),
            (failed(.deviceUnavailable, review: false), .connectFailed, [.failed, .future, .future]),
            (failed(.wrongDevice, review: false), .connectFailed, [.failed, .future, .future]),
            (failed(.deviceBusy, review: false), .denied, [.done, .failed, .future]),
            (failed(.authorizeRefused, review: false), .denied, [.done, .failed, .future]),
            (failed(.authorizeUncertain, review: true), .unsure, [.done, .failed, .future]),
            (failed(.authorizationInvalid, review: true), .unsure, [.done, .failed, .future]),
            (failed(.closeUnconfirmed, review: true), .unsure, [.done, .done, .failed]),
            (failed(.settleRefused, review: true), .unsure, [.done, .done, .failed]),
            (failed(.settleUncertain, review: true), .unsure, [.done, .done, .failed]),
            (failed(.settleUnconfirmed, review: true), .unsure, [.done, .done, .failed]),
        ]
        for (state, phase, steps) in cases {
            let page = ShowerPage(state)
            XCTAssertEqual(page?.phase, phase, "\(state.phase) \(String(describing: state.failure?.reason))")
            XCTAssertEqual(page?.steps, steps, "\(state.phase) \(String(describing: state.failure?.reason))")
        }
        XCTAssertTrue(ShowerPage(ShowerState(phase: .writePending))!.writeUnconfirmed)
        XCTAssertEqual(ShowerPage(ShowerState(phase: .running))?.stepNumber, 2)
        XCTAssertEqual(ShowerPage(failed(.deviceUnavailable, review: false))?.stepNumber, 1)
    }

    /// A failure that may have charged is never shown as harmless, whatever its reason.
    func testARecordThatMayHaveChargedIsAlwaysUnsure() {
        for reason in [ShowerFailureReason.deviceUnavailable, .wrongDevice, .deviceBusy, .authorizeRefused] {
            XCTAssertEqual(ShowerPage(failed(reason, review: true))?.phase, .unsure, reason.rawValue)
            XCTAssertNil(ShowerPage(failed(reason, review: true))?.denial)
        }
    }

    func testDenialSaysWhy() {
        XCTAssertEqual(ShowerPage(failed(.deviceBusy, review: false))?.denial, .inUse)
        XCTAssertEqual(ShowerPage(failed(.authorizeRefused, review: false, error: .rejected(.lxt6, code: "1", message: "余额不足")))?.denial,
                       .refused("余额不足"))
        XCTAssertEqual(ShowerPage(failed(.authorizeRefused, review: false, error: .badRequest(.lxt6)))?.denial, .refused(nil))
    }

    /// Only the platform's amount is shown, and minutes only with both ends known.
    func testDoneShowsOnlyThePlatformsAmount() {
        var s = ShowerState(phase: .done, startedAt: t0, receipt: ShowerReceipt(amount: Money(fen: 132)), endedAt: t0.addingTimeInterval(11 * 60 + 10))
        XCTAssertEqual(ShowerPage(s)?.amount, Money(fen: 132))
        XCTAssertEqual(ShowerPage(s)?.minutes, 11)
        s.receipt = ShowerReceipt(amount: nil)
        XCTAssertNil(ShowerPage(s)?.amount)
        s.receipt = nil; s.endedAt = nil
        XCTAssertNil(ShowerPage(s)?.amount)
        XCTAssertNil(ShowerPage(s)?.minutes)
        XCTAssertEqual(ShowerPage(ShowerState(phase: .done, startedAt: t0, endedAt: t0.addingTimeInterval(5)))?.minutes, 1)
    }

    // MARK: Flow

    func testAWholeShower() {
        var flow = ShowerPageFlow(record: .idle)
        XCTAssertEqual(reduce(&flow, .startTapped), [.start])
        XCTAssertTrue(flow.presented)
        XCTAssertEqual(flow.page?.phase, .connecting, "connecting at once")
        _ = reduce(&flow, .record(ShowerState(phase: .authorizing, startedAt: t0)))
        _ = reduce(&flow, .record(ShowerState(phase: .running, startedAt: t0)))
        _ = reduce(&flow, .startReturned)
        XCTAssertEqual(flow.page?.phase, .running)
        XCTAssertTrue(flow.mayCollapse)
        XCTAssertEqual(reduce(&flow, .endTapped), [.finish])
        _ = reduce(&flow, .record(ShowerState(phase: .closing, startedAt: t0)))
        XCTAssertFalse(flow.mayCollapse, "settling can't be left")
        _ = reduce(&flow, .record(ShowerState(phase: .settling, startedAt: t0)))
        _ = reduce(&flow, .record(ShowerState(phase: .done, startedAt: t0, receipt: ShowerReceipt(amount: Money(fen: 132)))))
        _ = reduce(&flow, .endReturned)
        XCTAssertEqual(flow.page?.phase, .done)
        XCTAssertTrue(flow.presented)
        XCTAssertEqual(reduce(&flow, .closeTapped), [.dismissRecord])
        XCTAssertFalse(flow.presented)
    }

    /// A second 结束 (double tap, or the lock screen as well) while the first runs does nothing.
    func testDuplicateEndTapsFinishOnce() {
        var flow = ShowerPageFlow(record: ShowerState(phase: .running, startedAt: t0), presented: true)
        XCTAssertEqual(reduce(&flow, .endTapped), [.finish])
        XCTAssertEqual(reduce(&flow, .endTapped), [])
        _ = reduce(&flow, .record(ShowerState(phase: .closing, startedAt: t0)))
        XCTAssertEqual(reduce(&flow, .endTapped), [])
        // The close was not sent (controller didn't answer): back to running, 结束 works again.
        _ = reduce(&flow, .record(ShowerState(phase: .running, startedAt: t0)))
        _ = reduce(&flow, .endReturned)
        XCTAssertEqual(reduce(&flow, .endTapped), [.finish])
    }

    func testCancelWhileConnectingGoesHomeWithNoRecord() {
        var flow = ShowerPageFlow(record: .idle)
        _ = reduce(&flow, .startTapped)
        _ = reduce(&flow, .record(ShowerState(phase: .authorizing, startedAt: t0)))
        XCTAssertEqual(reduce(&flow, .cancelTapped), [.cancelStart])
        XCTAssertEqual(reduce(&flow, .cancelTapped), [], "once")
        let effects = reduce(&flow, .record(failed(.deviceUnavailable, review: false)))
        XCTAssertEqual(effects, [.dismissRecord])
        XCTAssertFalse(flow.presented, "no failure face for a cancel")
        _ = reduce(&flow, .startReturned)
        XCTAssertFalse(flow.presented)
    }

    /// The authorize request had left: the cancel is refused and the page follows the start.
    func testARefusedCancelFollowsTheStart() {
        var flow = ShowerPageFlow(record: ShowerState(phase: .authorizing, startedAt: t0), presented: true)
        _ = reduce(&flow, .cancelTapped)
        _ = reduce(&flow, .cancelRefused)
        XCTAssertTrue(flow.mayCancel)
        _ = reduce(&flow, .record(ShowerState(phase: .running, startedAt: t0)))
        XCTAssertEqual(flow.page?.phase, .running)
        XCTAssertTrue(flow.presented)
    }

    /// A cancel that arrives as the start runs into an uncertain authorization: that is shown.
    func testACancelNeverHidesAnUncertainRecord() {
        var flow = ShowerPageFlow(record: ShowerState(phase: .authorizing, startedAt: t0), presented: true)
        _ = reduce(&flow, .cancelTapped)
        let effects = reduce(&flow, .record(failed(.authorizeUncertain, review: true)))
        XCTAssertEqual(effects, [])
        XCTAssertTrue(flow.presented)
        XCTAssertEqual(flow.page?.phase, .unsure)
    }

    /// The settlement timed out: 不确定, with no way to settle again from the page.
    func testASettlementTimeoutIsUnsureWithoutRetry() {
        var flow = ShowerPageFlow(record: ShowerState(phase: .settling, startedAt: t0), presented: true)
        _ = reduce(&flow, .record(failed(.settleUncertain, review: true, error: .timedOut)))
        XCTAssertEqual(flow.page?.phase, .unsure)
        for event in [ShowerPageEvent.endTapped, .retryTapped, .startTapped, .closeTapped, .cancelTapped] {
            XCTAssertEqual(ShowerPageFlow.reduce(flow, event).1, [], "\(event)")
        }
        var toReview = flow
        XCTAssertEqual(reduce(&toReview, .reviewTapped), [.openReview])
        XCTAssertFalse(toReview.presented)
        var toHome = flow
        XCTAssertEqual(reduce(&toHome, .homeTapped), [], "the record stays for 核对")
        XCTAssertFalse(toHome.presented)
    }

    func testRetryAfterAConnectFailure() {
        var flow = ShowerPageFlow(record: failed(.deviceUnavailable, review: false), presented: true)
        XCTAssertEqual(reduce(&flow, .retryTapped), [.start])
        XCTAssertEqual(flow.page?.phase, .connecting)
        XCTAssertEqual(reduce(&flow, .retryTapped), [], "not twice")
        var closing = ShowerPageFlow(record: failed(.deviceUnavailable, review: false), presented: true)
        XCTAssertEqual(reduce(&closing, .closeTapped), [.dismissRecord])
        XCTAssertFalse(closing.presented)
    }

    func testCollapseOnlyWhileRunningAndReopenAsItIs() {
        var flow = ShowerPageFlow(record: ShowerState(phase: .running, startedAt: t0), presented: true)
        _ = reduce(&flow, .collapseTapped)
        XCTAssertFalse(flow.presented)
        _ = reduce(&flow, .reopen)
        XCTAssertTrue(flow.presented)
        XCTAssertEqual(flow.page?.phase, .running)
        for state in [ShowerState(phase: .authorizing), ShowerState(phase: .settling), failed(.settleUncertain, review: true)] {
            var other = ShowerPageFlow(record: state, presented: true)
            _ = reduce(&other, .collapseTapped)
            XCTAssertTrue(other.presented, "\(state.phase)")
        }
    }

    /// Relaunched in the middle: the page starts closed and opens on the restored record.
    func testRelaunchMidShower() {
        let running = ShowerReducer.restore(ShowerState(phase: .running, machineID: "11223344", startedAt: t0))
        var flow = ShowerPageFlow(record: running)
        XCTAssertFalse(flow.presented)
        _ = reduce(&flow, .reopen)
        XCTAssertEqual(flow.page?.phase, .running)
        XCTAssertTrue(flow.mayEnd)

        let settling = ShowerReducer.restore(ShowerState(phase: .settling, machineID: "11223344", startedAt: t0, closeSent: true))
        XCTAssertEqual(ShowerPageFlow(record: settling).page?.phase, .unsure, "killed while settling")

        let sent = ShowerReducer.restore(ShowerState(phase: .authorizing, machineID: "11223344", startedAt: t0, authorizeSent: true))
        XCTAssertEqual(ShowerPageFlow(record: sent).page?.phase, .unsure)
        let notSent = ShowerReducer.restore(ShowerState(phase: .authorizing, machineID: "11223344", startedAt: t0))
        var idle = ShowerPageFlow(record: notSent)
        XCTAssertNil(idle.page)
        _ = reduce(&idle, .reopen)
        XCTAssertFalse(idle.presented, "nothing to show")
    }

    /// 开始洗澡 with a record still open shows that record and starts nothing.
    func testStartWithAnOpenRecordShowsIt() {
        var flow = ShowerPageFlow(record: failed(.closeUnconfirmed, review: true))
        XCTAssertEqual(reduce(&flow, .startTapped), [])
        XCTAssertTrue(flow.presented)
        XCTAssertEqual(flow.page?.phase, .unsure)
    }

    /// A start refused before it ran (a reset in progress): the page closes again.
    func testAStartThatNeverRanClosesThePage() {
        var flow = ShowerPageFlow(record: .idle)
        _ = reduce(&flow, .startTapped)
        _ = reduce(&flow, .startReturned)
        XCTAssertFalse(flow.presented)
    }

    /// The record went back to idle (the authorization never applied, or resolved elsewhere).
    func testARecordThatEndsQuietlyClosesThePage() {
        var flow = ShowerPageFlow(record: ShowerState(phase: .running, startedAt: t0), presented: true)
        _ = reduce(&flow, .endTapped)
        _ = reduce(&flow, .record(.idle))
        XCTAssertFalse(flow.presented)
        XCTAssertFalse(flow.ending)
    }

    /// Ended from the lock screen with the page down: the result comes up.
    func testAShowerEndedElsewhereShowsItsResult() {
        var flow = ShowerPageFlow(record: ShowerState(phase: .running, startedAt: t0))
        _ = reduce(&flow, .record(ShowerState(phase: .settling, startedAt: t0)))
        XCTAssertFalse(flow.presented)
        _ = reduce(&flow, .record(ShowerState(phase: .done, startedAt: t0, receipt: ShowerReceipt(amount: Money(fen: 132)))))
        XCTAssertTrue(flow.presented)
        var unsure = ShowerPageFlow(record: ShowerState(phase: .settling, startedAt: t0))
        _ = reduce(&unsure, .record(failed(.settleUncertain, review: true)))
        XCTAssertTrue(unsure.presented)
        var quiet = ShowerPageFlow(record: .idle)
        _ = reduce(&quiet, .record(ShowerState(phase: .done, startedAt: t0)))
        XCTAssertFalse(quiet.presented, "a restored result does not jump up")
    }
}
