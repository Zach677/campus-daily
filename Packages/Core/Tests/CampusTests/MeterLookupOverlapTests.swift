import XCTest
@testable import Core
import CoreTestSupport

/// The automatic meter lookup can take minutes on a slow school; meanwhile the same person
/// keeps using the app. What they did in between wins over what the lookup found.
final class MeterLookupOverlapTests: XCTestCase {
    typealias Hold = SchoolPersonSwitchRaceTests.Hold
    typealias Waits = MeterLookupRetryTests.Waits
    typealias SessionBox = MeterLookupRetryTests.SessionBox

    static let picked = MeterBinding(nodeID: "991001009", comAddress: "000000000999", label: "99栋999", nodeIsRoom: true,
                                     location: "星湖校区 · 半山公寓 · 99栋 · 999")

    static func pickByHand(_ session: SchoolSession) async throws {
        try await session.chooseMeter(nodeID: Self.picked.nodeID, meter: Meter(comAddress: Self.picked.comAddress, name: "99栋999"),
                                      nodeIsRoom: true, path: ["星湖校区", "半山公寓", "99栋", "999"],
                                      since: await session.personStamp())
    }

    func held(_ h: Harness, _ hold: Hold) -> SchoolSession {
        SchoolSession(portal: PortalClient(http: hold), ecykt: EcyktClient(http: hold), vault: h.vault,
                      passwordLogin: h.passwordLogin, now: h.clock.function, meterRetryWait: h.meterRetryWait)
    }

    // MARK: A meter picked by hand

    /// The lookup timed out, and while it waited to try again the user picked the meter in
    /// 「电表」: the retry that then finds the dorm's meter leaves the pick alone.
    func testAPickMadeWhileTheLookupWaitsStays() async throws {
        let box = SessionBox()
        var h = Harness()
        h.meterRetryWait = { _ in try? await Self.pickByHand(box.session!) }
        try h.signedIn()
        h.server.fail("POST", MeterLookupRetryTests.service, bodyMatch: MeterLookupRetryTests.campusRead, with: .timedOut, times: 1)
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try SchoolElectricityTests.serveTree(h)
        let session = h.session()
        box.session = session
        let (_, found) = try await session.matchElectricity()
        XCTAssertEqual(try h.vault.profile()?.meter, Self.picked, "the pick stays")
        XCTAssertEqual(found, .alreadyBound(Self.picked))
    }

    /// Picked while the campus-wide read was still under way: the same.
    func testAPickMadeDuringTheReadStays() async throws {
        let h = Harness()
        try h.signedIn()
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try SchoolElectricityTests.serveTree(h)
        let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
        let session = held(h, hold)
        async let result = session.matchElectricity()
        await fulfillment(of: [hold.reached], timeout: 5)
        try await Self.pickByHand(session)
        hold.release()
        let (_, found) = try await result
        XCTAssertEqual(try h.vault.profile()?.meter, Self.picked)
        XCTAssertEqual(found, .alreadyBound(Self.picked))
    }

    /// Same-name meters found after the user picked one: no list to choose from again.
    func testNoSameNameListOnceAMeterIsPicked() async throws {
        let h = Harness()
        try h.signedIn()
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991", "99栋 991"]), matchBody: ["server", "buildingID"])
        try h.server.serve("ecykt/electric-getBuildingInfo-root", matchBody: ["server", "buildingID"])
        h.server.respond("POST", MeterLookupRetryTests.service, bodyMatch: ["server": "/api/getBuildingInfo"],
                         body: Data(#"{"code":0,"msg":"获取成功","data":"[]"}"#.utf8))
        let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
        let session = held(h, hold)
        async let result = session.matchElectricity()
        await fulfillment(of: [hold.reached], timeout: 5)
        try await Self.pickByHand(session)
        hold.release()
        let (_, found) = try await result
        if case .chooseAmong = found { XCTFail("a list was offered after the pick") }
        XCTAssertEqual(found, .alreadyBound(Self.picked))
        XCTAssertEqual(try h.vault.profile()?.meter, Self.picked)
    }
}
