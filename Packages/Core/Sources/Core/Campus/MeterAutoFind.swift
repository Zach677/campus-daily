import Foundation

/// When the automatic meter lookup (`SchoolSession.matchElectricity`) starts by itself. Only
/// signed in with no meter bound. Back in the foreground and after a home refresh it re-finds
/// only with the dorm address known, at most once every `interval` counted from the last start
/// of any kind; launch and 「再找一次电表」 (`manual`) are not held back. Pure; the app keeps one.
public struct MeterAutoFind: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable {
        /// The app's cold launch.
        case launch
        /// Back in the foreground.
        case foreground
        /// A home refresh that read the card.
        case refreshed
        /// 「再找一次电表」.
        case manual
    }

    public static let interval: TimeInterval = 600
    private var lastStart: Date?

    public init() {}

    /// Whether the lookup starts now. A start is counted; a refusal is not.
    public mutating func start(_ trigger: Trigger, signedIn: Bool, meterBound: Bool, addressKnown: Bool, now: Date) -> Bool {
        guard signedIn, !meterBound else { return false }
        switch trigger {
        case .launch, .manual: break
        case .foreground, .refreshed:
            guard addressKnown else { return false }
            // A clock set back (now before the last start) does not hold it off.
            if let lastStart, now >= lastStart, now.timeIntervalSince(lastStart) < Self.interval { return false }
        }
        lastStart = now
        return true
    }
}
