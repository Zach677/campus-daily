import XCTest
@testable import Core
import CoreTestSupport

/// The lease lasts the whole refresh chain (portal exchange, password login, exchange after it),
/// and every step that mints, logs in or writes a credential checks it is still held.
final class RefreshLeaseChainTests: XCTestCase {
    func refresher(_ h: Harness, owner: String, leaseWait: TimeInterval = 500,
                   renewEvery: TimeInterval = RefreshLease.renewInterval) -> SnapshotRefresher {
        SnapshotRefresher(school: h.session(), store: h.snapshots,
                          lease: RefreshLease(store: h.store, owner: owner, now: h.clock.function),
                          leaseWait: leaseWait, sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000) },
                          renewInterval: renewEvery)
    }

    func passwordHarness(_ login: FakePasswordLogin) throws -> Harness {
        var h = Harness()
        h.passwordLogin = login
        try h.signedIn()
        try h.vault.savePortalToken(PortalToken("OLD", expiresAt: h.clock.now.addingTimeInterval(-1)))
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        return h
    }

    func testTheLeaseOutlastsTheSlowestChain() {
        XCTAssertGreaterThanOrEqual(RefreshLease.defaultDuration, 180)
        XCTAssertLessThan(RefreshLease.renewInterval, RefreshLease.defaultDuration / 3)
    }

    /// A chain slower than the lease itself: the holder keeps renewing it, so the other process
    /// never takes over halfway, never exchanges and never logs in a second time.
    func testASlowChainKeepsTheLeaseSoTheOtherProcessNeitherMintsNorLogsIn() async throws {
        let login = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
        let h = try passwordHarness(login)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "AFTER-PASSWORD"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let reached = expectation(description: "exchange after the password in flight")
        let release = DispatchSemaphore(value: 0)
        h.server.gate { r in
            guard r.url.path.hasSuffix("/csalogintoken/450010") else { return }
            reached.fulfill()
            release.wait()
        }
        let app = refresher(h, owner: "app-1", renewEvery: 0.01)
        async let first = app.refresh(inBackground: false)
        await fulfillment(of: [reached], timeout: 5)
        // 300 s pass in the middle of the chain, longer than one lease.
        for _ in 0..<3 {
            h.clock.advance(100)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let widget = refresher(h, owner: "widget-1", leaseWait: 1)
        let w = await widget.refresh(inBackground: true)
        XCTAssertFalse(w.snapshotSaved, "the widget found the lease held and read nothing")
        release.signal()
        let a = await first
        XCTAssertEqual(a.outcome, .ok)
        XCTAssertTrue(a.snapshotSaved)
        XCTAssertEqual(login.calls.count, 1, "one password login")
        XCTAssertEqual(h.server.requests(path: "/csalogintoken/450010").count, 1, "one exchange")
        XCTAssertEqual(h.livenessCalls(), 2, "the widget never read the school")
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "AFTER-PASSWORD")
    }

    /// The lease was lost while the portal exchange ran: the saved password is not sent.
    func testLostLeaseStopsBeforeThePasswordLogin() async throws {
        let login = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
        var h = Harness()
        h.passwordLogin = login
        try h.signedIn(portal: true)
        try h.vault.saveAccount(SchoolAccount(account: "99100991", password: "synthetic-pw-991"))
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"))
        let store = h.store, clock = h.clock
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getMyECard") else { return }
            clock.advance(RefreshLease.defaultDuration + 1)
            XCTAssertTrue(RefreshLease(store: store, owner: "app-2", now: clock.function).acquire())
        }
        let report = await refresher(h, owner: "widget-1").refresh(inBackground: true)
        XCTAssertTrue(login.calls.isEmpty, "no password login without the lease")
        XCTAssertFalse(report.snapshotSaved)
        XCTAssertEqual(try h.vault.portalToken()?.value, "PORTAL")
        XCTAssertEqual(try h.vault.account()?.paused, false, "a login that was never sent pauses nothing")
    }

    /// The lease was lost after the password was accepted: the new portal token is not saved and
    /// the session is not written back; the holder's own login is the one that counts.
    func testLostLeaseAfterThePasswordWritesNoCredential() async throws {
        let login = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
        let h = try passwordHarness(login)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "AFTER-PASSWORD"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        let store = h.store, clock = h.clock
        h.server.gate { r in
            guard r.url.path.hasSuffix("/csalogintoken/450010") else { return }
            clock.advance(RefreshLease.defaultDuration + 1)
            XCTAssertTrue(RefreshLease(store: store, owner: "app-2", now: clock.function).acquire())
        }
        let report = await refresher(h, owner: "widget-1").refresh(inBackground: true)
        XCTAssertFalse(report.snapshotSaved)
        XCTAssertEqual(try h.vault.portalToken()?.value, "OLD")
        XCTAssertEqual(try h.vault.ecyktSession()?.token, T.session().token)
    }

    /// Even with nothing to mint, the live session is written back only while the lease is held.
    func testWriteBackNeedsTheLease() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let store = h.store, clock = h.clock
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getSysBindCustInfo") else { return }
            clock.advance(RefreshLease.defaultDuration + 1)
            XCTAssertTrue(RefreshLease(store: store, owner: "app-2", now: clock.function).acquire())
        }
        let report = await refresher(h, owner: "widget-1").refresh(inBackground: true)
        XCTAssertFalse(report.snapshotSaved)
        XCTAssertNil(try h.vault.ecyktSession()?.lastAliveAt, "not written back")
        XCTAssertTrue(h.server.requests(path: "/getUserBalance").isEmpty)
    }
}

