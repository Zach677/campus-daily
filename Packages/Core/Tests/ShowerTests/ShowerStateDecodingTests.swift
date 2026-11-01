import XCTest
@testable import Core
import CoreTestSupport

/// A session record saved by another build (older or newer) still reads: missing fields get
/// their defaults, unknown values in fields that only explain the record are dropped. Only a
/// record without a readable phase is unreadable, and that is told apart from a Keychain error.
final class ShowerStateDecodingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func decode(_ json: String) throws -> ShowerState {
        try JSONDecoder().decode(ShowerState.self, from: Data(json.utf8))
    }

    /// The record the shower's first release wrote, before `authorizationNotWritten` existed.
    func testTheRecordOfTheFirstReleaseDecodes() throws {
        let s = try decode("""
        {"phase":"writePending","machineID":"11223344","peripheralID":"P","startedAt":\(t0.timeIntervalSinceReferenceDate),
         "authorizeSent":true,"authorizationID":"001122FF","closeSent":false,"stateReviewRequired":false,"reviewing":false,
         "settleRetryArmed":false,"manualSettleAttempts":0}
        """)
        XCTAssertEqual(s.phase, .writePending)
        XCTAssertEqual(s.startedAt, t0)
        XCTAssertEqual(s.authorizationID, "001122FF")
        XCTAssertFalse(s.authorizationNotWritten, "not proven unsent")
        XCTAssertTrue(s.canFinish)
    }

    /// Only the phase and a few ids: every flag gets its default, and a step that may have
    /// happened counts as happened.
    func testAnOlderRecordMissingFieldsGetsSafeDefaults() throws {
        let running = try decode(#"{"phase":"running","machineID":"11223344","authorizationID":"001122FF"}"#)
        XCTAssertEqual(running.phase, .running)
        XCTAssertFalse(running.stateReviewRequired)
        XCTAssertFalse(running.reviewing)
        XCTAssertFalse(running.settleRetryArmed)
        XCTAssertEqual(running.manualSettleAttempts, 0)
        XCTAssertFalse(running.holdSettle)
        XCTAssertTrue(running.canFinish)

        let authorizing = try decode(#"{"phase":"authorizing","machineID":"11223344"}"#)
        XCTAssertTrue(authorizing.authorizeSent, "may have left")
        XCTAssertEqual(ShowerReducer.restore(authorizing).failure?.reason, .authorizeUncertain)

        let closing = try decode(#"{"phase":"closing","machineID":"11223344","closingFrom":"running"}"#)
        XCTAssertTrue(closing.closeSent, "may have left")
        XCTAssertEqual(ShowerReducer.restore(closing).failure?.reason, .closeUnconfirmed)

        let failed = try decode(#"{"phase":"failed","machineID":"11223344","failure":{"reason":"settleUncertain"}}"#)
        XCTAssertEqual(failed.failure?.needsReview, true, "kept for a check")
        XCTAssertFalse(failed.canStart)
    }

    /// Values a newer build may write in fields that only describe the record.
    func testUnknownValuesInDescriptiveFieldsAreDropped() throws {
        let s = try decode("""
        {"phase":"failed","machineID":"11223344","closingFrom":"someLaterPhase","notice":{"someLaterNotice":{}},
         "failure":{"reason":"closeUnconfirmed","needsReview":true,"deviceError":"someLaterError","error":{"someLaterError":{}}},
         "lastReceipt":{"amount":"not money"},"someLaterField":1}
        """)
        XCTAssertEqual(s.failure?.reason, .closeUnconfirmed)
        XCTAssertNil(s.failure?.deviceError)
        XCTAssertNil(s.failure?.error)
        XCTAssertNil(s.closingFrom)
        XCTAssertNil(s.notice)
        XCTAssertNil(s.lastReceipt)
        XCTAssertTrue(s.canResolveManually)
    }

    func testARecordWithoutAReadablePhaseIsUnreadableNotAStorageError() throws {
        XCTAssertThrowsError(try decode(#"{"machineID":"11223344"}"#))
        XCTAssertThrowsError(try decode(#"{"phase":"someLaterPhase"}"#))

        let store = InMemorySecureStore()
        try store.write(Data(#"{"phase":"someLaterPhase","machineID":"11223344"}"#.utf8), for: .showerSession)
        XCTAssertThrowsError(try ShowerEngine(transport: FakeShowerTransport(), gateway: FakeGateway(), vault: StoredShowerVault(store: store),
                                              configuration: .init(bleName: "fixture-ble"))) {
            XCTAssertEqual($0 as? ShowerEngineError, .unreadableRecord)
        }
        let locked = InMemorySecureStore()
        locked.failReads()
        XCTAssertThrowsError(try ShowerEngine(transport: FakeShowerTransport(), gateway: FakeGateway(), vault: StoredShowerVault(store: locked),
                                              configuration: .init(bleName: "fixture-ble"))) {
            XCTAssertEqual($0 as? ShowerEngineError, .storage)
        }
    }

    func testEveryFieldRoundTrips() throws {
        let s = ShowerState(phase: .failed, machineID: "11223344", peripheralID: "P", startedAt: t0, authorizeSent: true,
                            authorizationID: "001122FF", closingFrom: .writePending, closeSent: true, consumption: "55AA",
                            receipt: ShowerReceipt(amount: Money(fen: 1)), lastReceipt: ShowerReceipt(amount: Money(fen: 2)),
                            failure: ShowerFailure(reason: .settleRefused, needsReview: true, error: .timedOut, deviceError: .busy),
                            stateReviewRequired: true, reviewing: true, settleRetryArmed: true, manualSettleAttempts: 3,
                            endedAt: t0.addingTimeInterval(60), notice: .device(.timedOut), authorizationNotWritten: true,
                            holdSettle: true)
        XCTAssertEqual(try JSONDecoder().decode(ShowerState.self, from: JSONEncoder().encode(s)), s)
    }
}
