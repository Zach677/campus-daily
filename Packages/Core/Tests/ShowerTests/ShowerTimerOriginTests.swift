import XCTest
import Foundation
@testable import Core
import CoreTestSupport

/// A clock the fakes move forward, so "connecting took 15 s" happens without waiting.
private final class StepClock: @unchecked Sendable {
    // @unchecked: state guarded by `lock`.
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

/// The platform takes `delay` seconds (on the step clock) to answer the authorize request.
private struct SlowGateway: ShowerGateway {
    let inner: FakeGateway
    let clock: StepClock
    let delay: TimeInterval
    func authorize(_ binding: ShowerBinding, frame: Data) async throws -> ShowerAuthorization {
        clock.advance(delay)
        return try await inner.authorize(binding, frame: frame)
    }
    func settle(_ binding: ShowerBinding, frame: Data) async throws -> ShowerReceipt {
        try await inner.settle(binding, frame: frame)
    }
}

/// The shower timer counts from the moment water may flow (出水), not from the 开始洗澡 tap:
/// connecting and authorizing take ~15 s that are not shower time.
final class ShowerTimerOriginTests: XCTestCase {
    let machine = "11223344"
    let binding = ShowerBinding(studentId: "S1234567", schoolId: "20021", machineId: "11223344", roomId: "R1", roomLabel: "99栋 991")
    let auth = ShowerAuthorization(machineID: "11223344", payload: Data((0..<15).map { UInt8(0x30 + $0) }), authorizationID: "001122FF")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheTimerTheLockScreenAndTheReminderAllStartWhenTheWaterDoes() async throws {
        let clock = StepClock(t0)
        let transport = FakeShowerTransport()
        let gateway = FakeGateway()
        let vault = StoredShowerVault(store: InMemorySecureStore())
        let engine = try ShowerEngine(transport: transport, gateway: SlowGateway(inner: gateway, clock: clock, delay: 15),
                                      vault: vault, configuration: .init(bleName: "fixture-ble"),
                                      now: { clock.now })
        transport.script(.frame(FakeFrames.identity(machine)), .frame(FakeFrames.ack))
        gateway.scriptAuthorize(.ok(auth))

        let s = try await engine.start(binding)          // tapped at t0, authorized at t0+15
        XCTAssertEqual(s.phase, .running)
        let water = t0.addingTimeInterval(15)
        XCTAssertEqual(s.startedAt, water, "the timer's origin is the water, not the tap")
        XCTAssertEqual(try vault.showerState()?.startedAt, water, "persisted the same way")

        let at20 = t0.addingTimeInterval(20)
        let page = try XCTUnwrap(ShowerPage(s))
        XCTAssertEqual(page.phase, .running)
        XCTAssertEqual(at20.timeIntervalSince(try XCTUnwrap(page.startedAt)), 5, "5 s of water, not 20")

        XCTAssertEqual(ShowerActivityAction(s, now: at20), .show(startedAt: water, writeUnconfirmed: false),
                       "Live Activity / Dynamic Island / lock screen count from the water")
        XCTAssertEqual(AppReset.Resync(shower: s, now: at20).showerReminderStart, water,
                       "the app's reminder is scheduled from the water")
    }

    /// The write is not acknowledged (shown as running on purpose): the water may still flow,
    /// so the timer is there and counts from the same moment.
    func testAnUnacknowledgedWriteStillCountsFromTheWater() {
        let tapped = ShowerReducer.reduce(.idle, .start(machineID: machine, preferredPeripheral: nil)).0
        XCTAssertNil(tapped.startedAt, "connecting is not shower time")
        var s = ShowerReducer.reduce(tapped, .connected(peripheralID: "P", probe: FakeFrames.identity(machine))).0
        XCTAssertNil(s.startedAt)
        let water = t0.addingTimeInterval(15)
        s = ShowerReducer.reduce(s, .authorized(auth, at: water)).0
        XCTAssertEqual(s.phase, .writePending)
        XCTAssertEqual(s.startedAt, water)
        s = ShowerReducer.reduce(s, .writeReplied(Data([0x00]))).0
        XCTAssertEqual(s.phase, .writePending)
        XCTAssertEqual(s.startedAt, water)
        XCTAssertEqual(ShowerPage(s)?.startedAt, water)
        XCTAssertEqual(ShowerActivityAction(s, now: t0.addingTimeInterval(20)), .show(startedAt: water, writeUnconfirmed: true))
    }

    /// Duration (「上次 11 分钟」, the settled lock screen, the done page) counts from the water too.
    func testTheDurationCountsFromTheWater() {
        let water = t0.addingTimeInterval(15)
        let done = ShowerState(phase: .done, startedAt: water, receipt: ShowerReceipt(amount: Money(fen: 132)),
                               endedAt: water.addingTimeInterval(10 * 60 + 40))
        XCTAssertEqual(done.minutes, 11)
        XCTAssertEqual(ShowerPage(done)?.minutes, 11)
        XCTAssertEqual(ShowerActivityAction(done, now: water), .settled(startedAt: water, minutes: 11, amountYuan: 1.32, dismissAfter: 4))
        XCTAssertNil(ShowerState(phase: .done, endedAt: water).minutes, "no water start, no duration")
    }

    /// A failure before the water never carries a timer origin.
    func testAFailureBeforeTheWaterHasNoTimer() {
        var s = ShowerReducer.reduce(.idle, .start(machineID: machine, preferredPeripheral: nil)).0
        s = ShowerReducer.reduce(s, .connected(peripheralID: "P", probe: FakeFrames.identity(machine))).0
        s = ShowerReducer.reduce(s, .authorizeFailed(.timedOut)).0
        XCTAssertEqual(s.failure?.reason, .authorizeUncertain)
        XCTAssertNil(s.startedAt)
        XCTAssertEqual(ShowerActivityAction(s, now: t0), .end)
    }
}
