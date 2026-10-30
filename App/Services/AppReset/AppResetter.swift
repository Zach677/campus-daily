import Foundation
import WidgetKit
import Core

/// Settings › 高级 › 重置校日常 (design §10). The clear list itself is `AppReset` in Core; this
/// puts the running models in step before and after it, and tells the home screen to start over.
@MainActor final class AppResetter: ObservableObject {
    static let shared = AppResetter()
    /// Bumped after each completed reset: the home screen closes settings and opens the guide.
    @Published private(set) var completed = 0
    @Published private(set) var running = false

    /// Not while a shower runs or its settlement still needs checking.
    static func lock(water: ShowerModel) -> AppReset.Lock? {
        if water.busy { return .showering }
        return AppReset.lock(shower: water.state)
    }

    /// Files the app wrote (the imported hot-water file and diagnostics, the laundry and Bluetooth
    /// caches). The bundled hot-water parameters are app resources and stay.
    static var files: [URL] {
        let support = FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask)[0]
        return ["Water", "LaundryCache", "WaterSession"].map { support.appendingPathComponent($0, isDirectory:true) }
    }

    func reset(campus: CampusModel, water: ShowerModel, laundry: LaundryModel) async throws {
        guard !running, Self.lock(water:water) == nil else { return }
        running = true
        defer { running = false }
        await campus.signOutForReset()
        var failure: Error?
        do {
            try AppReset.clear(store:AppEnvironment.store, preferences:.standard,
                               preferencesDomain:Bundle.main.bundleIdentifier ?? "", files:Self.files)
        } catch {
            failure = error
        }
        campus.reload()
        await water.reloadAfterReset()
        laundry.reloadAfterReset()
        Reminders.shared.clearAfterReset()
        WidgetCenter.shared.reloadAllTimelines()
        if let failure { throw failure }
        completed += 1
    }

    #if DEBUG
    /// Demo settings: show what follows a reset without clearing anything.
    func finishDemo() { completed += 1 }
    #endif
}
