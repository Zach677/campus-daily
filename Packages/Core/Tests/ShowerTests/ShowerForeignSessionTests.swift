import XCTest
@testable import Core
import CoreTestSupport

/// An `A5` (water running) that is most likely someone else's session never gets closed or
/// settled under this record without the user: after a close that most likely took, the next
/// consumption frame is kept for a manual settle; with an authorization that provably never
/// reached the controller, no close is sent at all.
final class ShowerForeignSessionTests: XCTestCase {
    let machine = "11223344"
    let binding = ShowerBinding(studentId: "S1234567", schoolId: "20021", machineId: "11223344", roomId: "R1", roomLabel: "99栋 991")
    let auth = ShowerAuthorization(machineID: "11223344", payload: Data((0..<15).map { UInt8(0x30 + $0) }), authorizationID: "001122FF")
    let close = Data([0xAC, 0x55, 0x44, 0x77, 0xAA])
    let receipt = ShowerReceipt(amount: Money(fen: 163))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var identity: Data { FakeFrames.identity(machine) }
    var consumption: Data { FakeFrames.identity(machine, tail: 9) }

    var vault: StoredShowerVault!
    var transport: FakeShowerTransport!
    var gateway: FakeGateway!

    override func setUp() { reset() }

    func reset() {
        vault = StoredShowerVault(store: InMemorySecureStore())
        transport = FakeShowerTransport()
        gateway = FakeGateway()
    }

    func engine() throws -> ShowerEngine {
        try ShowerEngine(transport: transport, gateway: gateway, vault: vault,
                         configuration: .init(bleName: "fixture-ble"), now: { [t0] in t0 })
    }

    func running() async throws -> ShowerEngine {
        let e = try engine()
        transport.script(.frame(identity), .frame(FakeFrames.ack))
        gateway.scriptAuthorize(.ok(auth))
        let s = try await e.start(binding)
        XCTAssertEqual(s.phase, .running)
        return e
    }

    /// The two ways into an unconfirmed close: the answer to the close was lost, or it came
    /// back with another machine's identity.
    func closeUnconfirmed(byWrongIdentity: Bool) async throws -> ShowerEngine {
        let e = try await running()
        transport.script(.frame(FakeFrames.active), byWrongIdentity ? .frame(FakeFrames.identity("99999999", tail: 9)) : .fail(.timedOut))
        let s = try await e.finish(binding)
        XCTAssertEqual(s.failure?.reason, .closeUnconfirmed)
        return e
    }

    // MARK: Back from an unconfirmed close

    func testAfterAnUnconfirmedCloseTheNextConsumptionIsKeptNotSettled() async throws {
        for wrongIdentity in [false, true] {
            reset()
            let e = try await closeUnconfirmed(byWrongIdentity: wrongIdentity)
            transport.script(.frame(FakeFrames.active))
            let back = try await e.review(binding)
            XCTAssertEqual(back.phase, .running, "\(wrongIdentity)")
            XCTAssertTrue(back.canFinish)

            transport.script(.frame(FakeFrames.active), .frame(consumption))
            gateway.scriptSettle(.ok(receipt))
            let held = try await e.finish(binding)
            XCTAssertTrue(gateway.settleFrames.isEmpty, "not settled by itself (\(wrongIdentity))")
            XCTAssertEqual(held.phase, .failed)
            XCTAssertEqual(held.failure?.needsReview, true)
            XCTAssertEqual(held.consumption, HexCoding.upper(consumption), "kept for the retry")
            XCTAssertTrue(held.canRetrySettle)
            XCTAssertTrue(held.canResolveManually)
            XCTAssertEqual(ShowerPage(held)?.phase, .unsure)
            XCTAssertEqual(try vault.showerState()?.consumption, HexCoding.upper(consumption), "persisted")

            // The usual two taps send it once.
            _ = try await e.requestSettleRetry()
            XCTAssertTrue(gateway.settleFrames.isEmpty)
            let done = try await e.confirmSettleRetry(binding)
            XCTAssertEqual(done.phase, .done)
            XCTAssertEqual(gateway.settleFrames, [consumption])
        }
    }

    /// The hold is only for a session that came back from an unconfirmed close.
    func testAnOrdinaryEndStillSettlesByItself() async throws {
        let e = try await running()
        transport.script(.frame(FakeFrames.active), .frame(consumption))
        gateway.scriptSettle(.ok(receipt))
        let done = try await e.finish(binding)
        XCTAssertEqual(done.phase, .done)
        XCTAssertEqual(gateway.settleFrames, [consumption])
    }

    func testTheHoldSurvivesARelaunch() async throws {
        let e = try await closeUnconfirmed(byWrongIdentity: false)
        transport.script(.frame(FakeFrames.active))
        _ = try await e.review(binding)

        let relaunched = try engine()
        transport.script(.frame(FakeFrames.active), .frame(consumption))
        let held = try await relaunched.finish(binding)
        XCTAssertTrue(gateway.settleFrames.isEmpty)
        XCTAssertTrue(held.canRetrySettle)
    }
}
