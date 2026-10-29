import Foundation
import AppIntents
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity for one hot-water shower session. Compiled into both the app and the widget.
struct ShowerActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case active, settling, settled, unconfirmed
    }
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var phase: Phase
        /// Only set once the server confirmed settlement.
        var durationMinutes: Int?
        /// Only set once the server confirmed settlement. Never an estimate.
        var amountYuan: Decimal?
    }
    /// Short dorm label, e.g. "3 栋 108".
    var dorm: String
}
#endif

/// Hook set by the app at launch. LiveActivityIntent.perform runs in the app process,
/// so in the widget extension this stays nil and is never called.
enum ShowerActivityBridge {
    @MainActor static var finish: (@MainActor () async throws -> Void)?
}

struct FinishShowerLiveIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "结束并结算"
    static var description = IntentDescription("结束正在进行的热水会话并提交结算。")
    static var isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        try await ShowerActivityBridge.finish?()
        return .result()
    }
}
