import XCTest
@testable import Core
import CoreTestSupport

/// Recharge and the hot-water hand-off read the card session, wait on the network and then
/// write the live session back. Meanwhile the widget may have stored a newer session: the
/// late write must not put the older one back over it.
final class SchoolCredentialWriteBackTests: XCTestCase {
    typealias Hold = SchoolPersonSwitchRaceTests.Hold

    /// What the widget's refresh stores while the app's call is held: a re-exchanged session.
    static let newer = T.session(token: "NEWER-TOKEN", syscustid: "NEWER-SYSCUSTID")

    func session(_ h: Harness, _ hold: Hold) -> SchoolSession {
        SchoolSession(portal: PortalClient(http: hold), ecykt: EcyktClient(http: hold), vault: h.vault, now: h.clock.function)
    }

    func testRechargePreparationKeepsANewerSessionStoredMeanwhile() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/loginBySysId-mintSeries1")
        let hold = Hold(h, self, suffix: "/loginBySysId")
        let session = session(h, hold)
        async let result = session.rechargeSession(.card)
        await fulfillment(of: [hold.reached], timeout: 5)
        try h.vault.saveEcyktSession(Self.newer)
        hold.release()
        _ = try await result
        let stored = try XCTUnwrap(try h.vault.ecyktSession())
        XCTAssertEqual(stored.token, "NEWER-TOKEN", "the older session is not written over the newer one")
        XCTAssertEqual(stored.syscustid, "NEWER-SYSCUSTID")
    }

    func testShowerHandoffKeepsANewerSessionStoredMeanwhile() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getSignData-ok")
        let hold = Hold(h, self, suffix: "/getSysBindCustInfo")
        let session = session(h, hold)
        async let result = session.showerHandoff()
        await fulfillment(of: [hold.reached], timeout: 5)
        try h.vault.saveEcyktSession(Self.newer)
        hold.release()
        _ = try await result
        let stored = try XCTUnwrap(try h.vault.ecyktSession())
        XCTAssertEqual(stored.token, "NEWER-TOKEN", "the older session is not written over the newer one")
        XCTAssertEqual(stored.syscustid, "NEWER-SYSCUSTID")
    }

    /// The app was suspended past the lease while its call was out, and the widget took the
    /// lease: whatever the widget does next, the app's late copy is not written back.
    func testACallThatLostTheLeaseWritesNothingBack() async throws {
        for handoff in [false, true] {
            let h = Harness()
            try h.signedIn()
            try h.server.serve("ecykt/getSysBindCustInfo-ok")
            try h.server.serve(handoff ? "ecykt/getSignData-ok" : "ecykt/loginBySysId-mintSeries1")
            let before = try XCTUnwrap(try h.vault.ecyktSession())
            let hold = Hold(h, self, suffix: handoff ? "/getSysBindCustInfo" : "/loginBySysId")
            let session = session(h, hold)
            let app = SnapshotRefresher(school: session, store: h.snapshots,
                                        lease: RefreshLease(file: h.store.leaseFile, owner: "app-1", now: h.clock.function),
                                        leaseWait: 3, sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) },
                                        renewInterval: 3600)
            async let result: Void = app.holdingLease { mayWrite in
                if handoff { _ = try await session.showerHandoff(mayWrite: mayWrite) }
                else { _ = try await session.rechargeSession(.card, mayWrite: mayWrite) }
            }
            await fulfillment(of: [hold.reached], timeout: 5)
            h.clock.advance(RefreshLease.defaultDuration + 1)
            let widget = RefreshLease(file: h.store.leaseFile, owner: "widget-1", now: h.clock.function)
            XCTAssertTrue(widget.acquire(), "the app's lease ran out")
            hold.release()
            try await result
            XCTAssertEqual(try h.vault.ecyktSession(), before, "nothing written without the lease")
            XCTAssertEqual(h.store.leaseFile.storedOwner(), "widget-1")
        }
    }

    /// Nothing changed meanwhile: the latest ciphertexts are still kept for next time.
    func testRechargePreparationStillSavesTheLatestCiphertext() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/loginBySysId-mintSeries1")
        let before = try XCTUnwrap(try h.vault.ecyktSession())
        _ = try await h.session().rechargeSession(.card)
        let stored = try XCTUnwrap(try h.vault.ecyktSession())
        XCTAssertEqual(stored.token, before.token)
        XCTAssertNotEqual(stored.syscustid, before.syscustid, "the fresh syscustid is kept")
    }
}
