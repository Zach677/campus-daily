import XCTest
@testable import Core
import CoreTestSupport

/// The automatic meter lookup after a slow or unreachable school: tried again twice, waiting
/// longer each time; any other failure, a sign-out or someone else signing in ends it.
final class MeterLookupRetryTests: XCTestCase {
    static let service = "https://ecykt.gdbtu.edu.cn/ykt-mini/api/electricnew/service"
    static let campusRead: [String: String?] = ["server": "/api/getMeterStatus", "buildingID": "991001"]

    /// Records the waits asked for; `then` runs inside each (a sign-out, say).
    final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [TimeInterval] = []
        var asked: [TimeInterval] { lock.withLock { _asked } }
        func record(_ t: TimeInterval) { lock.withLock { _asked.append(t) } }
    }

    func harness(_ waits: Waits, then: (@Sendable () async -> Void)? = nil) throws -> Harness {
        var h = Harness()
        h.meterRetryWait = { t in waits.record(t); await then?() }
        try h.signedIn()
        return h
    }

    func serveMeters(_ h: Harness) throws {
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try SchoolElectricityTests.serveTree(h)
    }

    func campusReads(_ h: Harness) -> Int {
        h.server.requests(path: "/electricnew/service").filter {
            $0.bodyField("server") == "/api/getMeterStatus" && $0.bodyField("buildingID") == "991001"
        }.count
    }

    func testTimedOutTwiceThenFound() async throws {
        let waits = Waits()
        let h = try harness(waits)
        h.server.fail("POST", Self.service, bodyMatch: Self.campusRead, with: .timedOut, times: 2)
        try serveMeters(h)
        let (_, found) = try await h.session().matchElectricity()
        guard case .matched = found else { return XCTFail("\(found)") }
        XCTAssertEqual(campusReads(h), 3)
        XCTAssertEqual(waits.asked, SchoolSession.meterRetryDelays)
        XCTAssertEqual(SchoolSession.meterRetryDelays, [5, 20], "two more tries, the second wait longer")
        XCTAssertNotNil(try h.vault.profile()?.meter)
    }

    func testOfflineThreeTimesGivesUp() async throws {
        let waits = Waits()
        let h = try harness(waits)
        h.server.fail("POST", Self.service, bodyMatch: Self.campusRead, with: .notConnectedToInternet, times: 3)
        try serveMeters(h)
        do { _ = try await h.session().matchElectricity(); XCTFail("expected offline") } catch {
            XCTAssertEqual(error as? ServiceError, .offline)
        }
        XCTAssertEqual(campusReads(h), 3, "the first try and two more")
        XCTAssertEqual(waits.asked, [5, 20])
        XCTAssertNil(try h.vault.profile()?.meter)
    }

    func testAnotherFailureIsNotTriedAgain() async throws {
        let waits = Waits()
        let h = try harness(waits)
        h.server.respond("POST", Self.service, bodyMatch: Self.campusRead, body: Data(#"{"code":500,"msg":"缺少参数"}"#.utf8))
        try serveMeters(h)
        do { _ = try await h.session().matchElectricity(); XCTFail("expected badRequest") } catch {
            XCTAssertEqual(error as? ServiceError, .badRequest(.ecykt))
        }
        XCTAssertEqual(campusReads(h), 1)
        XCTAssertEqual(waits.asked, [])
    }

    /// Signed out while waiting: no further read, nothing saved, the failure thrown.
    func testASignOutWhileWaitingEndsIt() async throws {
        let waits = Waits()
        let box = SessionBox()
        let h = try harness(waits) { try? await box.session?.signOut() }
        h.server.fail("POST", Self.service, bodyMatch: Self.campusRead, with: .timedOut, times: 1)
        try serveMeters(h)
        let session = h.session()
        box.session = session
        do { _ = try await session.matchElectricity(); XCTFail("signed out") } catch {}
        XCTAssertEqual(campusReads(h), 1)
        XCTAssertEqual(waits.asked, [5])
        XCTAssertNil(try h.vault.profile())
    }

    final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _session: SchoolSession?
        var session: SchoolSession? {
            get { lock.withLock { _session } }
            set { lock.withLock { _session = newValue } }
        }
    }
}
