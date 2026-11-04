import XCTest
import Core

/// Answers once `release` is called: a live read that is under way when the sample opens.
private final class HeldAnswer: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private var sent = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await withCheckedContinuation { (go: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                sent += 1
                if released { return true }
                waiting = go; return false
            }
            if now { go.resume() }
        }
        return HTTPResponse(status: 200, body: Data("answer".utf8))
    }
    var started: Bool { lock.withLock { sent > 0 } }
    func release() {
        let go = lock.withLock { () -> CheckedContinuation<Void, Never>? in released = true; defer { waiting = nil }; return waiting }
        go?.resume()
    }
}

/// The live school read as the session runs it, over the live network and Keychain: the read,
/// the check before minting (it renews the lease), a credential written back under the lease,
/// then the reading.
private struct LiveSchoolRead: SchoolReader {
    let http: any HTTPClient
    let store: any SecureStore
    func refresh(inBackground: Bool, mayMint: @Sendable () async -> Bool, owning: LeaseOwnership,
                 numbers: @Sendable (SchoolReading) async -> Void) async -> SchoolReading {
        let request = HTTPRequest(service: .ecykt, method: .get, url: URL(string: "https://example.invalid/balance")!)
        guard let answer = try? await http.send(request) else { return SchoolReading(outcome: .failed(.offline), checkedAt: Date()) }
        guard await mayMint() else { return SchoolReading(outcome: .leaseLost, checkedAt: Date()) }
        _ = try? owning.write { try store.write(answer.body, for: .schoolPortal) }
        return SchoolReading(outcome: .ok, checkedAt: Date(), balance: .success(Money(fen: 790)))
    }
}

/// The live app's files while 「先看看示例」 is shown: the refresh lease file and the imported
/// hot-water profile are written after the sample, like the Keychain and the preferences, also
/// by a read that was under way before it opened. (The app writes no laundry file: the
/// `LaundryCache` folder 重置 removes is an older build's.)
@MainActor
final class LiveFilePauseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("livefile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func contents(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

    /// A live refresh under way when the sample opens (it holds the lease, its heartbeat
    /// renewing it), answered while the sample is shown: the lease file is not touched until the
    /// sample is left (no renewal, no write-back under the lease, no release), nor is the
    /// Keychain; then the read finishes with that answer, stores it, and gives the lease back.
    func testALiveRefreshUnderWayLeavesTheLeaseFileAloneDuringTheSample() async throws {
        let pause = LivePause()
        let answer = HeldAnswer()
        let http = PausableHTTPClient(answer, pause: pause)
        let disk = InMemorySecureStore()
        let store = PausableSecureStore(disk, pause: pause)
        let url = folder.appendingPathComponent("refresh.lease")
        let lease = RefreshLease(file: LeaseFile(url: url), owner: RefreshLease.owner("app"))
        let refresher = SnapshotRefresher(school: LiveSchoolRead(http: http, store: store),
                                          store: SharedSnapshotStore(store: store), lease: lease,
                                          renewInterval: 0.02, pause: pause, diagnostic: { _ in })
        let sample = SampleMode(livePause: pause)
        let run = Task { await refresher.refresh(inBackground: true) }
        while !answer.started { await Task.yield() }
        XCTAssertFalse(contents(url).isEmpty, "the read holds the lease")
        sample.enter()
        // A renewal that passed its check just before the sample opened has finished by now.
        try await Task.sleep(for: .milliseconds(50))
        let held = contents(url)
        answer.release()
        // Several heartbeats, and the answer, while the sample is shown.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(contents(url), held, "the lease file was written during the sample")
        XCTAssertNil(try disk.read(.schoolPortal))
        XCTAssertNil(try disk.read(.sharedSnapshot))
        sample.leave()
        let report = await run.value
        XCTAssertEqual(report.outcome, .ok)
        XCTAssertTrue(report.snapshotSaved)
        XCTAssertEqual(try disk.read(.schoolPortal), Data("answer".utf8))
        XCTAssertNotNil(try disk.read(.sharedSnapshot))
        XCTAssertTrue(contents(url).isEmpty, "the lease is given back after the sample")
    }

    /// A live refresh waiting for the widget's lease when the sample opens: the widget giving it
    /// back during the sample does not let the app take it (no lease file write) until the
    /// sample is left.
    func testALiveRefreshWaitingForTheLeaseTakesItOnlyAfterTheSample() async throws {
        let pause = LivePause()
        let disk = InMemorySecureStore()
        let store = PausableSecureStore(disk, pause: pause)
        let answer = HeldAnswer()
        let http = PausableHTTPClient(answer, pause: pause)
        let url = folder.appendingPathComponent("refresh.lease")
        let widget = RefreshLease(file: LeaseFile(url: url), owner: RefreshLease.owner("widget"))
        XCTAssertTrue(widget.acquire())
        let refresher = SnapshotRefresher(school: LiveSchoolRead(http: http, store: store),
                                          store: SharedSnapshotStore(store: store),
                                          lease: RefreshLease(file: LeaseFile(url: url), owner: RefreshLease.owner("app")),
                                          leaseWait: 60, sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) },
                                          pause: pause, diagnostic: { _ in })
        let sample = SampleMode(livePause: pause)
        let run = Task { await refresher.refresh(inBackground: true) }
        try await Task.sleep(for: .milliseconds(50))
        sample.enter()
        try await Task.sleep(for: .milliseconds(30))
        widget.release()
        XCTAssertTrue(contents(url).isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(contents(url).isEmpty, "the app took the lease during the sample")
        sample.leave()
        for _ in 0..<200 where contents(url).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(contents(url).isEmpty, "the app takes the lease after the sample")
        answer.release()
        _ = await run.value
    }

    /// The imported hot-water profile (Settings › 高级), written while the sample is shown:
    /// nothing reaches the folder until it is left, then the last one is written (with its
    /// folder prepared first). Outside the sample it is written at once.
    func testTheLiveProfileFileIsWrittenAfterTheSample() throws {
        let pause = LivePause()
        let sample = SampleMode(livePause: pause)
        let water = folder.appendingPathComponent("Water", isDirectory: true)
        let target = water.appendingPathComponent("imported.waterconfig")
        let prepare: @Sendable () throws -> Void = { try FileManager.default.createDirectory(at: water, withIntermediateDirectories: true) }
        sample.enter()
        XCTAssertTrue(try pause.writeFile(Data("first".utf8), to: target, options: .atomic, prepare: prepare))
        XCTAssertTrue(try pause.writeFile(Data("second".utf8), to: target, options: .atomic, prepare: prepare))
        XCTAssertFalse(FileManager.default.fileExists(atPath: water.path), "the folder was made during the sample")
        sample.leave()
        XCTAssertEqual(contents(target), Data("second".utf8))
        XCTAssertFalse(try pause.writeFile(Data("third".utf8), to: target, options: .atomic, prepare: prepare))
        XCTAssertEqual(contents(target), Data("third".utf8))
    }
}
