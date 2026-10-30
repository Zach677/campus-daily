import XCTest
import os
@testable import Core
import CoreTestSupport

/// Scripted password login: each call takes the next result (no network).
final class FakePasswordLogin: SchoolPasswordLogin {
    struct Call: Equatable { var account: String; var password: String; var visitorID: String }
    private let state = OSAllocatedUnfairLock<(results: [Result<PortalToken, SchoolLoginFailure>], calls: [Call])>(initialState: ([], []))

    init(_ results: Result<PortalToken, SchoolLoginFailure>...) { state.withLock { $0.results = results } }
    var calls: [Call] { state.withLock { $0.calls } }

    func login(account: String, password: String, visitorID: String) async throws -> PortalToken {
        let result: Result<PortalToken, SchoolLoginFailure> = state.withLock {
            $0.calls.append(Call(account: account, password: password, visitorID: visitorID))
            return $0.results.isEmpty ? .failure(.cannotLoginDirectly) : $0.results.removeFirst()
        }
        return try result.get()
    }
}

final class SchoolPasswordSignInTests: XCTestCase {
    static let freshToken = PortalToken("PORTAL-PW", expiresAt: Date(timeIntervalSince1970: 1_793_330_000))

    func harness(_ login: FakePasswordLogin) -> Harness {
        var h = Harness()
        h.passwordLogin = login
        return h
    }

