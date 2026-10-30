import Foundation

/// Where hot water stands, as the home shower button shows it.
public enum ShowerHomeStatus: Equatable, Sendable {
    case unconfigured
    /// Hot water can't be used in this build or at this school (no start); the reason is the subtitle.
    case unavailable(String)
    case idle
    case starting
    case showering(Date)
    case settling(Date)
    /// A record that needs checking before another start (stage label).
    case unresolved(String)
    public var showering: Date? {
        switch self { case .showering(let date), .settling(let date): return date; default: return nil }
    }
}
