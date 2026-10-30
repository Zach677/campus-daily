import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

private enum ShowerStyle {
    static let accent = Color(red:1, green:138 / 255, blue:69 / 255) // #FF8A45
    static let background = Color(white:0.07).opacity(0.82)
    static func rounded(_ size: CGFloat) -> Font { .system(size:size, weight:.semibold, design:.rounded) }
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "HH:mm"
        return formatter.string(from:date)
    }
    /// Only ever called with a server-confirmed amount.
    static func yuan(_ value: Decimal) -> String {
        "¥" + value.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier:"en_US_POSIX")))
    }
}

private typealias ShowerState = ShowerActivityAttributes.ContentState

private extension ShowerState {
    var title: String {
        switch phase {
        case .active, .settling: return "正在洗澡"
        case .settled: return "洗好了"
        case .unconfirmed: return "结算待核对"
        }
    }
    var showsTimer: Bool { phase == .active || phase == .settling }
}

private struct ShowerTimer: View {
    let state: ShowerState
    let size: CGFloat
    var body: some View {
        Text(timerInterval:state.startedAt...Date.distantFuture, countsDown:false)
            .font(ShowerStyle.rounded(size)).monospacedDigit()
    }
}

/// Settled amount, or a neutral word when the server did not report one. Never an estimate.
private struct ShowerResult: View {
    let state: ShowerState
    let size: CGFloat
    var body: some View {
        Group {
            if state.phase == .settled, let amount = state.amountYuan { Text(ShowerStyle.yuan(amount)).monospacedDigit() }
            else if state.phase == .settled { Text("已结算") }
            else { Text("待核对") }
        }.font(ShowerStyle.rounded(size))
    }
}

private struct ShowerFinishButton: View {
    let state: ShowerState
    var fullWidth = false
    var body: some View {
        if state.phase == .settling {
            label("正在结算…").opacity(0.5)
        } else {
            Button(intent:FinishShowerLiveIntent()) { label("结束并结算") }.buttonStyle(.plain)
        }
    }
    private func label(_ text: String) -> some View {
        Text(text).font(.system(size:15, weight:.semibold)).foregroundStyle(.black)
            .padding(.horizontal,18).frame(maxWidth:fullWidth ? .infinity : nil).frame(height:40)
            .background(.white, in:Capsule())
    }
}

private struct ShowerLockScreen: View {
    let dorm: String
    let state: ShowerState
    private var caption: String {
        switch state.phase {
        case .active, .settling: return ShowerStyle.clock(state.startedAt) + " 开始 · 结算后显示费用"
        case .settled: return state.durationMinutes.map { "\($0) 分钟" } ?? ShowerStyle.clock(state.startedAt) + " 开始"
        case .unconfirmed: return "请打开校日常查看当前记录"
        }
    }
    var body: some View {
        VStack(alignment:.leading, spacing:8) {
            HStack(spacing:6) {
                Image(systemName:"drop.fill")
                Text(state.title)
                Spacer(minLength:8)
                Text("校日常").foregroundStyle(.white.opacity(0.6))
                Text(dorm).font(.system(size:12, weight:.semibold)).foregroundStyle(.white)
                    .padding(.horizontal,7).frame(height:22)
                    .background(.white.opacity(0.16), in:RoundedRectangle(cornerRadius:6))
            }.font(.system(size:13, weight:.semibold)).foregroundStyle(ShowerStyle.accent).lineLimit(1)
            HStack(alignment:.bottom) {
                VStack(alignment:.leading, spacing:4) {
                    if state.showsTimer { ShowerTimer(state:state, size:44) } else { ShowerResult(state:state, size:44) }
                    Text(caption).font(.system(size:13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength:8)
                if state.showsTimer { ShowerFinishButton(state:state) }
            }
        }
        .foregroundStyle(.white)
        .padding(.top,14).padding(.horizontal,16).padding(.bottom,16)
    }
}

struct ShowerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for:ShowerActivityAttributes.self) { context in
            ShowerLockScreen(dorm:context.attributes.dorm, state:context.state)
                .activityBackgroundTint(ShowerStyle.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(state.title).font(.system(size:13, weight:.semibold)).foregroundStyle(ShowerStyle.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.dorm).font(.system(size:13, weight:.semibold)).foregroundStyle(.white.opacity(0.55))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment:.leading, spacing:10) {
                        if state.showsTimer {
                            ShowerTimer(state:state, size:36)
                            ShowerFinishButton(state:state, fullWidth:true)
                        } else {
                            HStack(alignment:.lastTextBaseline) {
                                Text(state.durationMinutes.map { "\($0) 分钟" } ?? "")
                                    .font(.system(size:13, weight:.semibold)).foregroundStyle(.white.opacity(0.55))
                                Spacer()
                                ShowerResult(state:state, size:36)
                            }
                        }
                    }.foregroundStyle(.white)
                }
            } compactLeading: {
                Image(systemName:"drop.fill").foregroundStyle(ShowerStyle.accent)
            } compactTrailing: {
                Group {
                    if state.showsTimer { ShowerTimer(state:state, size:14) } else { ShowerResult(state:state, size:14) }
                }
                .font(ShowerStyle.rounded(14)).foregroundStyle(ShowerStyle.accent).lineLimit(1).minimumScaleFactor(0.6)
                .frame(width:44)
            } minimal: {
                Image(systemName:"drop.fill").foregroundStyle(ShowerStyle.accent)
            }
            .keylineTint(ShowerStyle.accent)
        }
    }
}
