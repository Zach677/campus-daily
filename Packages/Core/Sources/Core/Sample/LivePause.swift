import Foundation

/// The live app's background work, held while 「先看看示例」 is shown (`SampleMode` pauses it on
/// entering and resumes it on leaving). Held at the point where work has an effect, not where it
/// starts, so a read already under way when the sample opens waits too:
/// - requests (`PausableHTTPClient`) are sent only after the sample;
/// - a request already sent hands its answer (or its failure) over only after the sample, so
///   nothing that follows a reply (a write-back under the refresh lease, a store) runs during it;
/// - writes to the Keychain (`PausableSecureStore`) and the preferences (`PausableDefaults`) are
///   kept in memory, read back from there, and written after the sample; so is a live file
///   (`writeFile`: the imported hot-water profile);
/// - the refresh lease file is not touched: the live refresh waits before taking, renewing or
///   giving back the lease (`SnapshotRefresher`'s `pause`);
/// - other work (the background refresh, the refresh on coming to the front, reminders, the
///   widget redraw) is handed to `deferWhilePaused` and runs after the sample, the latest per key.
/// Nothing is dropped. What draws the running shower's Live Activity is not held.
public final class LivePause: @unchecked Sendable {
    // Everything below is touched only under `lock`.
    private let lock = NSLock()
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var deferred: [(key: String, work: @Sendable () async -> Void)] = []
    private var flushes: [() -> Void] = []
    private var files: [(url: URL, write: () -> Void)] = []
    private var drain: Task<Void, Never>?

    public init() {}

    public var isPaused: Bool { lock.withLock { paused } }

    /// The sample opened: the live work waits from now on.
    public func pause() {
        lock.withLock { paused = true }
    }

    /// The sample was left: the held writes are stored (in the order made), the held requests
    /// sent, then the deferred work runs, in the order asked for (`drained` waits for it).
    public func resume() {
        let (flush, release, work) = lock.withLock { () -> ([() -> Void], [CheckedContinuation<Void, Never>], [@Sendable () async -> Void]) in
            guard paused else { return ([], [], []) }
            paused = false
            defer { waiters = []; deferred = []; files = [] }
            return (flushes + files.map(\.write), waiters, deferred.map(\.work))
        }
        for store in flush { store() }
        for waiter in release { waiter.resume() }
        guard !work.isEmpty else { return }
        let previous = lock.withLock { drain }
        let task = Task {
            await previous?.value
            for job in work { await job() }
        }
        lock.withLock { drain = task }
    }

    /// Until the work deferred so far has run.
    public func drained() async {
        await lock.withLock { drain }?.value
    }

    /// Returns at once outside the sample; inside, when it is left.
    public func waitWhilePaused() async {
        await withCheckedContinuation { (go: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                guard paused else { return true }
                waiters.append(go)
                return false
            }
            if now { go.resume() }
        }
    }

    /// While the sample is shown `work` is kept for after it (replacing what was kept under the
    /// same `key`, which runs in its place) and this returns true. Outside it returns false and
    /// the caller does the work itself, as before.
    @discardableResult
    public func deferWhilePaused(_ key: String, _ work: @escaping @Sendable () async -> Void) -> Bool {
        lock.withLock {
            guard paused else { return false }
            if let index = deferred.firstIndex(where: { $0.key == key }) {
                deferred[index].work = work
            } else {
                deferred.append((key, work))
            }
            return true
        }
    }

    /// A live file write (the imported hot-water profile): written now outside the sample;
    /// while it is shown, kept (the last per file) and written on leaving, with the held store
    /// writes. True when it was kept.
    @discardableResult
    public func writeFile(_ data: Data, to url: URL, options: Data.WritingOptions = [],
                          prepare: @escaping @Sendable () throws -> Void = {}) throws -> Bool {
        let held = lock.withLock { () -> Bool in
            guard paused else { return false }
            let write = { try? prepare(); try? data.write(to: url, options: options) }
            if let index = files.firstIndex(where: { $0.url == url }) { files[index].write = write }
            else { files.append((url, write)) }
            return true
        }
        if held { return true }
        try prepare()
        try data.write(to: url, options: options)
        return false
    }

    /// A held store's writes, stored on `resume` before anything else runs.
    fileprivate func onResume(_ flush: @escaping () -> Void) {
        lock.withLock { flushes.append(flush) }
    }
}

/// The live Keychain, held while the sample is shown (`LivePause`): writes and deletes are kept
/// in memory and read back from there; on leaving they are stored, the last per key.
public final class PausableSecureStore: SecureStore, @unchecked Sendable {
    private let inner: any SecureStore
    private let pause: LivePause
    // Touched only under `lock`. nil: deleted.
    private let lock = NSLock()
    private var held: [StoreKey: Data?] = [:]
    private var order: [StoreKey] = []

    public init(_ inner: any SecureStore, pause: LivePause) {
        self.inner = inner; self.pause = pause
        pause.onResume { [weak self] in self?.flush() }
    }

    public func read(_ key: StoreKey) throws -> Data? {
        if let value = lock.withLock({ held[key] }) { return value }
        return try inner.read(key)
    }

    public func write(_ data: Data, for key: StoreKey) throws {
        if hold(data, for: key) { return }
        try inner.write(data, for: key)
    }

    public func delete(_ key: StoreKey) throws {
        if hold(nil, for: key) { return }
        try inner.delete(key)
    }

    private func hold(_ value: Data?, for key: StoreKey) -> Bool {
        guard pause.isPaused else { return false }
        lock.withLock {
            if held[key] == nil { order.append(key) }
            held[key] = .some(value)
        }
        return true
    }

