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

    /// A shower or laundry start refused while a reset runs (what Shortcuts shows, too).
    public struct InProgress: LocalizedError, Sendable, Equatable {
        public init() {}
        public var errorDescription: String? { "正在重置" }
    }

    /// All or nothing. The marker goes first, so from then on nothing can start; then one check of
    /// the locks. A lock removes the marker and returns, with nothing signed out or cleared.
    /// Otherwise: school sign-out (local deletes happen whatever it meets), clear, reload. The
    /// marker goes with the clear, and only when the clear succeeded: a failed or interrupted
    /// clear leaves it, and the next launch finishes the reset (`resume`). Returns the lock that
    /// stopped it, or nil when the stores were cleared. A marker that can't be written stops it
    /// before anything happens (thrown).
    @MainActor public static func run(marker: ResetMarker, now: Date, lock: () -> Lock?, signOut: () async -> Void,
                                      clear: () throws -> Void, reload: () async -> Void) async throws -> Lock? {
        try marker.begin(at: now)
        if let found = lock() {
            try? marker.end()
            return found
        }
        await signOut()
        var failure: Error?
        do { try clear() } catch { failure = error }
        await reload()
        if let failure { throw failure }
        return nil
    }

    public enum Resumed: Sendable, Equatable {
        case completed
        case stopped(Lock)
    }

    /// At launch: a marker left by a reset that did not finish. The same steps as `run`, the lock
    /// check included (a shower may have started once the marker went stale): stopped, the marker
    /// goes and nothing is cleared. Nil when there is no marker.
    @MainActor public static func resume(marker: ResetMarker, now: Date, lock: () -> Lock?, signOut: () async -> Void,
                                         clear: () throws -> Void, reload: () async -> Void) async throws -> Resumed? {
        guard marker.startedAt() != nil else { return nil }
        let stopped = try await run(marker: marker, now: now, lock: lock, signOut: signOut, clear: clear, reload: reload)
        return stopped.map(Resumed.stopped) ?? .completed
    }

    /// The locks as stored, for when the models may not have loaded yet (at launch): the shower
    /// record and the laundry record, an unreadable one locking as `recordsUnreadable`.
    public static func storedLock(store: SecureStore) -> Lock? {
        let shower: ShowerState, laundry: LaundryCheckout
        do {
            shower = ShowerReducer.restore(try StoredShowerVault(store: store).showerState())
            laundry = LaundryReducer.restore(try StoredLaundryVault(store: store).checkout())
        } catch { return .recordsUnreadable }
        return lock(shower: shower, laundry: laundry.phase)
    }

    /// Every Keychain item. A new `StoreKey` is cleared without being listed here. The reset
    /// marker is the last, and only when everything before it went.
    public static var keychainItems: [StoreKey] { StoreKey.allCases.filter { $0 != .sharedResetMarker } + [.sharedResetMarker] }

    public struct Failure: Error, Sendable, Equatable {
        /// Item or file names only (never values).
        public var items: [String]
    }

    /// Deletes everything; keeps going after a failure and reports what could not be deleted.
    /// After a failure the reset marker stays, so the next launch tries again.
    /// `preferencesDomain` is the app's own preferences domain (its bundle id; a suite name in
    /// tests): the whole domain goes, so a preference added later, `xrc.`-named or not, is
    /// cleared without being listed.
    public static func clear(store: SecureStore, preferences: UserDefaults, preferencesDomain: String, files: [URL],
                             fileManager: FileManager = .default) throws {
        var failed: [String] = []
        for key in keychainItems where key != .sharedResetMarker {
            do { try store.delete(key) } catch { failed.append(key.rawValue) }
        }
        preferences.removePersistentDomain(forName: preferencesDomain)
        for url in files where fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) } catch { failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty { throw Failure(items: failed) }
        do { try store.delete(.sharedResetMarker) } catch { throw Failure(items: [StoreKey.sharedResetMarker.rawValue]) }
    }
}
