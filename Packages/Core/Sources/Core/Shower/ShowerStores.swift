import Foundation

/// `ShowerVault` over a `SecureStore`: `water.binding` and `water.session`
/// (AfterFirstUnlockThisDeviceOnly, not shared with the widget). Writes throw (fail closed).
public struct StoredShowerVault: ShowerVault {
    let store: SecureStore
    public init(store: SecureStore) { self.store = store }

    public func binding() throws -> ShowerBinding? {
        guard let data = try store.read(.showerBinding) else { return nil }
        do { return try JSONDecoder().decode(ShowerBinding.self, from: data) }
        catch { throw StorageError(operation: "decode \(StoreKey.showerBinding.rawValue)", status: -1) }
    }
    public func saveBinding(_ binding: ShowerBinding?) throws { try store.writeJSON(binding, .showerBinding) }
    /// Throws `ShowerEngineError.unreadableRecord` when the record is there but can't be decoded.
    public func showerState() throws -> ShowerState? {
        guard let data = try store.read(.showerSession) else { return nil }
        do { return try JSONDecoder().decode(ShowerState.self, from: data) }
        catch { throw ShowerEngineError.unreadableRecord }
    }
    public func saveShowerState(_ state: ShowerState?) throws { try store.writeJSON(state, .showerSession) }
}
