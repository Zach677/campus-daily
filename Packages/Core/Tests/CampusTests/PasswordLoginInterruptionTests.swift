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
