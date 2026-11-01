import XCTest
@testable import Core
import CoreTestSupport

/// 再结算一次 on the 不确定 face: offered only for a settlement that failed with its consumption
/// kept; the first tap arms it, the second sends it once more.
final class ShowerSettleRetryPageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let consumption = HexCoding.upper(FakeFrames.identity("11223344", tail: 9))

    func failed(_ reason: ShowerFailureReason, review: Bool = true, consumption: String?) -> ShowerState {
        ShowerState(phase: .failed, machineID: "11223344", startedAt: t0, consumption: consumption,
                    failure: ShowerFailure(reason: reason, needsReview: review))
    }

    func reduce(_ flow: inout ShowerPageFlow, _ event: ShowerPageEvent) -> [ShowerPageEffect] {
        let (next, effects) = ShowerPageFlow.reduce(flow, event)
        flow = next
        return effects
    }

    func testRetryIsOfferedOnlyForASettlementThatFailedWithItsConsumption() {
        for reason in [ShowerFailureReason.settleRefused, .settleUncertain, .settleUnconfirmed] {
            let flow = ShowerPageFlow(record: failed(reason, consumption: consumption), presented: true)
            XCTAssertEqual(flow.page?.phase, .unsure)
            XCTAssertTrue(flow.mayRetrySettle, reason.rawValue)
            XCTAssertFalse(ShowerPageFlow(record: failed(reason, consumption: nil)).mayRetrySettle,
                           "\(reason.rawValue): nothing to settle")
        }
        for reason in [ShowerFailureReason.closeUnconfirmed, .authorizeUncertain, .authorizationInvalid] {
            XCTAssertFalse(ShowerPageFlow(record: failed(reason, consumption: consumption)).mayRetrySettle, reason.rawValue)
        }
        let others = [ShowerState(phase: .running, startedAt: t0), ShowerState(phase: .settling, startedAt: t0, consumption: consumption),
                      ShowerState(phase: .running, startedAt: t0, stateReviewRequired: true), ShowerState(phase: .done, startedAt: t0)]
        for record in others {
            XCTAssertFalse(ShowerPageFlow(record: record).mayRetrySettle, "\(record.phase)")
        }
    }

    func testTheFirstTapArmsAndTheSecondSends() {
        let unsure = failed(.settleUncertain, consumption: consumption)
        var flow = ShowerPageFlow(record: unsure, presented: true)
        XCTAssertEqual(reduce(&flow, .settleRetryTapped), [.requestSettleRetry])
        XCTAssertFalse(flow.settleRetryArmed, "armed only once the record says so")

        let armed = ShowerReducer.reduce(unsure, .requestSettleRetry).0
        _ = reduce(&flow, .record(armed))
        XCTAssertTrue(flow.settleRetryArmed)
        XCTAssertEqual(reduce(&flow, .settleRetryTapped), [.confirmSettleRetry])

        var closed = ShowerPageFlow(record: failed(.closeUnconfirmed, consumption: nil), presented: true)
        XCTAssertEqual(reduce(&closed, .settleRetryTapped), [], "nothing to settle")
    }

    /// The retry runs through the engine: the settle goes out again only after the second tap.
    func testTheEngineSendsTheRetryOnlyAfterBothTaps() async throws {
        let store = InMemorySecureStore()
        let vault = StoredShowerVault(store: store)
        try vault.saveShowerState(failed(.settleUncertain, consumption: consumption))
        let gateway = FakeGateway()
        let engine = try ShowerEngine(transport: FakeShowerTransport(), gateway: gateway, vault: vault,
                                      configuration: .init(bleName: "fixture-ble"), now: { [t0] in t0 })
        let binding = ShowerBinding(studentId: "S1234567", schoolId: "20021", machineId: "11223344", roomId: "R1", roomLabel: "99栋 991")
        var flow = ShowerPageFlow(record: await engine.state, presented: true)
        XCTAssertEqual(reduce(&flow, .settleRetryTapped), [.requestSettleRetry])
        _ = reduce(&flow, .record(try await engine.requestSettleRetry()))
        XCTAssertTrue(gateway.settleFrames.isEmpty)
        XCTAssertEqual(reduce(&flow, .settleRetryTapped), [.confirmSettleRetry])
        gateway.scriptSettle(.ok(ShowerReceipt(amount: Money(fen: 163))))
        _ = reduce(&flow, .record(try await engine.confirmSettleRetry(binding)))
        XCTAssertEqual(gateway.settleFrames.count, 1)
        XCTAssertEqual(flow.page?.phase, .done)
        XCTAssertFalse(flow.mayRetrySettle)
    }
}
