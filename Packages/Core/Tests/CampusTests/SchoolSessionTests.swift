import XCTest
@testable import Core
import CoreTestSupport

struct Harness {
    let server = StubServer()
    let store = InMemorySecureStore()
    let clock = FakeClock()
    var vault: StoredSchoolVault { StoredSchoolVault(store: store) }
    var snapshots: SharedSnapshotStore { SharedSnapshotStore(store: store) }

    func session() -> SchoolSession {
        let http = server.makeClient()
        return SchoolSession(portal: PortalClient(http: http), ecykt: EcyktClient(http: http), vault: vault,
                             now: clock.function)
    }

    /// The refresher over this harness's session and shared store.
    func refresher() -> SnapshotRefresher {
        SnapshotRefresher(school: session(), store: snapshots, now: clock.function)
    }

    func signedIn(portal: Bool = false, meter: MeterBinding? = nil, residence: String = "星湖校区9栋9号1层199房") throws {
        try vault.saveEcyktSession(T.session())
        if portal { try vault.savePortalToken(PortalToken("PORTAL")) }
        try vault.saveProfile(SchoolProfile(residence: PortalResidence(raw: residence), meter: meter))
    }

    static let roomBinding = MeterBinding(nodeID: "991001001000109000001003", comAddress: "000000000199", label: "9栋 199", nodeIsRoom: true)

    func loginBySysIdCalls() -> Int { server.requests(path: "/loginBySysId").count }
    func livenessCalls() -> Int { server.requests(path: "/getSysBindCustInfo").count }
}

final class SchoolRefreshTests: XCTestCase {
    func testRefreshOKReadsBalanceAndRoomMeterWithoutMinting() async throws {
        let h = Harness()
        try h.signedIn(meter: Harness.roomBinding)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        try h.server.serve("ecykt/electric-getMeterStatus-room", matchBody: ["server", "buildingID"])
        let report = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertEqual(report.snapshot.card.value, Money(fen: 790))
        XCTAssertEqual(report.snapshot.card.fetchedAt, h.clock.now)
        XCTAssertEqual(report.snapshot.power.value?.leftMoney, Money(fen: 3692))
        XCTAssertEqual(report.snapshot.roomLabel, "9栋 199")
        XCTAssertFalse(report.snapshot.needsLogin)
        XCTAssertTrue(report.snapshotSaved)
        let saved = try XCTUnwrap(try h.snapshots.loadSnapshot())
        XCTAssertEqual(saved.card, report.snapshot.card)
        XCTAssertEqual(saved.power.value?.leftMoney, Money(fen: 3692))
        XCTAssertEqual(h.loginBySysIdCalls(), 0, "refresh never calls loginBySysId")
        XCTAssertTrue(h.server.unmatched.isEmpty)
        // Latest custid ciphertext from the liveness answer is kept for next time.
        XCTAssertEqual(try h.vault.ecyktSession()?.custid, "TESTid00000000000000000000000002")
        // Balance used the custid from the validating response.
        XCTAssertEqual(h.server.requests(path: "/getUserBalance").first?.bodyField("custid"), "TESTid00000000000000000000000002")
    }

