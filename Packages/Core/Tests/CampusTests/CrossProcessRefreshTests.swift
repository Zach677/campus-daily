import XCTest
@testable import Core
import CoreTestSupport

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ l: String) { lock.withLock { lines.append(l) } }
    var all: [String] { lock.withLock { lines } }
}

/// The app and the widget are two processes over one Keychain: here two sessions and two
/// refreshers (different lease owners) over one in-memory store.
final class CrossProcessRefreshTests: XCTestCase {
    func refresher(_ h: Harness, owner: String) -> SnapshotRefresher {
        SnapshotRefresher(school: h.session(), store: h.snapshots,
                          lease: RefreshLease(store: h.store, owner: owner, now: h.clock.function),
                          leaseWait: 500, sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000) })
    }

    /// Both find the card session dead at once: only one mints (one ticket, one exchange); the
    /// other waits for the lease and then reads with the session the first one stored.
    func testOnlyOneProcessMintsANewCardSession() async throws {
        let h = Harness()
        try h.signedIn(portal: true)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "MINTED-ONCE"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let reached = expectation(description: "exchange in flight")
        let release = DispatchSemaphore(value: 0)
        h.server.gate { r in
            guard r.url.path.hasSuffix("/csalogintoken/450010") else { return }
            reached.fulfill()
            release.wait()
        }
        let app = refresher(h, owner: "app-1"), widget = refresher(h, owner: "widget-1")
        async let first = app.refresh(inBackground: false)
        await fulfillment(of: [reached], timeout: 5)
        async let second = widget.refresh(inBackground: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.livenessCalls(), 1, "the widget waits for the lease instead of reading")
        release.signal()
        let (a, w) = await (first, second)
        XCTAssertEqual(a.outcome, .ok)
        XCTAssertEqual(w.outcome, .ok)
        XCTAssertTrue(a.reexchanged)
        XCTAssertFalse(w.reexchanged)
        XCTAssertEqual(h.server.requests(path: "/csalogintoken/450010").count, 1)
        XCTAssertEqual(h.server.requests(path: "/getMyECard").count, 1)
        XCTAssertEqual(h.server.requests(path: "/getSysBindCustInfo").last?.header("acc_token"), "MINTED-ONCE")
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "MINTED-ONCE")
        XCTAssertNil(try h.store.read(.sharedRefreshLease), "both gave the lease back")
    }

    /// After taking the lease, the stored session is read again before minting: one stored by
    /// the other process meanwhile is used, nothing is minted.
    func testSessionStoredMeanwhileIsUsedInsteadOfMinting() async throws {
        let h = Harness()
        try h.signedIn(portal: true)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let vault = h.vault
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getSysBindCustInfo"), r.header("acc_token") != "OTHER-PROCESS" else { return }
            try? vault.saveEcyktSession(T.session(token: "OTHER-PROCESS"))
        }
        let report = await refresher(h, owner: "widget-1").refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertTrue(h.server.requests(path: "/getMyECard").isEmpty)
        XCTAssertTrue(h.server.requests(path: "/csalogintoken/450010").isEmpty)
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "OTHER-PROCESS")
    }

    /// Signed out in the other process while this one read: nothing is written back, the
    /// snapshot the other process emptied stays empty.
    func testSignOutInTheOtherProcessIsNotUndone() async throws {
        let h = Harness()
        try h.signedIn(meter: Harness.roomBinding)
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        try h.server.serve("ecykt/electric-getMeterStatus-room", matchBody: ["server", "buildingID"])
        let store = h.store
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getSysBindCustInfo") else { return }
            for key in StoreKey.allCases { try? store.delete(key) }
            try? SharedSnapshotStore(store: store).saveSnapshot(.empty)
        }
        let report = await refresher(h, owner: "widget-1").refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .notSignedIn)
        XCTAssertNil(try h.vault.ecyktSession())
        XCTAssertEqual(try h.snapshots.loadSnapshot(), .empty)
    }

    /// A newer session the other process stored while this one read is never overwritten.
    func testNewerSessionFromTheOtherProcessIsKept() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let vault = h.vault
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getSysBindCustInfo") else { return }
            try? vault.saveEcyktSession(T.session(token: "NEWER"))
        }
        let report = await refresher(h, owner: "app-1").refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "NEWER")
    }

    /// The background read (and so the widget) renews the card session with the portal token,
    /// like the foreground.
    func testBackgroundRenewsWithThePortalToken() async throws {
        let h = Harness()
        try h.signedIn(portal: true)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "BACKGROUND-RENEWED"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let report = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertTrue(report.reexchanged)
        XCTAssertFalse(report.snapshot.needsLogin)
        XCTAssertEqual(try h.vault.ecyktSession()?.token, "BACKGROUND-RENEWED")
    }

    /// The lease ran out and another process took it before this one minted: it stops without
    /// minting or writing anything.
    func testLostLeaseStopsBeforeMinting() async throws {
        let h = Harness()
        try h.signedIn(portal: true)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        let store = h.store, clock = h.clock
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getSysBindCustInfo") else { return }
            clock.advance(RefreshLease.defaultDuration + 1)
            XCTAssertTrue(RefreshLease(store: store, owner: "app-2", now: clock.function).acquire())
        }
        let report = await refresher(h, owner: "widget-1").refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .leaseLost)
        XCTAssertFalse(report.snapshotSaved)
        XCTAssertTrue(h.server.requests(path: "/getMyECard").isEmpty)
        XCTAssertEqual(try h.vault.ecyktSession()?.token, T.session().token)
        XCTAssertNil(try h.snapshots.loadSnapshot())
        XCTAssertNotNil(try h.store.read(.sharedRefreshLease), "the other owner's lease stays")
    }

    func testSignOutClearsTheLease() async throws {
        let h = Harness()
        XCTAssertTrue(RefreshLease(store: h.store, owner: "widget-1", now: h.clock.function).acquire())
        try await refresher(h, owner: "app-1").clear()
        XCTAssertNil(try h.store.read(.sharedRefreshLease))
    }
}

