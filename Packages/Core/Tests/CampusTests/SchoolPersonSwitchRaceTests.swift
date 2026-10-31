import XCTest
@testable import Core
import CoreTestSupport

/// Someone else signs in while a school call for the previous person is in flight: whatever
/// that call returns afterwards is dropped, so the previous person's dorm or meter is never
/// written into the new person's account.
final class SchoolPersonSwitchRaceTests: XCTestCase {
    /// Holds the first request whose path ends in `suffix` (and whose body matches) without
    /// blocking the stub's loading thread, so the next person's sign-in can go through meanwhile.
    final class Hold: HTTPClient, @unchecked Sendable {
        // @unchecked: `held` and `waiting` guarded by `lock`.
        let inner: HTTPClient
        let suffix: String
        let body: [String: String]
        let reached: XCTestExpectation
        private let lock = NSLock()
        private var held = false
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false

        init(_ h: Harness, _ test: XCTestCase, suffix: String, body: [String: String] = [:]) {
            inner = h.server.makeClient(); self.suffix = suffix; self.body = body
            reached = test.expectation(description: "request in flight")
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let fields = request.body.flatMap { try? JSONValue.parse($0) }
            let matches = request.url.path.hasSuffix(suffix) && body.allSatisfy { fields?[$0.key]?.text == $0.value }
            let first = matches && lock.withLock { () -> Bool in defer { held = true }; return !held }
            if first {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let go = lock.withLock { () -> Bool in
                        if released { return true }
                        waiting = c; return false
                    }
                    reached.fulfill()
                    if go { c.resume() }
                }
            }
            return try await inner.send(request)
        }

