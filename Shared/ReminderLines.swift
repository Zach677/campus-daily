import Foundation
import DailyStore

/// The user's 「电量低于 N 度」/「校园卡低于 N 元」 lines, shared with the widget through the
/// Keychain item `shared.reminderLines`. Defaults 10 度 / 20 元.
struct ReminderLines: Codable, Equatable {
    var powerKWh: Int = 10
    var cardYuan: Int = 20
    var power: Decimal { Decimal(powerKWh) }
    var card: Decimal { Decimal(cardYuan) }

    /// Shared value, or the defaults when nothing was saved yet.
    static func shared() -> ReminderLines {
        guard let bytes = (try? SharedKeychain.store.read(.sharedReminderLines)) ?? nil, bytes.count <= 1024,
              let value = try? JSONDecoder().decode(ReminderLines.self, from:bytes) else { return ReminderLines() }
        return value
    }
    /// App only. Returns false when the keychain refused the write.
    @discardableResult func share() -> Bool {
        guard let bytes = try? JSONEncoder().encode(self) else { return false }
        return (try? SharedKeychain.store.write(bytes, for:.sharedReminderLines)) != nil
    }
}
