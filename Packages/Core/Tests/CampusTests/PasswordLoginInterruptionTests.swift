import XCTest
@testable import Core
import CoreTestSupport

/// A password login that looks at the stored account while the password is "in flight", then
/// answers with `result`.
final class ProbingPasswordLogin: SchoolPasswordLogin, @unchecked Sendable {
    // @unchecked: `seen` is written once inside `login` and read after the refresh returned.
    let vault: StoredSchoolVault
    let result: Result<PortalToken, SchoolLoginFailure>
    private(set) var seen: SchoolAccount?
    init(vault: StoredSchoolVault, result: Result<PortalToken, SchoolLoginFailure>) { self.vault = vault; self.result = result }
    func login(account: String, password: String, visitorID: String) async throws -> PortalToken {
        seen = (try? vault.account()) ?? nil
        return try result.get()
    }
}

/// The widget can be suspended or killed at any point of a login: what is known is stored at once.
final class PasswordLoginInterruptionTests: XCTestCase {
    func harness(_ result: Result<PortalToken, SchoolLoginFailure>) throws -> (Harness, ProbingPasswordLogin) {
        var h = Harness()
        let login = ProbingPasswordLogin(vault: h.vault, result: result)
        h.passwordLogin = login
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        return (h, login)
    }

    /// The hold is on record while the password is out: a widget suspended there does not log in
    /// again next time.
    func testTheHoldIsRecordedBeforeThePasswordIsSent() async throws {
        let (h, login) = try harness(.failure(.noAnswer))
        _ = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(login.seen?.unansweredAt, h.clock.now, "written before the login was sent")
        XCTAssertEqual(try h.vault.account()?.unansweredAt, h.clock.now)
    }

    func testAnAnswerLiftsTheHold() async throws {
        for result: Result<PortalToken, SchoolLoginFailure> in [.success(SchoolPasswordSignInTests.freshToken), .failure(.offline)] {
            let (h, login) = try harness(result)
            h.server.serve(try T.eCardWithTicket())
            h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "AFTER-PASSWORD"))
            try h.server.serve("ecykt/getSysBindCustInfo-ok")
            try h.server.serve("ecykt/getUserBalance-ok")
            _ = await h.refresher().refresh(inBackground: true)
            XCTAssertNotNil(login.seen?.unansweredAt)
            let after = try XCTUnwrap(try h.vault.account())
            XCTAssertNil(after.unansweredAt, "\(result)")
            XCTAssertFalse(after.paused)
        }
    }

    func testARefusalPausesAndLiftsTheHold() async throws {
        let (h, _) = try harness(.failure(.wrongCredentials))
        _ = await h.refresher().refresh(inBackground: true)
        let after = try XCTUnwrap(try h.vault.account())
        XCTAssertTrue(after.paused)
        XCTAssertNil(after.unansweredAt)
    }

    /// The login worked and the read was then given up (the widget's deadline) during the exchange
    /// after it: the portal token from the login is already kept.
    func testThePortalTokenIsKeptWhenTheReadIsGivenUpAfterTheLogin() async throws {
        let (h, _) = try harness(.success(SchoolPasswordSignInTests.freshToken))
        h.server.serve(try T.eCardWithTicket())
        let reached = expectation(description: "exchange in flight")
        let release = DispatchSemaphore(value: 0)
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getMyECard") else { return }
            reached.fulfill()
            release.wait()
        }
        let refresher = h.refresher()
        let read = Task { await refresher.refresh(inBackground: true) }
        await fulfillment(of: [reached], timeout: 5)
        read.cancel()
        XCTAssertEqual(try h.vault.portalToken()?.value, SchoolPasswordSignInTests.freshToken.value)
        release.signal()
        _ = await read.value
        XCTAssertEqual(try h.vault.portalToken()?.value, SchoolPasswordSignInTests.freshToken.value)
        XCTAssertNil(try h.vault.account()?.unansweredAt)
    }
}