    /// Batch 1 acceptance: liveness `-1` → needsLogin while the old balance stays with its fetchedAt.
    func testExpiredLivenessMarksNeedsLoginAndKeepsOldValues() async throws {
        let h = Harness()
        try h.signedIn(meter: Harness.roomBinding)
        let t0 = h.clock.now
        var old = SchoolSnapshotReducer.reduce(.empty, .balance(.success(Money(fen: 790)), at: t0))
        old = SchoolSnapshotReducer.reduce(old, .meter(.success(Meter(comAddress: "000000000199", name: "9栋199")), at: t0))
        try h.snapshots.saveSnapshot(old)
        h.clock.advance(3600)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        try h.server.serve("ecykt/getUserBalance-ok")

        let report = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .needsLogin(.sessionExpired(.ecykt)))
        XCTAssertTrue(report.snapshot.needsLogin)
        XCTAssertEqual(report.snapshot.card.value, Money(fen: 790))
        XCTAssertEqual(report.snapshot.card.fetchedAt, t0)
        XCTAssertEqual(report.snapshot.power.fetchedAt, t0)
        XCTAssertEqual(try h.snapshots.loadSnapshot()?.needsLogin, true)
        XCTAssertFalse(report.reexchanged, "no silent re-exchange in background")
        XCTAssertTrue(h.server.requests(path: "/getUserBalance").isEmpty, "session state is never derived from balance")
    }

    func testForegroundSilentReexchangeOnce() async throws {
        let h = Harness()
        try h.signedIn(portal: true)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "REEXCHANGED-TOKEN"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")

        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertTrue(report.reexchanged)
        XCTAssertFalse(report.snapshot.needsLogin)
        let stored = try XCTUnwrap(try h.vault.ecyktSession())
        XCTAssertEqual(stored.token, "REEXCHANGED-TOKEN")
        XCTAssertEqual(stored.syscustid, "SYNTH-SYS-NEW")
        XCTAssertEqual(h.server.requests(path: "/csalogintoken/450010").first?.bodyField("ticket"), "SYNTHETIC-TICKET-1")
        XCTAssertEqual(h.server.requests(path: "/getSysBindCustInfo").last?.header("acc_token"), "REEXCHANGED-TOKEN")
        XCTAssertEqual(h.loginBySysIdCalls(), 0)
    }

    func testReexchangeStillExpiredStopsAfterOneRetry() async throws {
        let h = Harness()
        try h.signedIn(portal: true)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "STILL-DEAD"))
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .needsLogin(.sessionExpired(.ecykt)))
        XCTAssertEqual(h.livenessCalls(), 2)
        XCTAssertEqual(h.server.requests(path: "/getMyECard").count, 1)
        XCTAssertTrue(report.snapshot.needsLogin)
    }

    func testPortalTokenDeadAsksForLogin() async throws {
        let h = Harness()
        try h.signedIn(portal: true)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"))
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .needsLogin(.sessionExpired(.portal)))
        XCTAssertTrue(h.server.requests(path: "/csalogintoken/450010").isEmpty)
    }

    func testOfflineLivenessKeepsSessionAndValues() async throws {
        let h = Harness()
        try h.signedIn()
        try h.snapshots.saveSnapshot(SchoolSnapshotReducer.reduce(.empty, .balance(.success(Money(fen: 5)), at: h.clock.now)))
        h.server.fail("POST", "https://ecykt.gdbtu.edu.cn/ykt-mini/api/customer/getSysBindCustInfo", with: .notConnectedToInternet)
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .failed(.offline))
        XCTAssertFalse(report.snapshot.needsLogin)
        XCTAssertEqual(report.snapshot.card.value, Money(fen: 5))
        XCTAssertEqual(report.snapshot.card.error, .offline)
        XCTAssertNotNil(try h.vault.ecyktSession())
    }

    func testPerTileFailuresAreIndependent() async throws {
        let h = Harness()
        try h.signedIn(meter: Harness.roomBinding)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-missingCustid")
        try h.server.serve("ecykt/electric-getMeterStatus-unknownBuilding")
        let report = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertEqual(report.snapshot.card.error, .badRequest(.ecykt))
        XCTAssertTrue(report.snapshot.power.notFound)
        XCTAssertNil(report.snapshot.power.error)
    }

    /// Campus only reports what it read; the shared snapshot is written by the refresher alone.
    func testSchoolSessionNeverWritesTheSharedSnapshot() async throws {
        let h = Harness()
        try h.signedIn(meter: Harness.roomBinding)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        try h.server.serve("ecykt/electric-getMeterStatus-room", matchBody: ["server", "buildingID"])
        let reading = await h.session().refresh(inBackground: true)
        XCTAssertEqual(reading.outcome, .ok)
        XCTAssertEqual(reading.balance, .success(Money(fen: 790)))
        XCTAssertEqual(reading.roomLabel, "9栋 199")
        XCTAssertEqual(reading.checkedAt, h.clock.now)
        XCTAssertNil(try h.store.read(.sharedSnapshot))
        try await h.session().signOut()
        XCTAssertNil(try h.store.read(.sharedSnapshot))
    }

    func testNotSignedIn() async throws {
        let h = Harness()
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .notSignedIn)
        XCTAssertTrue(h.server.requests.isEmpty)
    }

    /// Signing out while the liveness call is in flight: the late answer never writes the
    /// school card session back, so the next launch is signed out too.
    func testSignOutDuringRefreshIsNotUndone() async throws {
        let h = Harness()
        try h.signedIn(meter: Harness.roomBinding)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        try h.server.serve("ecykt/electric-getMeterStatus-room", matchBody: ["server", "buildingID"])
        let reached = expectation(description: "liveness in flight")
        let release = DispatchSemaphore(value: 0)
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getSysBindCustInfo") else { return }
            reached.fulfill()
            release.wait()
        }
        let session = h.session()
        async let reading = session.refresh(inBackground: true)
        await fulfillment(of: [reached], timeout: 5)
        try await session.signOut()
        release.signal()
        let result = await reading
        XCTAssertEqual(result.outcome, .notSignedIn)
        XCTAssertNil(result.balance)
        XCTAssertNil(try h.vault.ecyktSession(), "the session stays signed out")
    }
}

