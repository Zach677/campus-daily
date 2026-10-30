import Foundation

/// `WaterVault` over a `SecureStore`: `water.binding` and `water.session`
/// (AfterFirstUnlockThisDeviceOnly, not shared with the widget). Writes throw (fail closed).
public struct StoredWaterVault: WaterVault {
    let store: SecureStore
    public init(store: SecureStore) { self.store = store }

    public func binding() throws -> WaterBinding? { try store.readJSON(WaterBinding.self, .waterBinding) }
    public func saveBinding(_ binding: WaterBinding?) throws { try store.writeJSON(binding, .waterBinding) }
    public func showerState() throws -> ShowerState? { try store.readJSON(ShowerState.self, .waterSession) }
    public func saveShowerState(_ state: ShowerState?) throws { try store.writeJSON(state, .waterSession) }
}
