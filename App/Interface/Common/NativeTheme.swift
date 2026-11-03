import SwiftUI

/// The system grouped-list look of the web and form pages (充值, 电费, 洗衣机, 学校登录, 热水详情).
/// The tint follows the theme; read in a body, like `Theme`'s tokens.
enum NativeTheme {
    static let background = Color(uiColor:.systemGroupedBackground)
    static let surface = Color(uiColor:.secondarySystemGroupedBackground)
    static var tint: Color { Theme.accentText }
    static var action: Color { Theme.pill }
}
