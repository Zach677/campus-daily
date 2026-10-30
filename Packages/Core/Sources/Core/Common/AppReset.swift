import Foundation

/// Settings › 高级 › 重置校日常: everything this app stored, back to a fresh install.
/// Clears every Keychain item (school login and saved password, login device id, dorm and
/// meter, hot-water binding and remembered controller, shower record, U净 login and device,
/// laundry record, widget snapshot and reminder lines), every preference the app set, and the files
/// the app wrote (imported hot-water file, records, diagnostics). The hot-water parameters
/// bundled with the app are read-only resources and stay.
public enum AppReset {
    /// Why reset is not offered right now.
    public enum Lock: Sendable, Equatable {
        /// Water may be flowing or a step of the shower is still running.
        case showering
        /// A settlement is waiting to be checked against the school's records.
        case unsettled
        /// A laundry order is not finished (being created, paid, running or needing attention).
        case laundry
    }

    /// Reset waits for the shower to end and its settlement to be checked, and for any laundry
    /// order to finish: clearing in between would lose the only record of a charge.
    public static func lock(shower: ShowerState?, laundry: LaundryPhase? = nil, laundryBusy: Bool = false) -> Lock? {
        if let s = shower {
            if s.phase == .failed, s.failure?.needsReview == true { return .unsettled }
            if s.stateReviewRequired { return .unsettled }
            if !s.canStart { return .showering }
        }
        if laundryBusy || (laundry ?? LaundryPhase.none) != LaundryPhase.none { return .laundry }
        return nil
    }

    /// Every Keychain item. A new `StoreKey` is cleared without being listed here.
    public static var keychainItems: [StoreKey] { StoreKey.allCases }

    public struct Failure: Error, Sendable, Equatable {
        /// Item or file names only (never values).
        public var items: [String]
    }

    /// Deletes everything; keeps going after a failure and reports what could not be deleted.
    /// `preferencesDomain` is the app's own preferences domain (its bundle id; a suite name in
    /// tests): the whole domain goes, so a preference added later, `xrc.`-named or not, is
    /// cleared without being listed.
    public static func clear(store: SecureStore, preferences: UserDefaults, preferencesDomain: String, files: [URL],
                             fileManager: FileManager = .default) throws {
        var failed: [String] = []
        for key in keychainItems {
            do { try store.delete(key) } catch { failed.append(key.rawValue) }
        }
        preferences.removePersistentDomain(forName: preferencesDomain)
        for url in files where fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) } catch { failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty { throw Failure(items: failed) }
    }
}
