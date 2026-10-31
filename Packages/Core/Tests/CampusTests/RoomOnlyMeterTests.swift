import XCTest
@testable import Core
import CoreTestSupport

/// Meters are bound to their room only. One bound to the campus node by an older build (read
/// with the whole campus's meters every time) counts as no meter: the app drops it at launch
/// and looks the room up again; until then nothing reads it.
final class RoomOnlyMeterTests: XCTestCase {
    static let campusBinding = MeterBinding(nodeID: "991001", comAddress: "000000000991", label: "99栋 991", nodeIsRoom: false,
                                            location: "星湖校区 · 99栋991")

    func meterReads(_ h: Harness) -> [RecordedRequest] {
        h.server.requests(path: "/electricnew/service").filter { $0.bodyField("server") == "/api/getMeterStatus" }
    }

    func testACampusWideBindingIsDroppedAtLaunchAndTheDormKept() throws {
        let h = Harness()
        try h.signedIn(meter: Self.campusBinding)
        XCTAssertTrue(try SchoolSession.dropCampusWideMeter(h.vault))
        let profile = try h.vault.profile()
        XCTAssertNil(profile?.meter)
        XCTAssertEqual(profile?.residence?.raw, "星湖校区99栋9号1层991房", "the dorm stays: the lookup walks to it")
        XCTAssertFalse(try SchoolSession.dropCampusWideMeter(h.vault), "once")
        XCTAssertTrue(h.server.requests.isEmpty)
    }

    func testARoomBindingOrNoneIsLeftAlone() throws {
        let h = Harness()
        try h.signedIn(meter: Harness.roomBinding)
        XCTAssertFalse(try SchoolSession.dropCampusWideMeter(h.vault))
        XCTAssertEqual(try h.vault.profile()?.meter, Harness.roomBinding)
        let empty = Harness()
        XCTAssertFalse(try SchoolSession.dropCampusWideMeter(empty.vault))
        XCTAssertNil(try empty.vault.profile())
    }

    /// The widget may refresh before the app has dropped it: no meter is read for it.
    func testARefreshOfACampusWideBindingReadsNoMeter() async throws {
        let h = Harness()
        try h.signedIn(meter: Self.campusBinding)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try h.server.serve("ecykt/card-getRecordList-ok")
        let reading = await h.session().refresh(inBackground: true, owning: .unchecked)
        XCTAssertEqual(reading.outcome, .ok)
        XCTAssertNil(reading.meter)
        XCTAssertTrue(reading.noMeter, "its stored reading is cleared")
        XCTAssertEqual(meterReads(h).count, 0)
    }

    /// With no meter saved (dropped, a new dorm, never found) the reading says so; with the
    /// room's meter it does not.
    func testARefreshSaysWhetherAMeterIsBound() async throws {
        for (binding, none) in [(nil, true), (Harness.roomBinding, false)] as [(MeterBinding?, Bool)] {
            let h = Harness()
            try h.signedIn(meter: binding)
            try h.server.serve("ecykt/getSysBindCustInfo-ok")
            try h.server.serve("ecykt/getUserBalance-ok")
            try h.server.serve("ecykt/electric-getMeterStatus-room", matchBody: ["server"])
            try h.server.serve("ecykt/card-getRecordList-ok")
            let reading = await h.session().refresh(inBackground: true, owning: .unchecked)
            XCTAssertEqual(reading.outcome, .ok)
            XCTAssertEqual(reading.noMeter, none)
        }
    }

    /// End to end: the refresh after the launch drop leaves home and the widget no reading.
    func testTheRefreshAfterTheDropClearsTheStoredReading() async throws {
        let h = Harness()
        try h.signedIn(meter: Self.campusBinding)
        let store = h.snapshots
        var old = HomeSnapshot(roomLabel: "99栋 991", checkedAt: Date(timeIntervalSince1970: 1))
        old.power.succeed(Meter(comAddress: "000000000991", name: "99栋991", remainingKWh: 42), at: Date(timeIntervalSince1970: 1))
        try store.saveSnapshot(old)
        XCTAssertTrue(try SchoolSession.dropCampusWideMeter(h.vault))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        try h.server.serve("ecykt/card-getRecordList-ok")
        let report = await SnapshotRefresher(school: h.session(), store: store).refresh(inBackground: true)
        XCTAssertNil(report.snapshot.power.value)
        XCTAssertNil(report.snapshot.roomLabel)
        XCTAssertNil(try store.loadSnapshot()?.power.value)
    }

    func testTheRechargeCheckReadsNoCampusWideMeter() async throws {
        let h = Harness()
        try h.signedIn(meter: Self.campusBinding)
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        let value = try await h.session().readRechargeValue(.electricity)
        XCTAssertNil(value)
        XCTAssertEqual(meterReads(h).count, 0)
    }

    /// A same-name choice without its room is never bound to the campus.
    func testAChoiceWithoutItsRoomIsNotBound() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/electric-getBuildingInfo-root", matchBody: ["server", "buildingID"])
        let session = h.session()
        let campusOnly = MeterCandidate(meter: Meter(comAddress: "000000000991", name: "99栋991"),
                                        path: [PowerNode(id: "991001", name: "星湖校区")])
        do {
            try await session.chooseMatchedMeter(campusOnly, since: await session.personStamp())
            XCTFail("bound without a room")
        } catch {}
        XCTAssertNil(try h.vault.profile()?.meter)
        XCTAssertTrue(h.server.requests.isEmpty)
    }

    /// Every meter the app binds from now on is a room's: a pick from the picker too.
    func testAPickFromThePickerIsARoomBinding() async throws {
        let h = Harness()
        try h.signedIn()
        let session = h.session()
        try await session.chooseMeter(nodeID: MeterWalkTests.room.id, meter: Meter(comAddress: "000000000991", name: "99栋991"),
                                      path: ["星湖校区", "半山公寓", "99栋", "1楼", "991"], since: await session.personStamp())
        let meter = try h.vault.profile()?.meter
        XCTAssertEqual(meter?.nodeIsRoom, true)
        XCTAssertEqual(meter?.location, "星湖校区 · 半山公寓 · 99栋 · 991")
    }
}
