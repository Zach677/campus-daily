import XCTest
@testable import Core
import CoreTestSupport

/// Meters are bound to their room only.
final class RoomOnlyMeterTests: XCTestCase {
    func meterReads(_ h: Harness) -> [RecordedRequest] {
        h.server.requests(path: "/electricnew/service").filter { $0.bodyField("server") == "/api/getMeterStatus" }
    }

    /// The room meter this build saves reads back unchanged, and a refresh reads it.
    func testARoomMeterSavedByThisBuildReadsBackAndIsRead() async throws {
        let h = Harness()
        var binding = Harness.roomBinding; binding.location = "星湖校区 · 半山公寓 · 99栋 · 991"
        try h.signedIn(meter: binding)
        XCTAssertEqual(try StoredSchoolVault(store: h.store).profile()?.meter, binding)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        try h.server.serve("ecykt/electric-getMeterStatus-room", matchBody: ["server"])
        try h.server.serve("ecykt/card-getRecordList-ok")
        let reading = await h.session().refresh(inBackground: true, owning: .unchecked)
        XCTAssertEqual(reading.outcome, .ok)
        XCTAssertFalse(reading.noMeter)
        XCTAssertEqual(meterReads(h).count, 1)
        XCTAssertEqual(try h.vault.profile()?.meter, binding, "kept as saved")
    }

    /// With no meter saved (a new dorm, never found) the reading says so; with the
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
