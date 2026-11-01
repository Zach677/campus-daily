import Foundation

/// Whether a BLE write that did not complete may have reached the controller. Decided here from
/// what CoreBluetooth reported (its error domain), so the rule is testable without CoreBluetooth.
public enum ShowerWriteDelivery: Sendable, Equatable {
    /// The command never reached the controller: `ShowerCommandNotSent`.
    case notSent
    /// The controller may have received and applied it.
    case maybeSent

    /// CoreBluetooth's domain for an ATT error response: the controller answered the write itself.
    public static let attErrorDomain = "CBATTErrorDomain"

    /// `written`: the write was handed to CoreBluetooth. `writeErrorDomain`: the domain of the
    /// error `didWriteValueFor` reported for it, nil when it reported none.
    /// Only an ATT error response is the controller refusing the write. A link error reported
    /// there (disconnected, connection timeout) can come after the controller applied it.
    public static func after(written: Bool, writeErrorDomain: String?) -> ShowerWriteDelivery {
        if !written || writeErrorDomain == attErrorDomain { return .notSent }
        return .maybeSent
    }
}
