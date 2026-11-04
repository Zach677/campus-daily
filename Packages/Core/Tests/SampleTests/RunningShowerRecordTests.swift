import XCTest
import Core
import CoreTestSupport

/// The platform as the hot-water engine sees it: authorizes at once; a settlement waits until
/// `answer` is called (its request held by the sample, or the app killed before the reply).
private final class TestGateway: ShowerGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var _authorization: ShowerAuthorization
    /// What the next authorize returns (a new session: a new authorization id).
    var authorization: ShowerAuthorization {
        get { lock.withLock { _authorization } }
        set { lock.withLock { _authorization = newValue } }
    }
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var answered = false
    init(_ authorization: ShowerAuthorization) { _authorization = authorization }
    var isAvailable: Bool { true }
    func authorize(_ binding: ShowerBinding, frame: Data) async throws -> ShowerAuthorization { authorization }
    func settle(_ binding: ShowerBinding, frame: Data) async throws -> ShowerReceipt {
        await withCheckedContinuation { (go: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if answered { return true }
                waiting.append(go); return false
            }
            if now { go.resume() }
        }
        return ShowerReceipt(amount: Money(fen: 163))
    }
    func answer() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in answered = true; defer { waiting = [] }; return waiting }
        for go in all { go.resume() }
    }
}

/// The running real shower's own record (`water.session`) while 「先看看示例」 is shown: the one
/// session whose water may be flowing when the sample opens writes its record straight to the
/// Keychain, so a kill during the sample can't lose it; everything else stays held. Only the
/// live store does this; the sample has no handle to it.
@MainActor
final class RunningShowerRecordTests: XCTestCase {
    let binding = ShowerBinding(studentId: "S1234567", schoolId: "20021", machineId: "11223344", roomId: "R1", roomLabel: "99栋 991")
    let authorization = ShowerAuthorization(machineID: "11223344", payload: Data((0..<15).map { UInt8(0x30 + $0) }), authorizationID: "001122FF")
    var identity: Data { FakeFrames.identity("11223344") }
    var consumption: Data { FakeFrames.identity("11223344", tail: 9) }

    /// One run of the app over `disk` (the Keychain, which outlives the process): its pause,
    /// its live store, its hot-water engine.
    private struct Process {
        let pause: LivePause
        let store: PausableSecureStore
        let transport: FakeShowerTransport
        let engine: ShowerEngine
        var vault: StoredShowerVault { StoredShowerVault(store: store) }
    }

    private func launch(over disk: InMemorySecureStore, gateway: TestGateway) throws -> Process {
        let pause = LivePause()
        let store = PausableSecureStore(disk, pause: pause)
        let transport = FakeShowerTransport()
        let engine = try ShowerEngine(transport: transport, gateway: gateway, vault: StoredShowerVault(store: store),
                                      configuration: .init(bleName: "fixture-ble"))
        return Process(pause: pause, store: store, transport: transport, engine: engine)
    }

    private func startRunning(_ p: Process) async throws {
        p.transport.script(.frame(identity), .frame(FakeFrames.ack))
        let state = try await p.engine.start(binding)
        XCTAssertEqual(state.phase, .running)
    }

    private func onDisk(_ disk: InMemorySecureStore) throws -> ShowerState? { try StoredShowerVault(store: disk).showerState() }

    /// The shower is running when the sample opens; 结束 runs while it is shown (the close goes
    /// over Bluetooth, the settlement is held). The app is killed before the sample is left:
    /// after the relaunch the record of that session is there, with the frame to settle, and is
    /// reviewed as an unconfirmed settlement, not lost and not shown as still running. What else
    /// the live app wrote during the sample (held) is gone, as before.
    func testTheRunningShowersRecordSurvivesAKillDuringTheSample() async throws {
        let disk = InMemorySecureStore()
        let gateway = TestGateway(authorization)
        let first = try launch(over: disk, gateway: gateway)
        try await startRunning(first)
        let sample = SampleMode(livePause: first.pause)
        sample.enter()
        try first.store.write(Data("held".utf8), for: .laundryCheckout)
        first.transport.script(.frame(FakeFrames.active), .frame(consumption))
        let engine = first.engine, binding = binding
        Task { _ = try? await engine.finish(binding) }
        for _ in 0..<500 where try onDisk(disk)?.phase != .settling { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try onDisk(disk)?.phase, .settling, "the session's record was held")
        XCTAssertEqual(try onDisk(disk)?.consumption, HexCoding.upper(consumption))

        // Killed: nothing in memory survives, the sample is never left. A new process over the
        // same Keychain.
        let second = try launch(over: disk, gateway: TestGateway(authorization))
        let restored = await second.engine.state
        XCTAssertEqual(restored.phase, .failed)
        XCTAssertEqual(restored.failure?.reason, .settleUnconfirmed)
        XCTAssertEqual(restored.failure?.needsReview, true)
        XCTAssertEqual(restored.consumption, HexCoding.upper(consumption))
        XCTAssertEqual(restored.authorizationID, authorization.authorizationID)
        XCTAssertNil(try disk.read(.laundryCheckout), "a held write outside the session's record reached the Keychain")
        gateway.answer()
    }

