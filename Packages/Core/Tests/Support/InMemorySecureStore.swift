import Foundation
import Core

/// In-memory store for tests, with injectable write and read failures.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoreKey: Data] = [:]
    private var failing: Set<StoreKey> = []
    private var unreadable = false
    private var afterWrite: [StoreKey: @Sendable () -> Void] = [:]
    private var beforeWrite: [StoreKey: @Sendable () -> Void] = [:]

    public init() {}

    /// Runs `step` once, right after the next write to `key` (as another process would act next).
    public func onNextWrite(to key: StoreKey, _ step: @escaping @Sendable () -> Void) {
        lock.withLock { afterWrite[key] = step }
    }

    /// Runs `step` once, right before the next write to `key`.
    public func beforeNextWrite(to key: StoreKey, _ step: @escaping @Sendable () -> Void) {
        lock.withLock { beforeWrite[key] = step }
    }

    /// Every read fails as the Keychain does before the first unlock (`errSecInteractionNotAllowed`).
    public func failReads(_ fail: Bool = true) { lock.withLock { unreadable = fail } }

    public func failWrites(to key: StoreKey, _ fail: Bool = true) {
        lock.withLock { if fail { failing.insert(key) } else { failing.remove(key) } }
    }

    public func read(_ key: StoreKey) throws -> Data? {
        try lock.withLock {
            if unreadable { throw StorageError(operation: "read \(key.rawValue)", status: -25308) }
            return items[key]
        }
    }

    public func write(_ data: Data, for key: StoreKey) throws {
        lock.withLock { beforeWrite.removeValue(forKey: key) }?()
        let step = try lock.withLock { () -> (@Sendable () -> Void)? in
            if failing.contains(key) { throw StorageError(operation: "write \(key.rawValue)", status: -1) }
            items[key] = data
            return afterWrite.removeValue(forKey: key)
        }
        step?()
    }

    public func delete(_ key: StoreKey) throws {
        try lock.withLock {
            if failing.contains(key) { throw StorageError(operation: "delete \(key.rawValue)", status: -1) }
            items[key] = nil
        }
    }
}
