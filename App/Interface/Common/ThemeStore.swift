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

    init(preference: ThemePreference) {
        self.preference = preference
        theme = preference.theme
    }

    /// Saves the choice where the widget and the Live Activities read it, and has the widget
    /// draw again.
    @MainActor func select(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        preference.set(theme)
        self.theme = theme
        WidgetCenter.shared.reloadAllTimelines()
    }
}
