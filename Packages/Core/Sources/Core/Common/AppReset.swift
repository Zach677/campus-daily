import Foundation

/// Settings › 高级 › 重置校日常: everything this app stored, back to a fresh install.
/// Clears every Keychain item (school login and saved password, the card session's and portal
/// token's obtained/alive times stored with them, login device id, dorm and meter, hot-water
/// binding and remembered controller, shower record, U净 login and device, laundry record,
/// widget snapshot and reminder lines, the app/widget refresh lease), every preference the app set, and the files
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
        /// The shower or laundry record can't be read, so nobody can tell whether a charge is open.
        case recordsUnreadable
        /// A hot-water controller check is talking to the controller.
        case checkingController
    }

    /// Reset waits for the shower to end and its settlement to be checked, and for any laundry
    /// order to finish: clearing in between would lose the only record of a charge.
    /// An unreadable record locks first: what it holds is unknown. A controller check in
    /// progress locks too (it writes the binding when it ends).
    public static func lock(shower: ShowerState?, laundry: LaundryPhase? = nil, laundryBusy: Bool = false,
                            recordsUnreadable: Bool = false, checkingController: Bool = false) -> Lock? {
        if recordsUnreadable { return .recordsUnreadable }
        if let s = shower {
            if s.phase == .failed, s.failure?.needsReview == true { return .unsettled }
            if s.stateReviewRequired { return .unsettled }
            if !s.canStart { return .showering }
        }
        if laundryBusy || (laundry ?? LaundryPhase.none) != LaundryPhase.none { return .laundry }
        if checkingController { return .checkingController }
        return nil
    }

    /// The steps of a reset, in order. `lock` is asked twice: before signing out, and again
    /// after (a shortcut may have started a shower while sign-out waited for a refresh). A lock
    /// the second time stops before anything is cleared; the school sign-out stands. `reload`
    /// runs whenever sign-out ran, so the models show what is stored even after a failure.
    /// Returns the lock that stopped it, or nil when the stores were cleared.
    @MainActor public static func run(lock: () -> Lock?, signOut: () async -> Void,
                                      clear: () throws -> Void, reload: () async -> Void) async throws -> Lock? {
        if let first = lock() { return first }
        await signOut()
        if let second = lock() {
            await reload()
            return second
        }
        var failure: Error?
        do { try clear() } catch { failure = error }
        await reload()
        if let failure { throw failure }
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
