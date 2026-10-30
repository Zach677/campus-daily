import Foundation

/// The cross-process lock around a school refresh. The app and the widget are two processes
/// sharing one stored card session; only the holder of this lease refreshes (and so mints or
/// rotates the session). The lease is one shared Keychain item `{owner, expiresAt}`, taken with
/// an atomic create. A holder that dies leaves it to expire after `duration`; the next process
/// removes a stale lease and creates its own.
public struct RefreshLease: Sendable {
    struct Record: Codable, Equatable {
        var owner: String
        var expiresAt: Date
    }

    let store: SecureStore
    /// Random per refresher (process): `app-<uuid>` / `widget-<uuid>`. Nothing personal.
    public let owner: String
    let now: @Sendable () -> Date
    public let duration: TimeInterval

    /// Longer than the slowest refresh chain: liveness, portal exchange, one password login and
    /// the exchange after it, each up to 20 s on a slow network, plus the reads (60–180 s).
    public static let defaultDuration: TimeInterval = 180
    /// The holder pushes the expiry forward this often while its read runs.
    public static let renewInterval: TimeInterval = 20

    public init(store: SecureStore, owner: String, duration: TimeInterval = RefreshLease.defaultDuration,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.owner = owner; self.duration = duration; self.now = now
    }

    /// A new owner id for one process: the role plus a random UUID.
    public static func owner(_ role: String) -> String { role + "-" + UUID().uuidString }

    /// Takes the lease when nobody holds it, or when the holder's lease has run out. False while
    /// another owner holds a live lease, or when the Keychain can't be read or written (a locked
    /// phone before the first unlock): no lease, no refresh.
    public func acquire() -> Bool {
        let mine = Record(owner: owner, expiresAt: now().addingTimeInterval(duration))
        if (try? create(mine)) == true { return true }
        let current: Record?
        do { current = try read() } catch { return false }
        guard let holder = current else { return (try? create(mine)) == true }
        if holder.owner == owner { return renew() }
        guard isStale(holder) else { return false }
        // Remove only the stale lease seen above; another process may have just replaced it.
        guard (try? read()) == holder else { return false }
        try? store.delete(.sharedRefreshLease)
        return (try? create(mine)) == true
    }

    /// Still ours and not run out: push the expiry forward. False = lost (it ran out and another
    /// process took it, or a sign-out removed it): stop before minting, logging in or writing a
    /// credential.
    public func renew() -> Bool {
        guard let holder = try? read(), holder.owner == owner, holder.expiresAt > now() else { return false }
        let data = (try? JSONEncoder().encode(Record(owner: owner, expiresAt: now().addingTimeInterval(duration)))) ?? Data()
        return (try? store.write(data, for: .sharedRefreshLease)) != nil
    }

    /// Still ours (not taken over, not removed by a sign-out in the other process).
    public func holds() -> Bool { (try? read())?.owner == owner }

    /// Sign-out and reset: the lease goes, whoever holds it.
    public func clear() throws { try store.delete(.sharedRefreshLease) }

    /// Gives the lease back if it is still ours.
    public func release() {
        guard let holder = try? read(), holder.owner == owner else { return }
        try? store.delete(.sharedRefreshLease)
    }

    /// Run out, or set further ahead than any holder would (a clock moved back): either way
    /// nobody is using it.
    func isStale(_ record: Record) -> Bool {
        let t = now()
        return record.expiresAt <= t || record.expiresAt > t.addingTimeInterval(duration * 2)
    }

    /// The stored lease; an unreadable one counts as long expired, so it can't block refreshes forever.
    func read() throws -> Record? {
        guard let data = try store.read(.sharedRefreshLease) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data)) ?? Record(owner: "", expiresAt: .distantPast)
    }

    private func create(_ record: Record) throws -> Bool {
        let data = try JSONEncoder().encode(record)
        return try store.create(data, for: .sharedRefreshLease)
    }
}