/// When a card session or portal token turns out dead, one diagnostic line: kind and measured
/// minutes only.
final class CredentialLifetimeLogTests: XCTestCase {
    static let pattern = #"^school\.credentialExpired kind=(card|portal) ageMinutes=(\d+|unknown)( aliveMinutes=(\d+|unknown))?$"#

    func testCardSessionAgeAndLastAliveAreLoggedOnce() async throws {
        let lines = Lines()
        var h = Harness()
        h.diagnostic = { lines.append($0) }
        try h.signedIn(portal: true)
        // Minted by the portal exchange now.
        try h.server.serve("ecykt/getSysBindCustInfo-badToken", times: 1)
        h.server.serve(try T.eCardWithTicket(), times: 1)
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "MINTED"), times: 1)
        try h.server.serve("ecykt/getSysBindCustInfo-ok", times: 2)
        try h.server.serve("ecykt/getUserBalance-ok")
        let session = h.session()
        let refresher = SnapshotRefresher(school: session, store: h.snapshots)
        _ = await refresher.refresh(inBackground: true)
        let minted = h.clock.now
        XCTAssertEqual(try h.vault.ecyktSession()?.obtainedAt, minted)
        h.clock.advance(92 * 60)
        _ = await refresher.refresh(inBackground: true)
        XCTAssertEqual(try h.vault.ecyktSession()?.lastAliveAt, minted.addingTimeInterval(92 * 60))
        h.clock.advance(60 * 60)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"))
        _ = await refresher.refresh(inBackground: true)
        _ = await refresher.refresh(inBackground: true)
        let cardLines = lines.all.filter { $0.contains("kind=card") }
        XCTAssertEqual(cardLines.last, "school.credentialExpired kind=card ageMinutes=152 aliveMinutes=92")
        XCTAssertEqual(cardLines.filter { $0.contains("ageMinutes=152") }.count, 1, "a dead session read again is not logged again")
        for line in lines.all {
            XCTAssertNotNil(line.range(of: Self.pattern, options: .regularExpression), line)
            XCTAssertFalse(line.contains("MINTED") || line.contains("PORTAL"), "never a value")
        }
    }

    func testPortalTokenAgeIsLogged() async throws {
        let lines = Lines()
        var h = Harness()
        h.diagnostic = { lines.append($0) }
        try h.signedIn()
        let obtained = h.clock.now
        try h.vault.savePortalToken(PortalToken("PORTAL", obtainedAt: obtained))
        h.clock.advance(481 * 60)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"))
        let report = await h.refresher().refresh(inBackground: true)
        XCTAssertEqual(report.outcome, .needsLogin(.sessionExpired(.portal)))
        XCTAssertTrue(lines.all.contains("school.credentialExpired kind=portal ageMinutes=481"))
        XCTAssertTrue(lines.all.contains("school.credentialExpired kind=card ageMinutes=unknown aliveMinutes=unknown"),
                      "a session saved by an older build has no stamp")
    }

    /// A portal token gets its stamp when first saved, from the sign-in path.
    func testSignInStampsBothCredentials() async throws {
        let h = Harness()
        h.server.serve(try T.eCardWithTicket())
        h.server.respond("POST", T.exchangeURL, body: T.exchangeBody(token: "NEW"))
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        _ = try await h.session().signIn(portalToken: PortalToken("PORTAL"))
        XCTAssertEqual(try h.vault.portalToken()?.obtainedAt, h.clock.now)
        XCTAssertEqual(try h.vault.ecyktSession()?.obtainedAt, h.clock.now)
    }

    func testEventFormat() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SchoolSession.expiredEvent(.card, obtainedAt: t, lastAliveAt: t.addingTimeInterval(5_520), now: t.addingTimeInterval(9_120)),
                       "school.credentialExpired kind=card ageMinutes=152 aliveMinutes=92")
        XCTAssertEqual(SchoolSession.expiredEvent(.portal, obtainedAt: nil, lastAliveAt: nil, now: t),
                       "school.credentialExpired kind=portal ageMinutes=unknown")
    }
}

