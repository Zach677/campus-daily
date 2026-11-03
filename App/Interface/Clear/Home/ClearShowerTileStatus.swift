import SwiftUI
import Core

/// The 热水 tile's status line: 「上次 11 分钟 · ¥1.32」, 「正在洗澡 08:42」 counting, or a record to
/// check in the notice colour. Always one line.
struct ClearShowerTileStatus: View {
    let status: ShowerTileStatus

    var body: some View {
        // One text, so 「正在洗澡 08:42」 shrinks as one line, not as two columns.
        Group {
            if let start = status.timerStart {
                Text("\(status.text) \(Text(timerInterval:start...Date.distantFuture, countsDown:false))").monospacedDigit()
            } else {
                Text(status.text)
            }
        }
        // One line on every screen: shrinks a little rather than wrapping under the tile.
        .lineLimit(1).minimumScaleFactor(0.85)
        .foregroundStyle(color)
    }

    private var color: Color {
        switch status.tone {
        case .secondary: Theme.ink2
        case .notice: Theme.notice
        case .accent: Theme.accentText
        }
    }
}
