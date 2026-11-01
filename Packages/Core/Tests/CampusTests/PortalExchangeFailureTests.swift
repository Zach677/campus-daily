import XCTest
@testable import Core
import CoreTestSupport

/// The card session is dead and the portal re-exchange fails without an answer about the login
/// (no network, a timeout, a school server error): that is a failed read, not 「重新登录」, and
/// the next refresh goes through the same steps again (the saved password included).
final class PortalExchangeFailureTests: XCTestCase {
    static let eCardURL = "https://portal.gdbtu.edu.cn/portal-api/v2/personalData/getMyECard"

    func harness(_ login: FakePasswordLogin) throws -> Harness {
        var h = Harness()
        h.passwordLogin = login
        try h.signedIn(portal: true)
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        return h
    }

    func testAnOfflinePortalExchangeIsAFailedReadNotALogin() async throws {
        let login = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
        let h = try harness(login)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 2)
        h.server.fail("GET", Self.eCardURL, with: .notConnectedToInternet, times: 1)
        // The next refresh: the portal token is dead by then, so the saved password goes once.
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"), times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "AFTER-PASSWORD"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")

        let first = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(first.outcome, .failed(.offline))
        XCTAssertFalse(first.snapshot.needsLogin)
        XCTAssertTrue(login.calls.isEmpty, "nothing more is sent without a network")
        XCTAssertEqual(try h.vault.account()?.paused, false)

        let second = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(second.outcome, .ok)
        XCTAssertEqual(login.calls.count, 1, "the saved password still works the next time")
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "AFTER-PASSWORD")
    }

    func testATimedOutPortalExchangeIsAFailedRead() async throws {
        let login = FakePasswordLogin()
        let h = try harness(login)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try T.eCardWithTicket())
        h.server.fail("POST", T.exchangeURL, with: .timedOut)
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .failed(.timedOut))
        XCTAssertFalse(report.snapshot.needsLogin)
        XCTAssertTrue(login.calls.isEmpty)
    }

    func testASchoolServerErrorDuringTheExchangeIsAFailedRead() async throws {
        for (url, method, service) in [(Self.eCardURL, "GET", Service.portal), (T.exchangeURL, "POST", Service.ecykt)] {
            let login = FakePasswordLogin()
            let h = try harness(login)
            try h.server.serve("ecykt/getSysBindCustInfo-badToken")
            h.server.respond(method, url, status: 502, body: Data("bad gateway".utf8))
            h.server.serve(try T.eCardWithTicket())
            let report = await h.refresher().refresh(inBackground: false)
            XCTAssertEqual(report.outcome, .failed(.rejected(service, code: "HTTP 502", message: "")), url)
            XCTAssertFalse(report.snapshot.needsLogin, url)
            XCTAssertTrue(login.calls.isEmpty, url)
            XCTAssertEqual(try h.vault.account()?.paused, false, url)
        }
    }

    /// A definite answer still asks for a login, as before.
    func testAnExchangeTheSchoolTurnsDownStillAsksForALogin() async throws {
        let h = try harness(FakePasswordLogin())
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: Data(#"{"code":2,"msg":"票据无效"}"#.utf8))
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .needsLogin(.sessionExpired(.ecykt)))
        XCTAssertTrue(report.snapshot.needsLogin)
    }
}
