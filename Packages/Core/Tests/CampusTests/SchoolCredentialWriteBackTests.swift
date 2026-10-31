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