final class SchoolRechargeTests: XCTestCase {
    /// Batch 1 acceptance: the recharge session calls loginBySysId once and uses the fresh token.
    func testCardRechargeSessionUsesFreshToken() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/loginBySysId-mintSeries1")
        let web = try await h.session().rechargeSession(.card)
        XCTAssertEqual(h.loginBySysIdCalls(), 1)
        XCTAssertEqual(h.livenessCalls(), 1)
        XCTAssertEqual(web.startURL, SchoolEndpoints.rechargePage)
        let state = try JSONValue.parse(web.stateJSON)
        XCTAssertEqual(state["logintoken"]?.text, "REDACTED_TOKEN_9")
        XCTAssertNotEqual(state["logintoken"]?.text, "REDACTED_TOKEN_2")
        XCTAssertEqual(state["loginInfo"]?["token"]?.text, "REDACTED_TOKEN_9")
        XCTAssertEqual(state["loginInfo"]?["syscustid"]?.text, "TESTid00000000000000000000000003")
        XCTAssertEqual(state["schoolid"]?.text, "450010")
        XCTAssertEqual(state["custInfo"]?["custunionid"]?.text, "TESTid00000000000000000000000001")
        XCTAssertEqual(state["custid"]?.text, "TESTid00000000000000000000000002")
        XCTAssertTrue(web.userScript.contains("location.origin !== 'https://ecykt.gdbtu.edu.cn'"))
        XCTAssertTrue(web.userScript.contains("elecampus_state"))
        XCTAssertFalse("\(web)".contains("REDACTED_TOKEN_9"))
        XCTAssertEqual(try h.vault.ecyktSession()?.syscustid, "TESTid00000000000000000000000003")
        // Same shape as the official CSA state for the fields the page reads.
        let official = try FixtureLoader.loadRaw("ecykt/localStorage-elecampus_state-csaLogin")["value"]
        for key in ["logintoken", "loginInfo", "schoolid", "custInfo"] { XCTAssertNotNil(official?[key], key); XCTAssertNotNil(state[key], key) }
    }

    func testElectricityRechargeStartsAtPowerEntry() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/loginBySysId-mintSeries2")
        let web = try await h.session().rechargeSession(.electricity)
        let comps = try XCTUnwrap(URLComponents(url: web.startURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.path, "/ykt-mini/api/electricnew/getPowerUrl")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "syscustid" }?.value, "TESTid00000000000000000000000004")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "custid" }?.value, "TESTid00000000000000000000000002")
    }

    func testExpiredRechargeNeverMints() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        try h.server.serve("ecykt/loginBySysId-mintSeries1")
        await T.expectError(.sessionExpired(.ecykt)) { _ = try await h.session().rechargeSession(.card) }
        XCTAssertEqual(h.loginBySysIdCalls(), 0)
    }

    func testNavigationAllowList() {
        let ecykt = "ecykt.gdbtu.edu.cn"
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "https://ecykt.gdbtu.edu.cn/ykt-view/recharge")!, isUserTap: false, sourceHost: nil), .allow)
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "https://cas.gdbtu.edu.cn/cas/login")!, isUserTap: false, sourceHost: ecykt), .allow)
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "http://ecykt.gdbtu.edu.cn/")!, isUserTap: true, sourceHost: ecykt), .cancel)
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "https://evil.example/")!, isUserTap: true, sourceHost: ecykt), .cancel)
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "alipays://platformapi/startapp")!, isUserTap: true, sourceHost: ecykt), .openExternal)
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "weixin://wap/pay")!, isUserTap: true, sourceHost: ecykt), .openExternal)
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "alipays://platformapi/startapp")!, isUserTap: false, sourceHost: ecykt), .cancel)
        XCTAssertEqual(RechargeNavigation.decide(URL(string: "alipays://platformapi/startapp")!, isUserTap: true, sourceHost: "portal.gdbtu.edu.cn"), .cancel)
    }
}