        func release() {
            let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true; defer { waiting = nil }; return waiting
            }
            c?.resume()
        }
    }

    func session(_ h: Harness, _ hold: Hold) -> SchoolSession {
        SchoolSession(portal: PortalClient(http: hold), ecykt: EcyktClient(http: hold), vault: h.vault,
                      passwordLogin: h.passwordLogin, now: h.clock.function)
    }

    /// Signed in as a person whose card differs from the one the web sign-in fixture shows.
    func previousPerson(portal: Bool = false) throws -> Harness {
        let h = Harness()
        try h.signedIn(portal: portal)
        var session = T.session(); session.cardUnionID = SchoolAccountSwitchTests.otherCard
        try h.vault.saveEcyktSession(session)
        return h
    }

    /// The next person signs in on the official web page (their card answers the liveness check).
    func signInSomeoneElse(_ session: SchoolSession) async throws {
        let state = try XCTUnwrap(try FixtureLoader.loadRaw("ecykt/localStorage-elecampus_state-csaLogin")["value"])
        let summary = try await session.adoptWebState(try state.encoded(), portalToken: nil, owning: .unchecked)
        XCTAssertTrue(summary.switchedAccount)
    }

    func testSwitchDuringElectricityMatchWritesNothing() async throws {
        let h = try previousPerson()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try SchoolElectricityTests.serveTree(h)
        let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
        let session = session(h, hold)
        async let result = session.resolveElectricity()
        await fulfillment(of: [hold.reached], timeout: 5)
        try await signInSomeoneElse(session)
        hold.release()
        do {
            _ = try await result
            XCTFail("a match for the previous person must not succeed")
        } catch {
            XCTAssertEqual(error as? ServiceError, .sessionExpired(.ecykt))
        }
        XCTAssertNil(try h.vault.profile(), "no dorm or meter of the previous person")
    }

    /// The match found several same-name meters (or none) for the previous person: no list and
    /// no picker hint reaches the next person, whichever way they signed in.
    func testSwitchWhileSameNamedMetersAreFoundOffersNoChoice() async throws {
        for (extra, byForm) in [(["99栋991", "99栋 991"], false), (["99栋991", "99栋 991"], true), ([], false)] {
            var h = try previousPerson()
            h.passwordLogin = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
            if byForm {
                h.server.serve(try T.eCardWithTicket())
                h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "NEXT-TOKEN"))
            }
            try h.server.serve("ecykt/getSysBindCustInfo-ok")
            h.server.serve(try SchoolElectricityTests.campusMeters(extra: extra), matchBody: ["server", "buildingID"])
            try h.server.serve("ecykt/electric-getBuildingInfo-root", matchBody: ["server", "buildingID"])
            h.server.respond("POST", "https://ecykt.gdbtu.edu.cn/ykt-mini/api/electricnew/service",
                             bodyMatch: ["server": "/api/getBuildingInfo"], body: Data(#"{"code":0,"msg":"获取成功","data":"[]"}"#.utf8))
            let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
            let session = session(h, hold)
            async let result = session.resolveElectricity()
            await fulfillment(of: [hold.reached], timeout: 5)
            if byForm {
                let summary = try await session.signIn(account: "99100992", password: "synthetic-pw-992", savePassword: false, owning: .unchecked)
                XCTAssertTrue(summary.switchedAccount)
            } else {
                try await signInSomeoneElse(session)
            }
            hold.release()
            do {
                let late = try await result
                XCTFail("the previous person's match reached the next one: \(late)")
            } catch {
                XCTAssertEqual(error as? ServiceError, .sessionExpired(.ecykt))
            }
            XCTAssertNil(try h.vault.profile()?.meter)
        }
    }

    /// The next person's sign-in wipes the previous person's account and tokens, then a later
    /// write of the same step fails (a full Keychain): the sign-in fails, but the previous
    /// person's match still in flight is stale all the same and writes no dorm or meter next to
    /// what is left.
    func testASwitchWhoseWritesFailHalfwayStillDropsThePreviousPersonsMatch() async throws {
        for byForm in [false, true] {
            var h = try previousPerson()
            h.passwordLogin = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
            if byForm {
                h.server.serve(try T.eCardWithTicket())
                h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "NEXT-TOKEN"))
            }
            try h.server.serve("ecykt/getSysBindCustInfo-ok")
            h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
            try SchoolElectricityTests.serveTree(h)
            let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
            let session = session(h, hold)
            let stamp = await session.personStamp()
            async let result = session.resolveElectricity()
            await fulfillment(of: [hold.reached], timeout: 5)
            // The previous person's items go first; the profile write after them fails.
            h.store.failWrites(to: .schoolProfile)
            do {
                if byForm {
                    _ = try await session.signIn(account: "99100992", password: "synthetic-pw-992", savePassword: false, owning: .unchecked)
                } else {
                    try await signInSomeoneElse(session)
                }
                XCTFail("byForm \(byForm): the sign-in's profile write was meant to fail")
            } catch {
                XCTAssertTrue(error is StorageError, "byForm \(byForm): \(error)")
            }
            XCTAssertNil(try h.vault.account(), "byForm \(byForm): the wipe ran")
            let stale = await session.isSamePerson(since: stamp)
            XCTAssertFalse(stale, "byForm \(byForm): the previous person's work is stale once the wipe began")
            h.store.failWrites(to: .schoolProfile, false)
            hold.release()
            do {
                let late = try await result
                XCTFail("byForm \(byForm): the previous person's match was written: \(late)")
            } catch {
                XCTAssertEqual(error as? ServiceError, .sessionExpired(.ecykt), "byForm \(byForm)")
            }
            XCTAssertNil(try h.vault.profile()?.meter, "byForm \(byForm): no meter of the previous person")
        }
    }

    /// The previous person's match was dropped by the switch: the next person's own match
    /// runs instead, so their first setup is not left without a meter or a word.
    func testAMatchDroppedBySomeoneElsesSignInRunsForThem() async throws {
        let h = try previousPerson()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try SchoolElectricityTests.serveTree(h)
        let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
        let session = session(h, hold)
        async let result = session.matchElectricity()
        await fulfillment(of: [hold.reached], timeout: 5)
        try await signInSomeoneElse(session)
        let next = await session.personStamp()
        hold.release()
        let (stamp, found) = try await result
        XCTAssertEqual(stamp, next, "the answer is the next person's")
        XCTAssertEqual(found, .noAddress, "their own match: no dorm known for them yet")
        XCTAssertNil(try h.vault.profile()?.meter)
    }

    func testAMatchDroppedBySignOutIsNotRunAgain() async throws {
        let h = try previousPerson()
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try SchoolElectricityTests.serveTree(h)
        let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
        let session = session(h, hold)
        async let result = session.matchElectricity()
        await fulfillment(of: [hold.reached], timeout: 5)
        try await session.signOut()
        hold.release()
        do { _ = try await result; XCTFail("signed out") } catch {
            XCTAssertEqual(error as? ServiceError, .sessionExpired(.ecykt))
        }
        XCTAssertNil(try h.vault.profile())
    }

    /// A sign-out that could not delete the card session is still a sign-out: the dropped
    /// match is not run again on what was left behind.
    func testAMatchDroppedByAFailedSignOutIsNotRunAgain() async throws {
        let h = try previousPerson()
        h.server.serve(try SchoolElectricityTests.campusMeters(extra: ["99栋991"]), matchBody: ["server", "buildingID"])
        try SchoolElectricityTests.serveTree(h)
        let hold = Hold(h, self, suffix: "/electricnew/service", body: ["server": "/api/getMeterStatus"])
        let session = session(h, hold)
        async let result = session.matchElectricity()
        await fulfillment(of: [hold.reached], timeout: 5)
        h.store.failWrites(to: .schoolEcykt)
        do { try await session.signOut(); XCTFail("expected a sign-out failure") } catch is SchoolSession.SignOutFailure {}
        XCTAssertNotNil(try h.vault.ecyktSession(), "the card session could not be deleted")
        hold.release()
        do { _ = try await result; XCTFail("signed out") } catch {
            XCTAssertEqual(error as? ServiceError, .sessionExpired(.ecykt))
        }
        XCTAssertNil(try h.vault.profile()?.meter, "nothing matched on what the sign-out left")
    }

    /// A same-name list or the manual picker opened for the previous person: the next person's
    /// pick from it is refused, though their own sign-in is current.
    func testAPickFromThePreviousPersonsListSavesNothing() async throws {
        let h = try previousPerson()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        let session = h.session()
        let stamp = await session.personStamp()
        try await signInSomeoneElse(session)
        let meter = Meter(comAddress: "000000000991", name: "99栋991")
        let room = PowerNode(id: "991001001000109000001003", name: "991")
        do {
            try await session.chooseMatchedMeter(MeterCandidate(meter: meter, path: [room]), since: stamp)
            XCTFail("a pick from the previous person's list must not be saved")
        } catch {
            XCTAssertEqual(error as? ServiceError, .sessionExpired(.ecykt))
        }
        do {
            try await session.chooseMeter(nodeID: room.id, meter: meter, nodeIsRoom: true, since: stamp)
            XCTFail("a pick from the previous person's picker must not be saved")
        } catch {
            XCTAssertEqual(error as? ServiceError, .sessionExpired(.ecykt))
        }
        XCTAssertNil(try h.vault.profile()?.meter)
        let now = await session.personStamp()
        try await session.chooseMeter(nodeID: room.id, meter: meter, nodeIsRoom: true, since: now)
        XCTAssertEqual(try h.vault.profile()?.meter?.comAddress, "000000000991", "their own pick is kept")
    }

    func testSwitchWhileReadingTheDormWritesNothing() async throws {
        let h = try previousPerson(portal: true)
        try h.vault.saveProfile(nil)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("portal/getMyInfo-ok")
        let hold = Hold(h, self, suffix: "/getMyInfo")
        let session = session(h, hold)
        async let result = session.resolveElectricity()
        await fulfillment(of: [hold.reached], timeout: 5)
        try await signInSomeoneElse(session)
        hold.release()
        do { _ = try await result; XCTFail("expected the late dorm to be dropped") } catch {}
        XCTAssertNil(try h.vault.profile())
    }

    func testSwitchDuringChosenMeterSaveWritesNothing() async throws {
        let h = try previousPerson()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/electric-getBuildingInfo-root", matchBody: ["server", "buildingID"])
        let hold = Hold(h, self, suffix: "/electricnew/service")
        let session = session(h, hold)
        async let result: Void = session.chooseMatchedMeter(MeterCandidate(meter: Meter(comAddress: "000000000991", name: "99栋991"), path: []), since: 0)
        await fulfillment(of: [hold.reached], timeout: 5)
        try await signInSomeoneElse(session)
        hold.release()
        do { try await result; XCTFail("expected the late choice to be dropped") } catch {}
        XCTAssertNil(try h.vault.profile())
    }

    /// The hot-water binding is saved by the app after the user picks a controller, long after
    /// `showerHandoff()` returned the previous person's identity: the stamp taken before the
    /// hand-off tells whether that identity still belongs to whoever is signed in.
    func testPersonStampChangesWhenSomeoneElseSignsIn() async throws {
        let h = try previousPerson()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        let session = h.session()
        let stamp = await session.personStamp()
        try await signInSomeoneElse(session)
        let afterSwitch = await session.isSamePerson(since: stamp)
        XCTAssertFalse(afterSwitch, "a binding from the previous person's hand-off must not be saved")
        let again = await session.personStamp()
        try await session.signOut()
        let afterSignOut = await session.isSamePerson(since: again)
        XCTAssertFalse(afterSignOut)
    }

    func testPersonStampStaysWhenTheSamePersonSignsInAgain() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        let session = h.session()
        let stamp = await session.personStamp()
        let state = try XCTUnwrap(try FixtureLoader.loadRaw("ecykt/localStorage-elecampus_state-csaLogin")["value"])
        let summary = try await session.adoptWebState(try state.encoded(), portalToken: nil, owning: .unchecked)
        XCTAssertFalse(summary.switchedAccount)
        let same = await session.isSamePerson(since: stamp)
        XCTAssertTrue(same)
    }
}
