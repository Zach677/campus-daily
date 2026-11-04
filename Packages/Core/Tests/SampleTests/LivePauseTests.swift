import XCTest
import Core

/// Counts what reaches the live stores, network and notifications.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var log: [String] = []
    func hit(_ what: String) { lock.withLock { counts[what, default: 0] += 1; log.append(what) } }
    subscript(_ what: String) -> Int { lock.withLock { counts[what] ?? 0 } }
    var order: [String] { lock.withLock { log } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

private final class CountingStore: SecureStore, @unchecked Sendable {
    let counter: Counter
    let inner = InMemorySecureStore()
    init(_ counter: Counter) { self.counter = counter }
    func read(_ key: StoreKey) throws -> Data? { try inner.read(key) }
    func write(_ data: Data, for key: StoreKey) throws { counter.hit("store write"); try inner.write(data, for: key) }
    func delete(_ key: StoreKey) throws { counter.hit("store delete"); try inner.delete(key) }
}

private struct CountingHTTP: HTTPClient {
    let counter: Counter
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { counter.hit("network"); return HTTPResponse(status: 200) }
}

/// Answers once `release` is called: a live read that is under way when the sample opens.
private final class SlowHTTP: HTTPClient, @unchecked Sendable {
    let counter: Counter
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    init(counter: Counter) { self.counter = counter }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        counter.hit("network")
        await withCheckedContinuation { (go: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if released { return true }
                waiting = go; return false
            }
            if now { go.resume() }
        }
        return HTTPResponse(status: 200, body: Data("answer".utf8))
    }
    var started: Bool { counter["network"] > 0 }
    func release() {
        let go = lock.withLock { () -> CheckedContinuation<Void, Never>? in released = true; defer { waiting = nil }; return waiting }
        go?.resume()
    }
}

private let request = HTTPRequest(service: .ecykt, method: .get, url: URL(string: "https://example.invalid/balance")!)

/// While 「先看看示例」 is shown the live app's background work waits: its requests, its storage
/// writes, its refreshes and its reminders. Leaving the sample runs them (none dropped). The
/// end of a real shower from the Live Activity or Siri leaves the sample first.
@MainActor
final class LivePauseTests: XCTestCase {

    /// The Live Activity's button or Siri's 结束并结算 while the sample is shown: the sample is
    /// left (and the live work resumed, a write made during it already stored) before the live
    /// session is ended, once; afterwards the live app stays up, not the login step or the sample.
    func testEndingTheRealShowerFromTheSampleLeavesItFirst() async throws {
        let counter = Counter()
        let pause = LivePause()
        let store = PausableSecureStore(CountingStore(counter), pause: pause)
        let sample = SampleMode(livePause: pause)
        sample.enter()
        try store.write(Data("running".utf8), for: .showerSession)
        var ends = 0
        try await LiveShowerFinish.run(sample: sample) {
            ends += 1
            XCTAssertFalse(sample.isActive, "the sample is still shown when the live session ends")
            XCTAssertFalse(pause.isPaused)
            XCTAssertEqual(counter["store write"], 1, "the live write waited past the end")
        }
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(sample.isActive)
        XCTAssertFalse(sample.takeLogin(), "after the end the live app stays up, not the login step")
        XCTAssertNil(sample.takePendingLink())
    }

    /// Outside the sample the end just runs.
    func testEndingOutsideTheSampleJustEnds() async throws {
        let sample = SampleMode(livePause: LivePause())
        var ends = 0
        try await LiveShowerFinish.run(sample: sample) { ends += 1 }
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(sample.isActive)
    }

    /// The live Keychain: written to only after the sample, but read back at once in the meantime.
    func testLiveStorageWritesWaitForTheSample() throws {
        let counter = Counter()
        let pause = LivePause()
        let inner = CountingStore(counter)
        let store = PausableSecureStore(inner, pause: pause)
        let sample = SampleMode(livePause: pause)
        sample.enter()
        try store.write(Data("a".utf8), for: .showerSession)
        try store.write(Data("b".utf8), for: .showerSession)
        try store.delete(.schoolProfile)
        XCTAssertEqual(counter.total, 0)
        XCTAssertEqual(try store.read(.showerSession), Data("b".utf8))
        XCTAssertNil(try inner.inner.read(.showerSession))
        sample.leave()
        XCTAssertEqual(try inner.inner.read(.showerSession), Data("b".utf8))
        XCTAssertEqual(counter["store write"], 1)
        XCTAssertEqual(counter["store delete"], 1)
        // Outside the sample: straight through.
        try store.write(Data("c".utf8), for: .showerSession)
        XCTAssertEqual(counter["store write"], 2)
    }

    /// The live preferences (`@AppStorage`, the models' flags): the same.
    func testLivePreferencesWaitForTheSample() throws {
        let suite = "livepause.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let pause = LivePause()
        let defaults = try XCTUnwrap(PausableDefaults(suiteName: suite, pause: pause))
        let disk = try XCTUnwrap(UserDefaults(suiteName: suite))
        disk.set("old", forKey: "gone")
        let sample = SampleMode(livePause: pause)
        sample.enter()
        defaults.set(true, forKey: "flag")
        defaults.set("x", forKey: "text")
        defaults.removeObject(forKey: "gone")
        XCTAssertTrue(defaults.bool(forKey: "flag"))
        XCTAssertEqual(defaults.string(forKey: "text"), "x")
        XCTAssertNil(defaults.object(forKey: "gone"))
        XCTAssertNil(disk.object(forKey: "flag"))
        XCTAssertEqual(disk.string(forKey: "gone"), "old")
        sample.leave()
        XCTAssertTrue(disk.bool(forKey: "flag"))
        XCTAssertEqual(disk.string(forKey: "text"), "x")
        XCTAssertNil(disk.object(forKey: "gone"))
    }

