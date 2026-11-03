import SwiftUI
import Core

/// The 洗衣 tile's status line: 「空闲」, 「待付款」, 「还剩 18 分钟」 counting down, or 「待核对」 in
/// the notice colour.
struct ClearLaundryTileStatus: View {
    let value: RowValue?

    var body: some View {
        switch value {
        case .word(let word)?:
            Text(word).foregroundStyle(Theme.ink2)
        case .accentWord(let word)?:
            Text(word).foregroundStyle(Theme.notice)
        case .countdown(let end)?:
            TimelineView(minuteSchedule(to:end)) { context in
                Text("还剩 \(LaundryFormat.minutesLeft(until:end, now:context.date)) 分钟")
                    .monospacedDigit().foregroundStyle(Theme.ink2)
            }
        default:
            EmptyView()
        }
    }
}