/// The lifetime lines are also kept in the shared Keychain for the in-app diagnostics export.
final class CredentialLifetimeStoreTests: XCTestCase {
    func testExpiredLinesAreKeptForTheExportWithoutValues() async throws {
        var h = Harness()
        h.keepsCredentialLog = true
        try h.signedIn()
        let obtained = h.clock.now
        try h.vault.savePortalToken(PortalToken("PORTAL", obtainedAt: obtained))
        h.clock.advance(481 * 60)
        try h.server.serve("ecykt/getSysBindCustInfo-badToken")
        h.server.serve(try FixtureLoader.load("portal/getMyInfo-badtoken").withURLPath("/portal-api/v2/personalData/getMyECard"))
        _ = await h.refresher().refresh(inBackground: true)
        let kept = CredentialLifetimeLog(store: h.store).entries()
        XCTAssertEqual(kept.map(\.event), ["school.credentialExpired kind=card ageMinutes=unknown aliveMinutes=unknown",
                                           "school.credentialExpired kind=portal ageMinutes=481"])
        XCTAssertEqual(kept.last?.at, h.clock.now)
        let raw = String(decoding: try XCTUnwrap(h.store.read(.sharedCredentialLog)), as: UTF8.self)
        for value in ["PORTAL", "REDACTED_TOKEN_2", T.syscustid] {
            XCTAssertFalse(raw.contains(value), "never a credential value")
        }
        for line in kept {
            XCTAssertNotNil(line.event.range(of: CredentialLifetimeLogTests.pattern, options: .regularExpression), line.event)
        }
    }

    func testOnlyTheLatestLinesAreKept() {
        let store = InMemorySecureStore()
        let log = CredentialLifetimeLog(store: store)
        for i in 0..<(CredentialLifetimeLog.limit + 5) {
            log.append("school.credentialExpired kind=card ageMinutes=\(i) aliveMinutes=0", at: Date(timeIntervalSince1970: Double(i)))
        }
        let kept = log.entries()
        XCTAssertEqual(kept.count, CredentialLifetimeLog.limit)
        XCTAssertEqual(kept.first?.event, "school.credentialExpired kind=card ageMinutes=5 aliveMinutes=0")
    }

    func testSignOutKeepsTheLinesAndResetDeletesThem() async throws {
        let h = Harness()
        try h.signedIn()
        CredentialLifetimeLog(store: h.store).append("school.credentialExpired kind=portal ageMinutes=3", at: h.clock.now)
        try await h.session().signOut()
        XCTAssertEqual(CredentialLifetimeLog(store: h.store).entries().count, 1)
        XCTAssertTrue(AppReset.keychainItems.contains(.sharedCredentialLog))
    }
}

/// Paths outside the lease (sign-in, saving a password, recharge, the hot-water handoff) may
/// store a session with the same token and new ciphertexts: the refresh doesn't overwrite it.
final class WriteBackComparisonTests: XCTestCase {
    func testASessionWithTheSameTokenButANewSyscustidIsKept() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        let vault = h.vault
        let rotated = T.session(syscustid: "TESTsyscus%3Ntid00000000000000000000000000%1H00%7J" + "-rotated")
        h.server.gate { r in
            guard r.url.path.hasSuffix("/getSysBindCustInfo") else { return }
            try? vault.saveEcyktSession(rotated)
        }
        let report = await h.refresher().refresh(inBackground: false)
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertEqual(try h.vault.ecyktSession(), rotated, "not overwritten with the older ciphertext")
    }
}