    /// The live network: a request made while the sample is shown is sent after it, not dropped.
    func testLiveRequestsWaitForTheSample() async throws {
        let counter = Counter()
        let pause = LivePause()
        let http = PausableHTTPClient(CountingHTTP(counter: counter), pause: pause)
        let sample = SampleMode(livePause: pause)
        sample.enter()
        let sent = Task { try await http.send(request).status }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter["network"], 0)
        sample.leave()
        let status = try await sent.value
        XCTAssertEqual(status, 200)
        XCTAssertEqual(counter["network"], 1)
    }

    /// The background refresh, the refresh on coming to the front and reminder scheduling, asked
    /// for while the sample is shown: nothing reaches the network, the stores or the notification
    /// center; each runs once after the sample (asked twice, the latest), in the order asked.
    /// Left by a login link too.
    func testBackgroundWorkInTheSampleRunsAfterIt() async throws {
        let counter = Counter()
        let pause = LivePause()
        let http = PausableHTTPClient(CountingHTTP(counter: counter), pause: pause)
        let store = PausableSecureStore(CountingStore(counter), pause: pause)
        let sample = SampleMode(livePause: pause)
        sample.enter()
        let refresh: @Sendable () async -> Void = {
            _ = try? await http.send(request)
            try? store.write(Data("snapshot".utf8), for: .sharedSnapshot)
            counter.hit("refresh")
        }
        XCTAssertTrue(pause.deferWhilePaused("background refresh", refresh))
        XCTAssertTrue(pause.deferWhilePaused("foreground refresh") { counter.hit("foreground") })
        XCTAssertTrue(pause.deferWhilePaused("shower reminder") { counter.hit("notification: first") })
        XCTAssertTrue(pause.deferWhilePaused("shower reminder") { counter.hit("notification") })
        XCTAssertTrue(pause.deferWhilePaused("background refresh", refresh))
        await Task.yield()
        XCTAssertEqual(counter.total, 0)
        XCTAssertEqual(sample.open(try XCTUnwrap(URL(string: "campusdaily://login"))), .leftSample)
        await pause.drained()
        XCTAssertEqual(counter["refresh"], 1)
        XCTAssertEqual(counter["network"], 1)
        XCTAssertEqual(counter["store write"], 1)
        XCTAssertEqual(counter["foreground"], 1)
        XCTAssertEqual(counter["notification"], 1)
        XCTAssertEqual(counter["notification: first"], 0)
        XCTAssertEqual(counter.order.filter { !$0.hasPrefix("store") && $0 != "network" }, ["refresh", "foreground", "notification"])
        // Outside the sample nothing waits: the caller runs the work itself.
        XCTAssertFalse(pause.deferWhilePaused("background refresh", refresh))
    }

    /// A live refresh already under way when the sample opens, answered while it is shown:
    /// what it does with the answer (store it, redraw the widget, judge the reminders) waits
    /// for the sample to be left, then happens once, with that answer. Not only new starts wait.
    func testLiveWorkStartedBeforeTheSampleAppliesAfterIt() async throws {
        let counter = Counter()
        let pause = LivePause()
        let slow = SlowHTTP(counter: counter)
        let http = PausableHTTPClient(slow, pause: pause)
        let inner = CountingStore(counter)
        let store = PausableSecureStore(inner, pause: pause)
        let suite = "livepause.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(PausableDefaults(suiteName: suite, pause: pause))
        let disk = try XCTUnwrap(UserDefaults(suiteName: suite))
        let sample = SampleMode(livePause: pause)
        // The refresh as the live models run it: read, store, then the widget and the reminders.
        let refresh = Task { @MainActor in
            let answer = try await http.send(request)
            try store.write(answer.body, for: .sharedSnapshot)
            defaults.set(Date(), forKey: "lastRead")
            if !pause.deferWhilePaused("widget", { counter.hit("widget") }) { counter.hit("widget") }
            if !pause.deferWhilePaused("campus reminder", { counter.hit("notification") }) { counter.hit("notification") }
        }
        while !slow.started { await Task.yield() }
        sample.enter()
        slow.release()
        // The answer is in; what follows it waits for the sample to be left.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter["store write"], 0, "the answer was stored during the sample")
        XCTAssertNil(disk.object(forKey: "lastRead"))
        XCTAssertEqual(counter["widget"], 0)
        XCTAssertEqual(counter["notification"], 0, "a reminder was posted during the sample")
        sample.leave()
        try await refresh.value
        await pause.drained()
        // The live models read their own write back.
        XCTAssertEqual(try store.read(.sharedSnapshot), Data("answer".utf8))
        XCTAssertEqual(try inner.inner.read(.sharedSnapshot), Data("answer".utf8))
        XCTAssertNotNil(disk.object(forKey: "lastRead"))
        XCTAssertEqual(counter["store write"], 1)
        XCTAssertEqual(counter["widget"], 1)
        XCTAssertEqual(counter["notification"], 1)
    }

    /// A new sample pauses again; a sample left and entered again keeps nothing of the last one.
    func testEachSamplePausesUntilItIsLeft() throws {
        let pause = LivePause()
        let sample = SampleMode(livePause: pause)
        XCTAssertFalse(pause.isPaused)
        sample.enter()
        XCTAssertTrue(pause.isPaused)
        sample.leave()
        XCTAssertFalse(pause.isPaused)
        sample.enter()
        XCTAssertTrue(pause.isPaused)
        sample.leaveForLive()
        XCTAssertFalse(pause.isPaused)
    }
}
