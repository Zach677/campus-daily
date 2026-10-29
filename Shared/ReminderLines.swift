import Foundation
import Security

/// The user's 「电量低于 N 度」/「校园卡低于 N 元」 lines, shared with the widget through the same
/// keychain access group as the campus cache (there is no app group). Defaults 10 度 / 20 元.
struct ReminderLines: Codable, Equatable {
    var powerKWh: Int = 10
    var cardYuan: Int = 20
    var power: Decimal { Decimal(powerKWh) }
    var card: Decimal { Decimal(cardYuan) }

    private static let service = "CampusDaily.reminder-lines.v1"
    /// No explicit access group: like CampusSharedCache, Security uses the default group both
    /// targets are signed with (first entry of keychain-access-groups).
    private static func query() -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,
         kSecAttrService as String:service, kSecAttrAccount as String:"lines"]
    }
    /// Shared value, or the defaults when nothing was saved yet.
    static func shared() -> ReminderLines {
        var request = query()
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &data) == errSecSuccess, let bytes = data as? Data,
              bytes.count <= 1024, let value = try? JSONDecoder().decode(ReminderLines.self, from:bytes) else { return ReminderLines() }
        return value
    }
    /// App only. Returns false when the keychain refused the write.
    @discardableResult func share() -> Bool {
        guard let bytes = try? JSONEncoder().encode(self) else { return false }
        let key = Self.query()
        let changes: [String:Any] = [kSecValueData as String:bytes,
                                     kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = key; changes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
