import SwiftUI
import Observation
import WidgetKit
import Core

/// The theme the app draws with, read by every token in `Theme`. Observable: a view whose body
/// read a token is drawn again when the theme changes, so a switch shows at once, without a
/// restart. Written on the main actor only (`select`).
@Observable final class ThemeStore: @unchecked Sendable {
    private(set) var theme: AppTheme
    @ObservationIgnored private let preference: ThemePreference
    /// The App Group's lock, which the widget and Live Activities' processes respect.
    @ObservationIgnored private let lock: any SharedLock

    init(preference: ThemePreference, lock: any SharedLock) {
        self.preference = preference
        self.lock = lock
        theme = preference.theme
    }

    /// Saves the choice where the widget and the Live Activities read it, and has the widget
    /// draw again. When the shared lock can't be taken (the container locked before the first
    /// unlock) nothing changes: the option stays unselected.
    @MainActor func select(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        do { try preference.set(theme, under:lock) } catch { return }
        self.theme = theme
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// After 重置校日常 cleared the stored choice: back to what is stored (暖橙).
    @MainActor func reload() {
        let stored = preference.theme
        if stored != theme { theme = stored }
    }
}
