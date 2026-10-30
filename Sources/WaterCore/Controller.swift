import Foundation

@MainActor public protocol WaterTransport: AnyObject {
    func connect(config: WaterConfig, expectedPeripheral: String?, preferredPeripheral: String?) async throws -> String
    func exchange(_ data: Data) async throws -> Data
    func disconnect()
}

extension WaterTransport {
    public func connect(config: WaterConfig, expectedPeripheral: String?) async throws -> String {
        try await connect(config:config,expectedPeripheral:expectedPeripheral,preferredPeripheral:nil)
    }
}

/// One pending transport step at a time. Each wait reserves a token; late timers and cancel handlers
/// pass their token and can only finish the wait they were created for, never the next step.
@MainActor public final class WaterWaitSlot {
    private var continuation: CheckedContinuation<Void, Error>?
    private var generation = 0
    public init() {}
    public var isWaiting: Bool { continuation != nil }
    /// Start a new wait generation; any older token becomes stale.
    public func reserve() -> Int { generation &+= 1; return generation }
    /// Attach the continuation for `token`. A stale token (superseded before attaching) is interrupted at once.
    public func attach(_ continuation: CheckedContinuation<Void, Error>, token: Int) {
        guard token == generation, self.continuation == nil else {
            continuation.resume(throwing: WaterError.interrupted); return
        }
        self.continuation = continuation
    }
    /// Whether a completion carrying `token` (nil = current step, from a device callback) may act.
    public func accepts(_ token: Int?) -> Bool { token == nil || token == generation }
    /// Finish the current wait if `token` still matches. Returns whether a continuation was resumed.
    @discardableResult public func complete(_ result: Result<Void, Error>, token: Int? = nil) -> Bool {
        guard accepts(token), let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}

public enum WaterTargetSelection {
    public static func select(_ candidates: [String], required: String?, preferred: String?) throws -> String {
        let ids = Set(candidates)
        if let required {
            guard ids.contains(required) else { throw WaterError.targetMissing }
            return required
        }
        if let preferred, ids.contains(preferred) { return preferred }
        guard !ids.isEmpty else { throw WaterError.targetMissing }
        guard ids.count == 1, let id = ids.first else { throw WaterError.targetAmbiguous }
        return id
    }
}
/// Probe with the read-only identity command before presenting same-name radios as targets.
/// RSSI orders probes only; it never establishes device ownership.
public enum WaterIdentitySelection {
    @MainActor public static func match(_ candidates: [String], machineID: String,
        probe: (String) async throws -> Data) async throws -> String {
        var seen = Set<String>()
        var sawOtherIdentity = false
        for id in candidates where seen.insert(id).inserted {
            try Task.checkCancellation()
            do {
                let frame = try await probe(id)
                let identity = try WaterProtocol.identity(frame)
                if identity == machineID.uppercased() { try Task.checkCancellation(); return id }
                sawOtherIdentity = true
            } catch is CancellationError { throw CancellationError() }
              catch WaterError.interrupted { throw WaterError.interrupted }
              catch { /* Busy, malformed and unreachable devices are not verified targets. */ }
        }
        try Task.checkCancellation()
        throw sawOtherIdentity ? WaterError.wrongDevice : WaterError.targetMissing
    }
}

@MainActor public protocol WaterProvider: AnyObject {
    func authorize(config: WaterConfig, frame: Data) async throws -> Authorization
    func settle(config: WaterConfig, frame: Data) async throws -> SettlementReceipt
}
/// Thrown by a provider only when the server definitely refused the request
/// (HTTP 200, well-formed JSON, non-zero result code). Anything less certain stays `WaterError.provider`
/// or `.networkUncertain`. The controller surfaces it as `WaterError.provider`.
public struct WaterProviderRefusal: Error, Equatable, Sendable { public init() {} }

@MainActor public protocol SessionStore: AnyObject {
    func load() throws -> WaterSession?
    func save(_ session: WaterSession) throws
    /// Remove the saved session. Used only to roll back a record for which nothing could have been charged.
    func clear() throws
}
extension SessionStore {
    /// Stores that cannot delete keep the record unresolved (fail safe).
    public func clear() throws { throw WaterError.storage }
}

@MainActor public final class WaterController {
    public private(set) var session: WaterSession?
    public private(set) var busy = false
    public private(set) var storageBlocked = false
    private let transport: WaterTransport
    private let provider: WaterProvider
    private let store: SessionStore
    public init(transport: WaterTransport, provider: WaterProvider, store: SessionStore) throws {
        self.transport = transport; self.provider = provider; self.store = store
        do { session = try store.load() } catch { throw WaterError.storage }
    }
    private func persist(_ value: WaterSession) throws {
        // Keep the more conservative in-memory state even if disk persistence fails.
        session = value
        do { try store.save(value) } catch { storageBlocked = true; throw WaterError.storage }
    }
    /// Restore the previous record (or none) when nothing could have been charged.
    /// If the store cannot do it, the unresolved record stays as is: memory keeps matching disk.
    private func rollBack(to previous: WaterSession?) {
        do {
            if let previous { try store.save(previous) } else { try store.clear() }
            session = previous
        } catch {}
    }
    /// Read the hardware identity without requesting authorization or creating a session.
    public func identify(config: WaterConfig) async throws -> String {
        try Task.checkCancellation()
        guard !busy else { throw WaterError.busy }
        guard !storageBlocked else { throw WaterError.storage }
        guard session == nil || session?.stage == .settled else { throw WaterError.unresolved }
        try config.validate()
        busy = true
        defer { transport.disconnect(); busy = false }
        let id = try await transport.connect(config:config,expectedPeripheral:nil,preferredPeripheral:nil)
        let frame = try await transport.exchange(Data([0xAA]))
        guard try WaterProtocol.identity(frame) == config.machineID.uppercased() else { throw WaterError.wrongDevice }
        try Task.checkCancellation()
        return id
    }
    public func start(config: WaterConfig, preferredPeripheral: String? = nil) async throws {
        try Task.checkCancellation()
        guard !busy else { throw WaterError.busy }
        guard !storageBlocked else { throw WaterError.storage }
        guard session == nil || session?.stage == .settled else { throw WaterError.unresolved }
        try config.validate()
        busy = true
        defer { transport.disconnect(); busy = false }
        let preferred = session?.machineID == config.machineID.uppercased() ? session?.peripheralID : nil
        let id = try await transport.connect(config: config, expectedPeripheral: nil, preferredPeripheral: preferredPeripheral ?? preferred)
        let frame = try await transport.exchange(Data([0xAA]))
        guard try WaterProtocol.identity(frame) == config.machineID.uppercased() else { throw WaterError.wrongDevice }
        try Task.checkCancellation()
        let previous = session
        var value = WaterSession(stage: .authorizationPending, machineID: config.machineID.uppercased(), peripheralID: id)
        try persist(value)
        // Nothing has been sent yet: a cancellation here leaves no record behind.
        do { try Task.checkCancellation() } catch { rollBack(to: previous); throw error }
        let auth: Authorization
        do { auth = try await provider.authorize(config: config, frame: frame) }
        catch is WaterProviderRefusal {
            // The server definitely refused: no authorization exists, nothing can be charged.
            rollBack(to: previous); throw WaterError.provider
        }
        // Timeouts, unreadable replies and malformed authorizations stay unresolved (may exist server-side).
        guard auth.machineID.uppercased() == value.machineID else { throw WaterError.wrongDevice }
        guard auth.payload.count == 15 else { throw WaterError.malformedFrame }
        _ = try WaterProtocol.closeCommand(auth.studentID)
        value.authorizationID = auth.studentID
        value.stage = .authorizationIssued
        try persist(value)
        try Task.checkCancellation()
        value.stage = .authorizationWritePending
        try persist(value)
        let ack = try await transport.exchange(auth.payload)
        guard ack.count == 9, ack.first == 0xAA else { throw WaterError.malformedFrame }
        value.stage = .active
        try persist(value)
    }
    public func finish(config: WaterConfig) async throws {
        try Task.checkCancellation()
        guard !busy else { throw WaterError.busy }
        guard !storageBlocked else { throw WaterError.storage }
        guard var value = session, value.stage.mayClose, let authID = value.authorizationID else {
            throw session == nil || session?.stage == .settled ? WaterError.noSession : WaterError.unresolved
        }
        try config.validate()
        guard value.machineID == config.machineID.uppercased() else { throw WaterError.wrongDevice }
        let command = try WaterProtocol.closeCommand(authID)
        busy = true
        defer { transport.disconnect(); busy = false }
        _ = try await transport.connect(config: config, expectedPeripheral: value.peripheralID)
        let first = try await transport.exchange(Data([0xAA]))
        guard first == Data([0xA5]) else {
            // The authorization write was never confirmed and the device now reports itself idle with our
            // identity: the authorization never took effect, so no water and no charge. An `.active` session
            // stays unresolved (the device may have ended on its own after use).
            if value.stage == .authorizationWritePending,
               (try? WaterProtocol.identity(first)) == value.machineID {
                rollBack(to: nil)
            }
            throw WaterError.notActive
        }
        try Task.checkCancellation()
        value.stage = .closeWritePending
        try persist(value)
        let consumption = try await transport.exchange(command)
        guard try WaterProtocol.identity(consumption) == value.machineID else { throw WaterError.wrongDevice }
        value.consumption = consumption
        value.stage = .settlementPending
        try persist(value)
        try Task.checkCancellation()
        do { value.receipt = try await provider.settle(config: config, frame: consumption) }
        catch is WaterProviderRefusal { throw WaterError.provider }
        value.stage = .settled
        value.endedAt = Date()
        try persist(value)
    }
    /// Deliberate user action after checking the official hot-water record: close an unresolved record
    /// without contacting the device or the server. Kept as `.settled` with `resolvedManually`, no receipt.
    public func resolveManually() throws {
        guard !busy else { throw WaterError.busy }
        guard !storageBlocked else { throw WaterError.storage }
        guard var value = session, value.stage != .settled else { throw WaterError.noSession }
        value.stage = .settled
        value.resolvedManually = true
        try persist(value)
    }
}