final class SchoolElectricityTests: XCTestCase {
    /// Campus-wide rows + one synthetic row for the faked user room.
    func campusMeters(extra: [String]) throws -> Fixture {
        let f = try FixtureLoader.load("ecykt/electric-getMeterStatus-ok")
        return T.editingData(f) { data in
            guard let text = data.text, case .array(var rows)? = try? JSONValue.parse(text) else { return }
            for (i, name) in extra.enumerated() {
                rows.append(.object(["comAddress": .string(i == 0 ? "000000000199" : "00000000099\(i)"), "piplineName": .string(name),
                                     "type": .string("电表"), "leftMoney": .string("36.92"), "remaining": .string("52.00"),
                                     "onlineStatus": .string("在线")]))
            }
            data = .string(String(decoding: (try? JSONValue.array(rows).encoded()) ?? Data(), as: UTF8.self))
        }
    }

    func serveTree(_ h: Harness) throws {
        for n in ["root", "level1", "level2", "level3", "level4"] {
            try h.server.serve("ecykt/electric-getBuildingInfo-" + n, matchBody: ["server", "buildingID"])
        }
        try h.server.serve("ecykt/electric-getMeterStatus-room", matchBody: ["server", "buildingID"])
        // Other apartments are empty in this synthetic tree.
        h.server.respond("POST", "https://ecykt.gdbtu.edu.cn/ykt-mini/api/electricnew/service",
                         bodyMatch: ["server": "/api/getBuildingInfo"], body: Data(#"{"code":0,"msg":"获取成功","data":"[]"}"#.utf8))
    }

    func testMatchesByPiplineNameAndSavesRoomNode() async throws {
        let h = Harness()
        try h.signedIn()
        h.server.serve(try campusMeters(extra: ["9栋199"]), matchBody: ["server", "buildingID"])
        try serveTree(h)
        let result = try await h.session().resolveElectricity()
        guard case .matched(let binding, let meter) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(binding, Harness.roomBinding)
        XCTAssertEqual(meter.name, "9栋199")
        XCTAssertEqual(try h.vault.profile()?.meter, Harness.roomBinding)
        XCTAssertTrue(h.server.unmatched.isEmpty)
        XCTAssertEqual(h.server.requests.filter { $0.bodyField("server") == "/api/getMeterStatus" && $0.bodyField("buildingID") == "991001" }.count, 1,
                       "one campus-wide meter read")
    }

    func testFallsBackToCampusNodeWhenRoomNodeNotFound() async throws {
        let h = Harness()
        try h.signedIn()
        h.server.serve(try campusMeters(extra: ["9栋199"]), matchBody: ["server", "buildingID"])
        try h.server.serve("ecykt/electric-getBuildingInfo-root", matchBody: ["server", "buildingID"])
        h.server.respond("POST", "https://ecykt.gdbtu.edu.cn/ykt-mini/api/electricnew/service",
                         bodyMatch: ["server": "/api/getBuildingInfo"], body: Data(#"{"code":0,"msg":"获取成功","data":"[]"}"#.utf8))
        let result = try await h.session().resolveElectricity()
        guard case .matched(let binding, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(binding, MeterBinding(nodeID: "991001", comAddress: "000000000199", label: "9栋 199", nodeIsRoom: false))
    }

    func testZeroOrManyMatchesGoToPicker() async throws {
        let none = Harness()
        try none.signedIn()
        none.server.serve(try campusMeters(extra: []), matchBody: ["server", "buildingID"])
        try none.server.serve("ecykt/electric-getBuildingInfo-root", matchBody: ["server", "buildingID"])
        let r0 = try await none.session().resolveElectricity()
        XCTAssertEqual(r0, .manualPicker)
        XCTAssertNil(try none.vault.profile()?.meter)

        let many = Harness()
        try many.signedIn()
        many.server.serve(try campusMeters(extra: ["9栋199", "9栋 199"]), matchBody: ["server", "buildingID"])
        try many.server.serve("ecykt/electric-getBuildingInfo-root", matchBody: ["server", "buildingID"])
        let r2 = try await many.session().resolveElectricity()
        guard case .chooseAmong(let list) = r2 else { return XCTFail("\(r2)") }
        XCTAssertEqual(list.count, 2)
    }

    func testNoParsedAddress() async throws {
        let h = Harness()
        try h.signedIn(residence: "暂无宿舍")
        let r = try await h.session().resolveElectricity()
        XCTAssertEqual(r, .noAddress)
        XCTAssertTrue(h.server.requests.isEmpty)
    }
}

final class SchoolSignInTests: XCTestCase {
    func testNativeSignInSavesSessionAndResidence() async throws {
        let h = Harness()
        try h.server.serve("portal/getMyInfo-ok")
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "REDACTED_TOKEN_2"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        let summary = try await h.session().signIn(portalToken: PortalToken("PORTAL"))
        XCTAssertEqual(summary.cardholder, "测试员")
        XCTAssertEqual(summary.residence?.address?.meterName, "9栋199")
        XCTAssertEqual(try h.vault.portalToken(), PortalToken("PORTAL"))
        XCTAssertEqual(try h.vault.ecyktSession()?.cardUnionID, "TESTid00000000000000000000000001")
        XCTAssertEqual(try h.vault.profile()?.residence?.raw, "星湖校区9栋9号1层199房")
    }

    func testAdoptWebStateFallback() async throws {
        let h = Harness()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        let state = try XCTUnwrap(try FixtureLoader.loadRaw("ecykt/localStorage-elecampus_state-csaLogin")["value"])
        let summary = try await h.session().adoptWebState(try state.encoded(), portalToken: nil)
        XCTAssertEqual(summary.cardholder, "测试员")
        let s = try XCTUnwrap(try h.vault.ecyktSession())
        XCTAssertEqual(s.token, "REDACTED_TOKEN_2")
        XCTAssertEqual(s.syscustid, T.syscustid)
        await T.expectError(.malformed(.ecykt, "elecampus_state")) { _ = try await h.session().adoptWebState(Data("{}".utf8), portalToken: nil) }
    }

    func testSignInWithBadTicketExchangeSavesNothing() async throws {
        let h = Harness()
        try h.server.serve("portal/getMyInfo-ok")
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: Data())
        await T.expectError(.badRequest(.ecykt)) { _ = try await h.session().signIn(portalToken: PortalToken("PORTAL")) }
        XCTAssertNil(try h.vault.ecyktSession())
        XCTAssertNil(try h.vault.portalToken())
    }
}

extension Fixture {
    /// Same reply, served on another path of the same host.
    func withURLPath(_ path: String) -> Fixture {
        var f = self
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.path = path
        f.url = c.url!
        return f
    }
}
