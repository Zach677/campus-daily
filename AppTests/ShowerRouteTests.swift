import XCTest
import Core
@testable import XiaoRiChang

/// 暖橙: while a shower is on, every push of 热水 (home's 最近, 校园卡记录, the home button) opens
/// the timer page instead of the 热水洗澡 screen; with no shower on the screen is pushed as before.
/// (清爽 pushes its own timer page for the route, `ClearDestination`; Core's
/// `ShowerStoppedFlowTests` checks what that page shows.)
final class ShowerRouteTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAPushOfHotWaterOpensTheTimerPageWhileAShowerIsOn() {
        let on = [ShowerState(phase: .running, machineID: "11223344", startedAt: t0),
                  ShowerState(phase: .writePending, machineID: "11223344", startedAt: t0),
                  ShowerState(phase: .running, machineID: "11223344", startedAt: t0, stateReviewRequired: true),
                  ShowerState(phase: .settling, machineID: "11223344", startedAt: t0)]
        for record in on {
            let page = ShowerPageFlow(record: record)
            let fromRecents = HomeRoute.opened([.shower], over: [], page: page)
            XCTAssertEqual(fromRecents.routes, [], "\(record.phase)")
            XCTAssertTrue(fromRecents.showsPage, "\(record.phase)")
            let fromRecords = HomeRoute.opened([.records, .shower], over: [.records], page: page)
            XCTAssertEqual(fromRecords.routes, [.records], "校园卡记录 stays under the page")
            XCTAssertTrue(fromRecords.showsPage)
        }
    }

    func testHotWaterIsPushedAsBeforeWithNoShowerOn() {
        let idle = ShowerPageFlow(record: .idle)
        let pushed = HomeRoute.opened([.records, .shower], over: [.records], page: idle)
        XCTAssertEqual(pushed.routes, [.records, .shower])
        XCTAssertFalse(pushed.showsPage)
        let unsure = ShowerPageFlow(record: ShowerState(phase: .failed, failure: ShowerFailure(reason: .settleUncertain, needsReview: true)))
        XCTAssertEqual(HomeRoute.opened([.shower], over: [], page: unsure).routes, [.shower], "the 不确定 record's screen")
    }

    func testOtherPushesAndPopsPassThrough() {
        let page = ShowerPageFlow(record: ShowerState(phase: .running, machineID: "11223344", startedAt: t0))
        XCTAssertEqual(HomeRoute.opened([.laundry], over: [], page: page).routes, [.laundry])
        XCTAssertFalse(HomeRoute.opened([.laundry], over: [], page: page).showsPage)
        XCTAssertEqual(HomeRoute.opened([], over: [.shower], page: page).routes, [], "a pop")
    }
}
