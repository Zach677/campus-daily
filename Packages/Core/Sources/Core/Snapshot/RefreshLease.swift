import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The cross-process lock around a school refresh. The app and the widget are two processes
/// sharing one stored card session; only the holder of this lease refreshes (and so mints or
/// rotates the session). The lease is one small file `{owner, expiresAt}` in the App Group
/// container both processes can open. Every step (take, renew, check, give back, clear) is one
/// read-compare-write done while holding an exclusive `flock` on that file, so two processes can
/// never both find the same lease free, and a holder whose lease ran out can never write over
/// the next one's. The lock is held only for that step, never across an `await`: iOS ends a
/// suspended process that still holds a file lock in a shared container.
///
/// A holder that dies leaves its lease to expire after `duration`; the next process takes it.
/// Without the shared container (a build signed without the App Group) `file` is nil and the
/// lease can never be taken.
public struct RefreshLease: Sendable {
    struct Record: Codable, Equatable {
        var owner: String
        var expiresAt: Date
    }

    /// The App Group both targets are entitled to.
    public static let groupIdentifier = "group.com.beamjason.xiaorichang"

    /// The lease file in the shared container, or nil when this build has no App Group.
    public static func sharedFile() -> LeaseFile? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            .map { LeaseFile(url: $0.appendingPathComponent("refresh.lease")) }
    }

    let file: LeaseFile?
    /// Random per refresher (process): `app-<uuid>` / `widget-<uuid>`. Nothing personal.
    public let owner: String
    let now: @Sendable () -> Date
    public let duration: TimeInterval

    /// Longer than the slowest refresh chain: liveness, portal exchange, one password login and
    /// the exchange after it, each up to 20 s on a slow network, plus the reads (60–180 s).
    public static let defaultDuration: TimeInterval = 180
    /// The holder pushes the expiry forward this often while its read runs.
    public static let renewInterval: TimeInterval = 20

    public init(file: LeaseFile?, owner: String, duration: TimeInterval = RefreshLease.defaultDuration,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file; self.owner = owner; self.duration = duration; self.now = now
    }

    /// The same file under another owner (a login from the app's form beside its own refresh).
    func with(owner: String) -> RefreshLease { RefreshLease(file: file, owner: owner, duration: duration, now: now) }

    /// A new owner id for one process: the role plus a random UUID.
    public static func owner(_ role: String) -> String { role + "-" + UUID().uuidString }

    /// False when there is no shared file to lock: nobody can take the lease.
    public var isAvailable: Bool { file != nil }

    /// Takes the lease when nobody holds it, or when the holder's lease has run out (an
    /// owner whose own lease ran out takes it afresh like anyone else). False while another
    /// owner holds a live lease, or when the file can't be opened, read or written (a locked
    /// phone before the first unlock): no lease, no refresh.
    public func acquire() -> Bool {
        update { current in
            if let holder = current, holder.owner != owner, !isStale(holder) { return (current, false) }
            return (Record(owner: owner, expiresAt: now().addingTimeInterval(duration)), true)
        } ?? false
    }

    /// Still ours and not run out: push the expiry forward. False = lost (it ran out, another
    /// process took it, or a sign-out removed it): stop before minting, logging in or writing a
    /// credential. Nothing is written then.
    public func renew() -> Bool {
        update { current in
            guard let holder = current, holder.owner == owner, holder.expiresAt > now() else { return (current, false) }
            return (Record(owner: owner, expiresAt: now().addingTimeInterval(duration)), true)
        } ?? false
    }

    /// Still ours (not taken over, not removed by a sign-out in the other process).
    public func holds() -> Bool {
        update { current in (current, current?.owner == owner) } ?? false
    }

    /// Sign-out and reset: the lease goes, whoever holds it.
    public func clear() throws {
        guard let file else { return }
        _ = try file.update { _ in (nil, ()) }
    }

    /// Gives the lease back if it is still ours.
    public func release() {
        _ = update { current in current?.owner == owner ? (nil, ()) : (current, ()) }
    }

    /// Run out, or set further ahead than any holder would (a clock moved back): either way
    /// nobody is using it.
    func isStale(_ record: Record) -> Bool {
        let t = now()
        return record.expiresAt <= t || record.expiresAt > t.addingTimeInterval(duration * 2)
    }

    /// The stored lease (for tests and diagnostics).
    func read() throws -> Record? {
        guard let file else { return nil }
        return try file.update { current in (current, current) }
    }

    /// One locked read-compare-write; nil when the file can't be used.
    private func update<T>(_ body: (Record?) -> (Record?, T)) -> T? {
        guard let file else { return nil }
        return try? file.update(body)
    }
}

/// The lease's file: `update` reads the record, lets the caller decide, and writes the
/// decision back, all under one exclusive `flock`. An empty file is "no lease"; an unreadable
/// one counts as long expired, so it can't block refreshes forever.
public struct LeaseFile: Sendable {
    public let url: URL
    /// Runs inside the lock right after the record was read (tests use it to let the other
    /// "process" try at exactly that moment).
    let insideLock: (@Sendable () -> Void)?

    public init(url: URL) { self.init(url: url, insideLock: nil) }

    init(url: URL, insideLock: (@Sendable () -> Void)?) { self.url = url; self.insideLock = insideLock }

    struct Failure: Error { let step: String; let code: Int32 }

    /// The stored owner, run out or not (nil = no lease). For diagnostics and tests.
    public func storedOwner() -> String? { ((try? update { ($0, $0?.owner) }) ?? nil) }

    func update<T>(_ body: (RefreshLease.Record?) -> (RefreshLease.Record?, T)) throws -> T {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(step: "open", code: errno) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure(step: "lock", code: errno) }
        }
        defer { flock(fd, LOCK_UN) }
        let before = try readAll(fd)
        let current: RefreshLease.Record? = before.isEmpty ? nil
            : (try? JSONDecoder().decode(RefreshLease.Record.self, from: before)) ?? RefreshLease.Record(owner: "", expiresAt: .distantPast)
        insideLock?()
        let (next, result) = body(current)
        let after = try next.map { try JSONEncoder().encode($0) } ?? Data()
        if after != before { try writeAll(fd, after) }
        return result
    }

    private func readAll(_ fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw Failure(step: "seek", code: errno) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw Failure(step: "read", code: errno) }
            if n == 0 { return data }
            data.append(buffer, count: n)
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        guard ftruncate(fd, 0) == 0 else { throw Failure(step: "truncate", code: errno) }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offset)) }
            if n < 0 { if errno == EINTR { continue }; throw Failure(step: "write", code: errno) }
            offset += n
        }
    }
}
