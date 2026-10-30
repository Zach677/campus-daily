import Foundation
import WidgetKit
import Core

/// Settings › 高级 › 重置校日常. The clear list itself is `AppReset` in Core; this
/// puts the running models in step before and after it, and tells the home screen to start over.
@MainActor final class AppResetter: ObservableObject {
    static let shared = AppResetter()
    /// Bumped after each completed reset: the home screen closes settings and opens the guide.
    @Published private(set) var completed = 0
    @Published private(set) var running = false

    /// Not while a shower runs or its settlement still needs checking, with an unfinished
    /// laundry order, while a record can't be read, or while a controller check runs.
    static func lock(water: ShowerModel, laundry: LaundryModel) -> AppReset.Lock? {
        if water.busy && !water.storageBlocked && !laundry.storageBlocked { return .showering }
        return AppReset.lock(shower:water.state, laundry:laundry.checkout?.phase, laundryBusy:laundry.checkoutBusy,
                             recordsUnreadable:water.storageBlocked || laundry.storageBlocked,
                             checkingController:water.inspecting)
    }

    /// Files the app wrote (the imported hot-water file and diagnostics, the laundry and Bluetooth
    /// caches). The bundled hot-water parameters are app resources and stay.
    static var files: [URL] {
        let support = FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask)[0]
        return ["Water", "LaundryCache", "WaterSession"].map { support.appendingPathComponent($0, isDirectory:true) }
            + [ShowerDiagnosticReport.exportFolder]
    }

    /// The order is `AppReset.run`: lock, sign out, lock again, clear, reload. Returns the lock
    /// that stopped it (nil = reset done).
    @discardableResult
    func reset(campus: CampusModel, water: ShowerModel, laundry: LaundryModel) async throws -> AppReset.Lock? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        let stopped = try await AppReset.run(
            lock: { Self.lock(water:water, laundry:laundry) },
            signOut: { await campus.signOutForReset() },
            clear: {
                // The in-memory diagnostics first: the next event would write them all back.
                ShowerDiagnosticReport.clearMemory()
                try AppReset.clear(store:AppEnvironment.store, preferences:.standard,
                                   preferencesDomain:Bundle.main.bundleIdentifier ?? "", files:Self.files)
            },
            reload: {
                campus.reload()
                await water.reloadAfterReset()
                laundry.reloadAfterReset()
                Reminders.shared.clearAfterReset()
                ShowerActivityController.shared.endAll()
                WidgetCenter.shared.reloadAllTimelines()
            })
        if stopped == nil { completed += 1 }
        return stopped
    }

    #if DEBUG
    /// Demo settings: show what follows a reset without clearing anything.
    func finishDemo() { completed += 1 }
    #endif
}