/// A password login during which the process lost its lease (suspended past it, and the other
/// process took it).
final class LeaseLosingPasswordLogin: SchoolPasswordLogin, @unchecked Sendable {
    // @unchecked: `calls` is only touched by the one login of each refresh, read after it returned.
    let leaseFile: LeaseFile
    let clock: FakeClock
    private(set) var calls = 0
    init(leaseFile: LeaseFile, clock: FakeClock) { self.leaseFile = leaseFile; self.clock = clock }
    func login(account: String, password: String, visitorID: String) async throws -> PortalToken {
        calls += 1
        if calls == 1 {
            clock.advance(RefreshLease.defaultDuration + 1)
            _ = RefreshLease(file: leaseFile, owner: "widget-2", now: clock.function).acquire()
        }
        return SchoolPasswordSignInTests.freshToken
    }
}

final class PasswordLoginLostLeaseTests: XCTestCase {
    /// The school accepted the password while the lease ran out: the portal token is kept and the
    /// hold lifted, and the next refresh exchanges that token instead of sending the password again.
    func testAnAcceptedPasswordIsKeptWhenTheLeaseIsLostMeanwhile() async throws {
        var h = Harness()
        let login = LeaseLosingPasswordLogin(leaseFile: h.store.leaseFile, clock: h.clock)
        h.passwordLogin = login
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 2)
        func refresher(_ owner: String) -> SnapshotRefresher {
            SnapshotRefresher(school: h.session(), store: h.snapshots,
                              lease: RefreshLease(file: h.store.leaseFile, owner: owner, now: h.clock.function),
                              leaseWait: 0, sleep: { _ in })
        }
        let first = await refresher("app-1").refresh(inBackground: false)
        XCTAssertFalse(first.snapshotSaved, "lost the lease: no session written")
        XCTAssertEqual(try h.vault.portalToken()?.value, SchoolPasswordSignInTests.freshToken.value, "kept")
        let account = try XCTUnwrap(try h.vault.account())
        XCTAssertNil(account.unansweredAt)
        XCTAssertFalse(account.paused)
        XCTAssertEqual(try h.vault.ecyktSession()?.token, T.session().token)

        // Next refresh, after the other process's lease ran out: the token is exchanged.
        h.clock.advance(RefreshLease.defaultDuration + 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "AFTER-PASSWORD"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let second = await refresher("app-1").refresh(inBackground: false)
        XCTAssertEqual(second.outcome, .ok)
        XCTAssertEqual(login.calls, 1, "the password was sent once")
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "AFTER-PASSWORD")
    }
}

/// Counts password logins.
final class CountingPasswordLogin: SchoolPasswordLogin, @unchecked Sendable {
    // @unchecked: `calls` is only touched by the logins of one refresh at a time, read after it returned.
    private(set) var calls = 0
    func login(account: String, password: String, visitorID: String) async throws -> PortalToken {
        calls += 1
        return SchoolPasswordSignInTests.freshToken
    }
}

final class PasswordLoginAfterOtherSignInTests: XCTestCase {
    /// While this process exchanges its old portal token, the other one's password login is
    /// accepted: it stores a new portal token and card session and lifts its hold. This one's
    /// exchange then fails as expired; it does not send the password a second time.
    func testNewCredentialsStoredDuringTheExchangeSendNoPassword() async throws {
        var h = Harness()
        let login = CountingPasswordLogin()
        h.passwordLogin = login
        try h.signedIn()
        try h.vault.savePortalToken(PortalToken("OLD"))
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"))
        let vault = h.vault
        let renewed = { var s = T.session(); s.token = "OTHER-PROCESS"; return s }()
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getMyECard") else { return }
            // The other process, meanwhile: its password login was accepted.
            try? vault.savePortalToken(PortalToken("NEW"))
            try? vault.saveEcyktSession(renewed)
            try? vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        }
        let report = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(login.calls, 0, "no second password login")
        XCTAssertEqual(report.outcome, .interrupted)
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "OTHER-PROCESS", "the other process's session stays")
        XCTAssertEqual(try h.vault.portalToken()?.value, "NEW")
        let account = try XCTUnwrap(try h.vault.account())
        XCTAssertNil(account.unansweredAt)
        XCTAssertFalse(account.paused)
    }

    /// Nothing changed meanwhile: the password goes out once, as before.
    func testUnchangedCredentialsStillSendThePasswordOnce() async throws {
        var h = Harness()
        let login = CountingPasswordLogin()
        h.passwordLogin = login
        try h.signedIn()
        try h.vault.savePortalToken(PortalToken("OLD"))
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"), times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "AFTER-PASSWORD"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        _ = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(login.calls, 1)
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "AFTER-PASSWORD")
    }
}
