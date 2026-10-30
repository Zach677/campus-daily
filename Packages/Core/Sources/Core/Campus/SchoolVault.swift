import Foundation

/// Persistence the school engine needs. Implemented by `StoredSchoolVault` (SchoolStores.swift) and by
/// in-memory fakes. Writes throw so callers can fail closed.
public protocol SchoolVault: Sendable {
    func portalToken() throws -> PortalToken?
    func savePortalToken(_ token: PortalToken?) throws
    func ecyktSession() throws -> EcyktSession?
    func saveEcyktSession(_ session: EcyktSession?) throws
    func profile() throws -> SchoolProfile?
    func saveProfile(_ profile: SchoolProfile?) throws
    func account() throws -> SchoolAccount?
    func saveAccount(_ account: SchoolAccount?) throws
    func loginDeviceID() throws -> String?
    func saveLoginDeviceID(_ id: String?) throws
}
