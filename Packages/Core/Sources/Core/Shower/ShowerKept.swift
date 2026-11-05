import Foundation

/// Showers not settled in the app: stopped on the controller (the school settles them) and kept
/// by the next start (`ShowerVault.retainShower`). The stopped page counts them in one line.
public enum ShowerKept {
    /// The kept records plus the stopped one on screen, once (it is kept already when a next
    /// start got as far as keeping it).
    public static func count(retained: [ShowerState], current: ShowerState) -> Int {
        let stopped = current.mayBeFlowing && current.stateReviewRequired
        guard stopped else { return retained.count }
        let kept = retained.contains { same($0, current) }
        return retained.count + (kept ? 0 : 1)
    }

    private static func same(_ a: ShowerState, _ b: ShowerState) -> Bool {
        if let id = a.authorizationID, id == b.authorizationID { return a.machineID == b.machineID }
        return a == b.persistable
    }
}
