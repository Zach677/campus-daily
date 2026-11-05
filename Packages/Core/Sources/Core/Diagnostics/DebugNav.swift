import Foundation

/// `nav.open` lines. A way in that is not a tap on a page (a widget, a notification, Siri, a
/// link) says so with `from` just before it routes; the page then says it opened. An entry
/// older than `pendingLifetime` is not used, and each one is used once.
public final class DebugNav: @unchecked Sendable {
    // @unchecked: `pending` is touched only under `lock`.
    public static let pendingLifetime: TimeInterval = 3
    private let log: any DebugLogSink
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var pending: (entry: DebugEntry, at: Date)?

    public init(log: any DebugLogSink, now: @escaping @Sendable () -> Date = Date.init) {
        self.log = log; self.now = now
    }

    public func from(_ entry: DebugEntry) {
        guard log.isEnabled else { return }
        let at = now()
        lock.withLock { pending = (entry, at) }
    }

    public func opened(_ page: DebugPage, default entry: DebugEntry) {
        guard log.isEnabled else { return }
        let at = now()
        let used: DebugEntry = lock.withLock {
            defer { pending = nil }
            guard let p = pending, at.timeIntervalSince(p.at) <= Self.pendingLifetime, at >= p.at else { return entry }
            return p.entry
        }
        log.record(.navOpen(page, from: used))
    }
}
