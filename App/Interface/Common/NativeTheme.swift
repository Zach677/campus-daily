import SwiftUI

/// The system grouped-list look of the web and form pages (充值, 电费, 洗衣机, 学校登录, 热水详情).
/// The tint follows the theme; read in a body, like `Theme`'s tokens.
enum NativeTheme {
    static let background = Color(uiColor:.systemGroupedBackground)
    static let surface = Color(uiColor:.secondarySystemGroupedBackground)
    // Computed, never cached in a `let`: a stored value would keep the theme of the first read.
    static var tint: Color { Theme.accentText }
    static var action: Color { Theme.pill }
    /// Problems on these pages: the system orange in 暖橙 (what they always showed), the theme's
    /// `notice` in 清爽.
    static var notice: Color { Theme.current == .clear ? Theme.notice : .orange }
}