    /// Only the session already under way when the sample opened. With no shower running then,
    /// a session started during the sample (Siri, Shortcuts) is held like any other live write:
    /// nothing reaches the Keychain until the sample is left.
    func testASessionStartedDuringTheSampleIsHeld() async throws {
        let disk = InMemorySecureStore()
        let gateway = TestGateway(authorization)
        let p = try launch(over: disk, gateway: gateway)
        let sample = SampleMode(livePause: p.pause)
        sample.enter()
        try await startRunning(p)
        XCTAssertNil(try onDisk(disk), "a session that started during the sample was written through")
        XCTAssertEqual(try p.vault.showerState()?.phase, .running, "the live app reads its own record back")
        sample.leave()
        XCTAssertEqual(try onDisk(disk)?.phase, .running)
        gateway.answer()
    }

    /// The running session ends during the sample: its end is written through, once, and from
    /// then on its exemption is over. A new session started afterwards in the same sample (a
    /// new authorization id) is held, and so is a record of another session written while the
    /// first still ran.
    func testTheExemptionEndsWithThatSession() async throws {
        let disk = InMemorySecureStore()
        let gateway = TestGateway(authorization)
        gateway.answer()
        let p = try launch(over: disk, gateway: gateway)
        try await startRunning(p)
        let sample = SampleMode(livePause: p.pause)
        sample.enter()

        // Another session's record while this one runs: not this session's, held.
        var other = try XCTUnwrap(try onDisk(disk))
        other.authorizationID = "99999999"
        try p.vault.saveShowerState(other)
        XCTAssertEqual(try onDisk(disk)?.authorizationID, authorization.authorizationID)

        p.transport.script(.frame(FakeFrames.active), .frame(consumption))
        let done = try await p.engine.finish(binding)
        XCTAssertEqual(done.phase, .done)
        XCTAssertEqual(try onDisk(disk), done.persistable, "the session's end was held")
        let idle = try await p.engine.dismiss()
        XCTAssertEqual(try onDisk(disk)?.phase, .done, "after its end the record is held again")
        XCTAssertEqual(try p.vault.showerState(), idle.persistable)

        // A new session in the same sample (a new authorization id): held.
        gateway.authorization = ShowerAuthorization(machineID: "11223344", payload: authorization.payload, authorizationID: "00AABBCC")
        try await startRunning(p)
        XCTAssertEqual(try onDisk(disk)?.phase, .done, "a new session was written through")
        sample.leave()
        XCTAssertEqual(try onDisk(disk)?.phase, .running)
        XCTAssertEqual(try onDisk(disk)?.authorizationID, "00AABBCC")
    }

    /// The record written through is the live engine's, byte for byte; the sample's own shower
    /// (its services, its in-memory Keychain) writes nowhere near it: the sample has no handle
    /// to the live store or to the exemption.
    func testOnlyTheLiveSessionWritesTheRecord() async throws {
        let disk = InMemorySecureStore()
        let gateway = TestGateway(authorization)
        let p = try launch(over: disk, gateway: gateway)
        try await startRunning(p)
        let live = try XCTUnwrap(try disk.read(.showerSession))
        let sample = SampleMode(livePause: p.pause)
        sample.enter()

        let sampleServices = CampusServices.sample()
        XCTAssertFalse(sampleServices.secureStore is PausableSecureStore)
        XCTAssertNil(sampleServices.livePause)
        var sampleRecord = ShowerState(phase: .running, machineID: "11223344", peripheralID: "PERIPHERAL-A",
                                       startedAt: Date(timeIntervalSince1970: 1), authorizeSent: true,
                                       authorizationID: authorization.authorizationID)
        sampleRecord.consumption = "SAMPLE"
        try sampleServices.showerVault.saveShowerState(sampleRecord)
        XCTAssertEqual(try disk.read(.showerSession), live, "the sample reached the live record")

        p.transport.script(.frame(FakeFrames.active), .frame(consumption))
        let engine = p.engine, binding = binding
        Task { _ = try? await engine.finish(binding) }
        for _ in 0..<500 where try onDisk(disk)?.phase != .settling { try await Task.sleep(for: .milliseconds(10)) }
        let engineState = await p.engine.state
        XCTAssertEqual(try onDisk(disk), engineState.persistable)
        XCTAssertEqual(try onDisk(disk)?.consumption, HexCoding.upper(consumption))
        XCTAssertEqual(try sampleServices.showerVault.showerState()?.consumption, "SAMPLE")
        gateway.answer()
        sample.leave()
    }
}