    private func flush() {
        let writes = lock.withLock { () -> [(StoreKey, Data?)] in
            defer { held = [:]; order = [] }
            return order.compactMap { key in held[key].map { (key, $0) } }
        }
        for (key, value) in writes {
            if let value { try? inner.write(value, for: key) } else { try? inner.delete(key) }
        }
    }
}

/// The live network, held while the sample is shown (`LivePause`): a request is sent once it
/// is left, and one already sent hands over its answer (or failure) once it is left, so what
/// the live app does with a reply never runs during the sample.
public struct PausableHTTPClient: HTTPClient {
    private let inner: any HTTPClient
    private let pause: LivePause
    public init(_ inner: any HTTPClient, pause: LivePause) { self.inner = inner; self.pause = pause }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await pause.waitWhilePaused()
        let answer: Result<HTTPResponse, Error>
        do { answer = .success(try await inner.send(request)) } catch { answer = .failure(error) }
        await pause.waitWhilePaused()
        return try answer.get()
    }
}

/// The live preferences, held while the sample is shown (`LivePause`): writes are kept in memory
/// and read back from there (`@AppStorage` sees them as usual); on leaving they are stored.
public final class PausableDefaults: UserDefaults {
    private enum Held { case value(Any), removed }
    private let pause: LivePause
    // Touched only under `lock`.
    private let lock = NSLock()
    private var held: [String: Held] = [:]
    private var order: [String] = []

    /// `suiteName` nil: the app's standard preferences.
    public init?(suiteName: String?, pause: LivePause) {
        self.pause = pause
        super.init(suiteName: suiteName)
        pause.onResume { [weak self] in self?.flush() }
    }

    public override func object(forKey key: String) -> Any? {
        switch lock.withLock({ held[key] }) {
        case .value(let value): return value
        case .removed: return nil
        case nil: return super.object(forKey: key)
        }
    }

    public override func set(_ value: Any?, forKey key: String) {
        guard pause.isPaused else { super.set(value, forKey: key); return }
        willChangeValue(forKey: key)
        lock.withLock {
            if held[key] == nil { order.append(key) }
            held[key] = value.map(Held.value) ?? .removed
        }
        didChangeValue(forKey: key)
    }

    public override func removeObject(forKey key: String) {
        guard pause.isPaused else { super.removeObject(forKey: key); return }
        set(nil, forKey: key)
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        var all = super.dictionaryRepresentation()
        for (key, value) in lock.withLock({ held }) {
            switch value {
            case .value(let v): all[key] = v
            case .removed: all[key] = nil
            }
        }
        return all
    }

    public override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ value: Float, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ url: URL?, forKey key: String) {
        guard pause.isPaused else { super.set(url, forKey: key); return }
        set(url.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) } as Any?, forKey: key)
    }

    public override func string(forKey key: String) -> String? {
        guard isHeld(key) else { return super.string(forKey: key) }
        return object(forKey: key) as? String
    }
    public override func array(forKey key: String) -> [Any]? {
        guard isHeld(key) else { return super.array(forKey: key) }
        return object(forKey: key) as? [Any]
    }
    public override func dictionary(forKey key: String) -> [String: Any]? {
        guard isHeld(key) else { return super.dictionary(forKey: key) }
        return object(forKey: key) as? [String: Any]
    }
    public override func data(forKey key: String) -> Data? {
        guard isHeld(key) else { return super.data(forKey: key) }
        return object(forKey: key) as? Data
    }
    public override func stringArray(forKey key: String) -> [String]? {
        guard isHeld(key) else { return super.stringArray(forKey: key) }
        return object(forKey: key) as? [String]
    }
    public override func url(forKey key: String) -> URL? {
        guard isHeld(key) else { return super.url(forKey: key) }
        guard let data = object(forKey: key) as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL?
    }
    public override func integer(forKey key: String) -> Int {
        guard isHeld(key) else { return super.integer(forKey: key) }
        return number(key)?.intValue ?? 0
    }
    public override func float(forKey key: String) -> Float {
        guard isHeld(key) else { return super.float(forKey: key) }
        return number(key)?.floatValue ?? 0
    }
    public override func double(forKey key: String) -> Double {
        guard isHeld(key) else { return super.double(forKey: key) }
        return number(key)?.doubleValue ?? 0
    }
    public override func bool(forKey key: String) -> Bool {
        guard isHeld(key) else { return super.bool(forKey: key) }
        if let text = object(forKey: key) as? String { return ["yes", "true", "1"].contains(text.lowercased()) }
        return number(key)?.boolValue ?? false
    }

    private func isHeld(_ key: String) -> Bool { lock.withLock { held[key] != nil } }

    private func number(_ key: String) -> NSNumber? {
        switch object(forKey: key) {
        case let n as NSNumber: return n
        case let s as String: return Double(s).map { NSNumber(value: $0) }
        default: return nil
        }
    }

    private func flush() {
        let writes = lock.withLock { () -> [(String, Held)] in
            defer { held = [:]; order = [] }
            return order.compactMap { key in held[key].map { (key, $0) } }
        }
        for (key, value) in writes {
            switch value {
            case .value(let v): super.set(v, forKey: key)
            case .removed: super.removeObject(forKey: key)
            }
        }
    }
}

/// The end of a real shower from outside the app's pages: the Live Activity's button and
/// Siri/Shortcuts' 结束并结算. While the sample is shown it is left first (the live work resumes,
/// the live app is shown again, not the login step), then the live session is ended; the app
/// stays on the live pages.
@MainActor public enum LiveShowerFinish {
    public static func run<T>(sample: SampleMode?, _ end: @MainActor () async throws -> T) async rethrows -> T {
        if let sample, sample.isActive { sample.leaveForLive() }
        return try await end()
    }
}
