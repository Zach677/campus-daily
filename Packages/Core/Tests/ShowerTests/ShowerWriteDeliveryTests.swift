import XCTest
@testable import Core
import CoreTestSupport

/// A write that did not complete counts as not sent only when it never left, or when the
/// controller answered it with an ATT error. A link lost after the write (disconnect, timeout)
/// may have come after the controller applied it.
final class ShowerWriteDeliveryTests: XCTestCase {
    func testAWriteThatNeverLeftWasNotSent() {
        XCTAssertEqual(ShowerWriteDelivery.after(written: false, writeErrorDomain: nil), .notSent)
        XCTAssertEqual(ShowerWriteDelivery.after(written: false, writeErrorDomain: "CBErrorDomain"), .notSent)
    }

    func testAnATTErrorResponseIsARefusal() {
        XCTAssertEqual(ShowerWriteDelivery.attErrorDomain, "CBATTErrorDomain")
        XCTAssertEqual(ShowerWriteDelivery.after(written: true, writeErrorDomain: "CBATTErrorDomain"), .notSent)
    }

    func testALinkErrorAfterTheWriteMayHaveBeenSent() {
        // CBError.peripheralDisconnected, .connectionTimeout and the like.
        XCTAssertEqual(ShowerWriteDelivery.after(written: true, writeErrorDomain: "CBErrorDomain"), .maybeSent)
        XCTAssertEqual(ShowerWriteDelivery.after(written: true, writeErrorDomain: NSPOSIXErrorDomain), .maybeSent)
        XCTAssertEqual(ShowerWriteDelivery.after(written: true, writeErrorDomain: ""), .maybeSent)
    }

    func testNoAnswerAfterTheWriteMayHaveBeenSent() {
        XCTAssertEqual(ShowerWriteDelivery.after(written: true, writeErrorDomain: nil), .maybeSent)
    }

    /// What the engine makes of each: a refused authorization write is proven unwritten, a
    /// link error leaves the write pending; a refused close goes back to the timer, a link
    /// error after it needs a check.
    func testTheEngineFollowsTheClassification() async throws {
        let binding = ShowerBinding(studentId: "S1234567", schoolId: "20021", machineId: "11223344", roomId: "R1", roomLabel: "99栋 991")
        let auth = ShowerAuthorization(machineID: "11223344", payload: Data((0..<15).map { UInt8(0x30 + $0) }), authorizationID: "001122FF")
        func reply(_ domain: String) -> FakeShowerTransport.Reply {
            ShowerWriteDelivery.after(written: true, writeErrorDomain: domain) == .notSent ? .notSent(.disconnected) : .fail(.disconnected)
        }
        func engine() throws -> (ShowerEngine, FakeShowerTransport) {
            let t = FakeShowerTransport(), g = FakeGateway()
            g.scriptAuthorize(.ok(auth))
            return (try ShowerEngine(transport: t, gateway: g, vault: StoredShowerVault(store: InMemorySecureStore()),
                                     configuration: .init(bleName: "fixture-ble")), t)
        }

        var (e, t) = try engine()
        t.script(.frame(FakeFrames.identity("11223344")), reply("CBErrorDomain"))
        var s = try await e.start(binding)
        XCTAssertEqual(s.phase, .writePending)
        XCTAssertFalse(s.authorizationNotWritten, "a link error may have come after the controller took it")

        (e, t) = try engine()
        t.script(.frame(FakeFrames.identity("11223344")), reply("CBATTErrorDomain"))
        s = try await e.start(binding)
        XCTAssertTrue(s.authorizationNotWritten)

        (e, t) = try engine()
        t.script(.frame(FakeFrames.identity("11223344")), .frame(FakeFrames.ack))
        _ = try await e.start(binding)
        t.script(.frame(FakeFrames.active), reply("CBErrorDomain"))
        s = try await e.finish(binding)
        XCTAssertEqual(s.failure?.reason, .closeUnconfirmed)

        (e, t) = try engine()
        t.script(.frame(FakeFrames.identity("11223344")), .frame(FakeFrames.ack))
        _ = try await e.start(binding)
        t.script(.frame(FakeFrames.active), reply("CBATTErrorDomain"))
        s = try await e.finish(binding)
        XCTAssertEqual(s.phase, .running)
    }
}
