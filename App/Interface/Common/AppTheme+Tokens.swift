import SwiftUI
import Core

/// The tokens that aren't colours, for views that read the theme from `\.appTheme`.
extension AppTheme {
    /// Corner radius of a custom `group` container (sign-in form, result panel): its 暖橙 value,
    /// 16 in 清爽.
    func cardRadius(_ warm: CGFloat) -> CGFloat { self == .clear ? 16 : warm }
    var buttonShape: ThemeButtonShape { ThemeButtonShape(rounded:self == .clear) }
}