/// A sign-out in one process while the other is in the middle of a password login: nothing the
/// login produced is written back.
final class SignOutDuringOtherProcessLoginTests: XCTestCase {
    func run(revokingLease: Bool) async throws {
        let login = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
        let h = try RefreshLeaseChainTests().passwordHarness(login)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "AFTER-PASSWORD"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let reached = expectation(description: "login in flight")
        let release = DispatchSemaphore(value: 0)
        h.server.gate { r in
            guard r.url.path.hasSuffix("/csalogintoken/450010") else { return }
            reached.fulfill()
            release.wait()
        }
        let widget = RefreshLeaseChainTests().refresher(h, owner: "widget-1")
        async let read = widget.refresh(inBackground: true)
        await fulfillment(of: [reached], timeout: 5)
        // The app signs out: lease first (unless an older build), then every school item.
        let app = RefreshLeaseChainTests().refresher(h, owner: "app-1")
        if revokingLease { app.revokeLease() }
        try await h.session().signOut()
        try await app.clear()
        if !revokingLease {
            // An older app build left the lease in place.
            XCTAssertTrue(RefreshLease(store: h.store, owner: "widget-1", now: h.clock.function).acquire())
        }
        release.signal()
        let report = await read
        // Without the lease revoked the read may store the same signed-out snapshot again.
        if revokingLease { XCTAssertFalse(report.snapshotSaved) }
        XCTAssertEqual(report.outcome, revokingLease ? .failed(.timedOut) : .notSignedIn)
        XCTAssertNil(try h.vault.portalToken(), "revoking: \(revokingLease)")
        XCTAssertNil(try h.vault.ecyktSession())
        XCTAssertNil(try h.vault.account())
        XCTAssertNil(try h.vault.loginDeviceID())
        XCTAssertEqual(try h.snapshots.loadSnapshot(), SchoolSnapshotReducer.reduce(.empty, .signedOut))
    }

    func testRevokedLeaseStopsTheOtherProcessWritingBack() async throws { try await run(revokingLease: true) }

    func testCredentialsAreReadAgainBeforeWritingEvenWithTheLease() async throws { try await run(revokingLease: false) }
}
