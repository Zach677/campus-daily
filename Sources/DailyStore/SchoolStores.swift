import Foundation
import DailyCore

/// `SchoolVault` over a `SecureStore` (Keychain in the app, in-memory in tests).
public struct StoredSchoolVault: SchoolVault {
    let store: SecureStore
    public init(store: SecureStore) { self.store = store }

    private struct PortalBox: Codable { var token: String }

    public func portalToken() throws -> PortalToken? {
        try store.readJSON(PortalBox.self, .schoolPortal).map { PortalToken($0.token) }
    }
    public func savePortalToken(_ token: PortalToken?) throws {
        try store.writeJSON(token.map { PortalBox(token: $0.value) }, .schoolPortal)
    }
    public func ecyktSession() throws -> EcyktSession? { try store.readJSON(EcyktSession.self, .schoolEcykt) }
    public func saveEcyktSession(_ session: EcyktSession?) throws { try store.writeJSON(session, .schoolEcykt) }
    public func profile() throws -> SchoolProfile? { try store.readJSON(SchoolProfile.self, .schoolProfile) }
    public func saveProfile(_ profile: SchoolProfile?) throws { try store.writeJSON(profile, .schoolProfile) }
}

/// The widget-shared home snapshot (`shared.snapshot`, ≤ 64 KiB JSON).
public struct SharedSnapshotStore: SnapshotStoring {
    let store: SecureStore
    /// Called after each successful write (App: `WidgetCenter.reloadTimelines(ofKind:)`).
    let didWrite: @Sendable () -> Void

    public static let widgetKind = "XiaoRiChangBalances"

    public init(store: SecureStore, didWrite: @escaping @Sendable () -> Void = {}) {
        self.store = store
        self.didWrite = didWrite
    }

    public func loadSnapshot() throws -> HomeSnapshot? {
        try store.readJSON(HomeSnapshot.self, .sharedSnapshot)
    }

    public func saveSnapshot(_ snapshot: HomeSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let data: Data
        do { data = try encoder.encode(snapshot) }
        catch { throw StorageError(operation: "encode shared.snapshot", status: -1) }
        guard data.count <= HomeSnapshot.maxEncodedBytes else {
            throw StorageError(operation: "write shared.snapshot (too large)", status: -1)
        }
        try store.write(data, for: .sharedSnapshot)
        didWrite()
    }
}
