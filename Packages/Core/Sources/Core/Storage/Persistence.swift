import Foundation

/// Persistence the school engine needs. Implemented by the Keychain stores in `Storage/` and by
/// in-memory fakes. Writes throw so callers can fail closed.
public protocol SchoolVault: Sendable {
    func portalToken() throws -> PortalToken?
    func savePortalToken(_ token: PortalToken?) throws
    func ecyktSession() throws -> EcyktSession?
    func saveEcyktSession(_ session: EcyktSession?) throws
    func profile() throws -> SchoolProfile?
    func saveProfile(_ profile: SchoolProfile?) throws
}

/// Where the home snapshot is shared with the widget.
public protocol SnapshotStoring: Sendable {
    func loadSnapshot() throws -> HomeSnapshot?
    func saveSnapshot(_ snapshot: HomeSnapshot) throws
}

/// Storage failure. Session stores fail closed: the side effect after a failed write does not run.
public struct StorageError: Error, Equatable, Sendable {
    public var operation: String
    public var status: Int32
    public init(operation: String, status: Int32) { self.operation = operation; self.status = status }
}

/// Hot-water persistence (Keychain `water.binding`, `water.session`). Session writes fail
/// closed: the engine runs no side effect after a failed write.
public protocol ShowerVault: Sendable {
    func binding() throws -> ShowerBinding?
    func saveBinding(_ binding: ShowerBinding?) throws
    func showerState() throws -> ShowerState?
    func saveShowerState(_ state: ShowerState?) throws
}

/// Laundry persistence (Keychain `laundry.account`, `laundry.checkout`). Checkout writes fail
/// closed: the engine runs no side effect after a failed write.
public protocol LaundryVault: Sendable {
    func accountItem() throws -> UjingAccountItem?
    func saveAccountItem(_ item: UjingAccountItem?) throws
    func checkout() throws -> LaundryCheckout?
    func saveCheckout(_ checkout: LaundryCheckout?) throws
}

public extension LaundryVault {
    /// The per-install `x-mobile-id`: created once (UUID) and kept across logins/logouts.
    func mobileID(make: () -> String = { UUID().uuidString }) throws -> String {
        if let item = try accountItem() { return item.mobileID }
        let id = make()
        try saveAccountItem(UjingAccountItem(mobileID: id))
        return id
    }

    func account() throws -> UjingAccount? { try accountItem()?.account }

    /// Stores (or clears) the login, keeping the install's mobile id.
    func saveAccount(_ account: UjingAccount?) throws {
        let id = try mobileID()
        try saveAccountItem(UjingAccountItem(mobileID: id, account: account))
    }
}