    /// The card exchange after a login: ticket from the portal, then the ecykt token.
    func serveExchange(_ h: Harness, token: String = "PW-TOKEN") throws {
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: token))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
    }

    func testSignInSavesTheAccountAndThePasswordOnlyWhenAsked() async throws {
        for save in [true, false] {
            let login = FakePasswordLogin(.success(Self.freshToken))
            let h = harness(login)
            try h.server.serve("portal/getMyInfo-ok")
            try serveExchange(h)
            let summary = try await h.session().signIn(account: "99100991", password: "synthetic-pw-991", savePassword: save)
            XCTAssertEqual(summary.cardholder, "测试员")
            XCTAssertEqual(try h.vault.portalToken(), Self.freshToken, "the expiry is kept with the token")
            XCTAssertEqual(try h.vault.ecyktSession()?.token, "PW-TOKEN")
            XCTAssertEqual(try h.vault.account(), SchoolAccount(account: "99100991", password: save ? "synthetic-pw-991" : nil))
            let visitor = try XCTUnwrap(try h.vault.loginDeviceID())
            XCTAssertEqual(login.calls.map(\.visitorID), [visitor])
            XCTAssertNotNil(visitor.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        }
    }

    func testRefusedSignInSavesNothingAndIsNotRetried() async throws {
        for failure in [SchoolLoginFailure.wrongCredentials, .cannotLoginDirectly, .offline] {
            let login = FakePasswordLogin(.failure(failure))
            let h = harness(login)
            do { _ = try await h.session().signIn(account: "99100991", password: "x", savePassword: true); XCTFail() }
            catch { XCTAssertEqual(error as? SchoolLoginFailure, failure) }
            XCTAssertEqual(login.calls.count, 1)
            XCTAssertNil(try h.vault.account())
            XCTAssertNil(try h.vault.ecyktSession())
            XCTAssertTrue(h.server.requests.isEmpty)
        }
    }

    func testTheSameDeviceIdIsSentEveryTime() async throws {
        let login = FakePasswordLogin(.failure(.wrongCredentials), .failure(.wrongCredentials))
        let h = harness(login)
        for _ in 0..<2 { _ = try? await h.session().signIn(account: "99100991", password: "x", savePassword: false) }
        XCTAssertEqual(Set(login.calls.map(\.visitorID)).count, 1)
    }

    func testSavePasswordChecksItFirstAndForgetKeepsTheAccount() async throws {
        let login = FakePasswordLogin(.failure(.wrongCredentials), .success(Self.freshToken))
        let h = harness(login)
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991"))
        do { try await h.session().savePassword("wrong"); XCTFail() }
        catch { XCTAssertEqual(error as? SchoolLoginFailure, .wrongCredentials) }
        XCTAssertNil(try h.vault.account()?.password)
        try await h.session().savePassword("synthetic-pw-991")
        XCTAssertEqual(try h.vault.account()?.usablePassword, "synthetic-pw-991")
        XCTAssertEqual(login.calls.map(\.account), ["99100991", "99100991"])
        try await h.session().forgetPassword()
        XCTAssertEqual(try h.vault.account(), SchoolAccount(account: "99100991"))
    }

    // MARK: Refresh ladder

    func testExpiredCardAndPortalTokenSignInWithTheSavedPassword() async throws {
        for background in [false, true] {
            let login = FakePasswordLogin(.success(Self.freshToken))
            let h = harness(login)
            try h.signedIn()
            try h.vault.savePortalToken(PortalToken("OLD", expiresAt: h.clock.now.addingTimeInterval(-1)))
            try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
            try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
            try serveExchange(h, token: "AFTER-PASSWORD")
            try h.server.serve("ecykt/getUserBalance-ok")

            let report = await h.refresher().refresh(inBackground: background)
            XCTAssertEqual(report.outcome, .ok, "background: \(background)")
            XCTAssertTrue(report.reexchanged)
            XCTAssertEqual(login.calls.count, 1)
            XCTAssertEqual(try h.vault.ecyktSession()?.token, "AFTER-PASSWORD")
            XCTAssertEqual(try h.vault.portalToken(), Self.freshToken)
            XCTAssertEqual(h.server.requests(path: "/getMyECard").count, 1, "the expired portal token is never sent")
        }
    }

    func testLivePortalTokenIsTriedBeforeThePassword() async throws {
        let login = FakePasswordLogin()
        let h = harness(login)
        try h.signedIn(portal: true)
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        try serveExchange(h)
        try h.server.serve("ecykt/getUserBalance-ok")
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertTrue(login.calls.isEmpty)
    }

    func testRefusedPasswordPausesItUntilTheUserSignsIn() async throws {
        let login = FakePasswordLogin(.failure(.wrongCredentials))
        let h = harness(login)
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        let first = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(first.outcome, .needsLogin(.sessionExpired(.ecykt)))
        XCTAssertTrue(first.snapshot.needsLogin)
        XCTAssertEqual(try h.vault.account()?.paused, true)
        let second = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(second.outcome, .needsLogin(.sessionExpired(.ecykt)))
        XCTAssertEqual(login.calls.count, 1, "a refused password is never tried again by itself")
    }

    /// The user saves a new password while an automatic login with the old one is refused:
    /// the new one is not paused.
    func testARefusalDoesNotPauseAPasswordSavedMeanwhile() async throws {
        struct SavesThenRefuses: SchoolPasswordLogin {
            let vault: StoredSchoolVault
            func login(account: String, password: String, visitorID: String) async throws -> PortalToken {
                try vault.saveAccount(SchoolAccount(account: account, password: "new-pw-992"))
                throw SchoolLoginFailure.wrongCredentials
            }
        }
        var h = Harness()
        h.passwordLogin = SavesThenRefuses(vault: h.vault)
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        _ = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(try h.vault.account(), SchoolAccount(account: "99100991", password: "new-pw-992"))
    }

    func testNoNetworkDuringThePasswordStepDoesNotPauseIt() async throws {
        let login = FakePasswordLogin(.failure(.offline))
        let h = harness(login)
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        let report = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .failed(.offline))
        XCTAssertEqual(try h.vault.account()?.paused, false)
    }

    /// A posted password with no answer is never sent again by a refresh for the next hours;
    /// after that one more automatic try is allowed.
    func testNoAnswerHoldsAutomaticLoginsOff() async throws {
        let login = FakePasswordLogin(.failure(.noAnswer), .success(Self.freshToken))
        let h = harness(login)
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 3)
        let first = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(first.outcome, .failed(.offline))
        let held = try XCTUnwrap(try h.vault.account())
        XCTAssertFalse(held.paused)
        XCTAssertEqual(held.unansweredAt, h.clock.now)
        XCTAssertTrue(held.isHolding(at: h.clock.now))

        h.clock.advance(5 * 3600)
        let second = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(second.outcome, .needsLogin(.sessionExpired(.ecykt)))
        XCTAssertEqual(login.calls.count, 1, "not sent again while holding off")

        h.clock.advance(3600 + 1)
        try serveExchange(h, token: "AFTER-HOLD")
        try h.server.serve("ecykt/getUserBalance-ok")
        let third = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(third.outcome, .ok)
        XCTAssertEqual(login.calls.count, 2)
    }

    func testSignOutAndWebSignInDropTheSavedPassword() async throws {
        let h = harness(FakePasswordLogin())
        try h.signedIn()
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.vault.saveLoginDeviceID("99000000000000000000000000000991")
        try await h.session().signOut()
        XCTAssertNil(try h.vault.account())
        XCTAssertNil(try h.vault.loginDeviceID())

        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        let state = try XCTUnwrap(try FixtureLoader.loadRaw("ecykt/localStorage-elecampus_state-csaLogin")["value"])
        _ = try await h.session().adoptWebState(try state.encoded(), portalToken: nil)
        XCTAssertNil(try h.vault.account(), "the web page never says whose password it was")
    }

    /// One item that can't be deleted doesn't keep the password (or anything else) behind.
    func testSignOutKeepsGoingAfterAFailedDeletion() async throws {
        for stuck in [StoreKey.schoolPortal, .schoolEcykt, .schoolPassword] {
            let h = harness(FakePasswordLogin())
            try h.signedIn(portal: true)
            try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
            try h.vault.saveLoginDeviceID("99000000000000000000000000000991")
            h.store.failWrites(to: stuck)
            do { try await h.session().signOut(); XCTFail("expected a sign-out failure") }
            catch let failure as SchoolSession.SignOutFailure { XCTAssertEqual(failure.items.count, 1, "\(stuck)") }
            for key in [StoreKey.schoolPortal, .schoolEcykt, .schoolProfile, .schoolPassword, .schoolDevice] where key != stuck {
                XCTAssertNil(try h.store.read(key), "\(key) after \(stuck) failed")
            }
        }
    }

    func testAutoLoginStatusForEveryState() {
        let t = Date(timeIntervalSince1970: 1_793_300_000)
        XCTAssertEqual(SchoolAccount(account: "a").autoLogin(at: t), .off)
        XCTAssertEqual(SchoolAccount(account: "a", password: "").autoLogin(at: t), .off)
        XCTAssertEqual(SchoolAccount(account: "a", password: "p").autoLogin(at: t), .on)
        XCTAssertEqual(SchoolAccount(account: "a", password: "p", paused: true).autoLogin(at: t), .pausedRefused)
        XCTAssertEqual(SchoolAccount(account: "a", password: "p", paused: true, unansweredAt: t).autoLogin(at: t), .pausedRefused)
        let held = SchoolAccount(account: "a", password: "p", unansweredAt: t)
        XCTAssertEqual(held.autoLogin(at: t), .pausedNoAnswer)
        XCTAssertEqual(held.autoLogin(at: t.addingTimeInterval(SchoolAccount.holdAfterNoAnswer - 1)), .pausedNoAnswer)
        XCTAssertEqual(held.autoLogin(at: t.addingTimeInterval(SchoolAccount.holdAfterNoAnswer)), .on, "resumes by itself")
        XCTAssertEqual(SchoolAccount(account: "a", unansweredAt: t).autoLogin(at: t), .off)
    }

    /// 重新输入密码: a checked password lifts both kinds of pause.
    func testEnteringThePasswordAgainEndsThePause() async throws {
        for stored in [SchoolAccount(account: "99100991", password: "old", paused: true),
                       SchoolAccount(account: "99100991", password: "old", unansweredAt: Date(timeIntervalSince1970: 1_793_300_000))] {
            let h = harness(FakePasswordLogin(.success(Self.freshToken)))
            try h.signedIn()
            try h.vault.saveAccount(stored)
            try await h.session().savePassword("synthetic-pw-991")
            let account = try XCTUnwrap(try h.vault.account())
            XCTAssertEqual(account.autoLogin(at: h.clock.now), .on)
            XCTAssertEqual(account.usablePassword, "synthetic-pw-991")
        }
    }

    func testAccountIsMaskedAndNeverPrinted() {
        let a = SchoolAccount(account: "99100991", password: "synthetic-pw-991")
        XCTAssertEqual(a.masked, "99••••91")
        XCTAssertFalse("\(a)".contains("991009"))
        XCTAssertFalse("\(a)".contains("synthetic"))
        XCTAssertNil(SchoolAccount(account: "a", password: "p", paused: true).usablePassword)
    }
}
