import SwiftUI

/// Trailing value of a status row.
enum RowValue: Equatable {
    case number(String, unit: String?, low: Bool)
    case word(String)
    /// Needs attention but isn't "running out": accentText.
    case accentWord(String)
    case dash
}

/// Home status row (design §4.3): emoji · title/subtitle · value. Min height 66.
struct StatusRow: View {
    let emoji: String
    let title: String
    var subtitle: String = ""
    var subtitleLow = false
    var value: RowValue?
    var dimmed = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing:14) {
            Text(emoji).font(.system(size:22)).frame(width:28).accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment:.leading, spacing:6) { titles; valueView }
                Spacer(minLength:0)
            } else {
                titles
                Spacer(minLength:8)
                valueView
            }
        }
        .padding(.vertical,10).frame(minHeight:66)
        .padding(.horizontal,24)
    }
    private var titles: some View {
        VStack(alignment:.leading, spacing:2) {
            Text(title).scaledFont(17, .medium).foregroundStyle(dimmed ? Theme.ink2 : Theme.ink)
            if !subtitle.isEmpty {
                Text(subtitle).scaledFont(13, relativeTo:.footnote)
                    .foregroundStyle(subtitleLow ? Theme.redText : Theme.ink2)
            }
        }.fixedSize(horizontal:false, vertical:true)
    }
    @ViewBuilder private var valueView: some View {
        switch value {
        case .number(let number, let unit, let low)?:
            HStack(alignment:.firstTextBaseline, spacing:3) {
                Text(number).scaledFont(24, .semibold, design:.rounded, relativeTo:.title2).monospacedDigit().tracking(-0.2)
                    .foregroundStyle(low ? Theme.redLarge : Theme.ink)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                if let unit { Text(unit).scaledFont(14, .medium, relativeTo:.subheadline).foregroundStyle(Theme.ink2) }
            }.lineLimit(1)
        case .word(let word)?:
            Text(word).scaledFont(17, .medium).foregroundStyle(Theme.ink2)
        case .accentWord(let word)?:
            Text(word).scaledFont(17, .medium).foregroundStyle(Theme.accentText)
        case .dash?:
            Text("—").scaledFont(17, .medium).foregroundStyle(Theme.ink3)
        case nil:
            EmptyView()
        }
    }
}

/// 「最近」 row (design §4.4): min height 56, emoji 18, 16pt text.
struct RecentRow: View {
    let item: HomeData.Recent
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing:14) {
            Text(item.emoji).font(.system(size:18)).frame(width:28).accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment:.leading, spacing:4) { titles; amountView }
                Spacer(minLength:0)
            } else {
                titles
                Spacer(minLength:8)
                amountView
            }
        }
        .padding(.vertical,8).frame(minHeight:56)
        .padding(.horizontal,24)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel([item.title, subtitle, item.amount.map { Theme.yuan($0).dropFirst() + " 元" }].compactMap { $0 }.joined(separator:"，"))
    }
    private var titles: some View {
        VStack(alignment:.leading, spacing:2) {
            Text(item.title).scaledFont(16, relativeTo:.callout).foregroundStyle(Theme.ink)
            Text(subtitle).scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
        }.fixedSize(horizontal:false, vertical:true)
    }
    @ViewBuilder private var amountView: some View {
        if let amount = item.amount {
            Text(Theme.yuan(amount)).scaledFont(16, .medium, relativeTo:.callout).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
    private var subtitle: String { [Theme.when(item.date), item.detail].compactMap { $0 }.joined(separator:" · ") }
}

/// Section header 「最近」/「登录后会出现」.
struct HomeSectionHeader: View {
    let text: String
    var body: some View {
        Text(text).scaledFont(13, .semibold, relativeTo:.footnote).foregroundStyle(Theme.ink2)
            .padding(.horizontal,24).padding(.bottom,4)
            .frame(maxWidth:.infinity, alignment:.leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Hairline between rows: starts at x = 24 and runs to the trailing edge.
struct RowSeparator: View {
    var body: some View { Hairline().padding(.leading,24) }
}

/// 8pt accent dot that pulses 1 → 0.35 on a 1.6s loop (static under Reduce Motion).
struct PulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    var body: some View {
        Circle().fill(Theme.accent).frame(width:8, height:8)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration:0.8).repeatForever(autoreverses:true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// mm:ss, h:mm:ss past one hour.
struct ShowerClock: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from:start, by:1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(Self.format(seconds))
                .contentTransition(.numericText(countsDown:false))
                .animation(.default, value:seconds)
                .accessibilityLabel(Self.spoken(seconds))
        }
    }
    static func format(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format:"%d:%02d:%02d", h, m, s) : String(format:"%02d:%02d", m, s)
    }
    /// Quantised to 30s so VoiceOver is not flooded.
    static func spoken(_ seconds: Int) -> String {
        let q = seconds / 30 * 30
        let m = q / 60, s = q % 60
        return s == 0 ? "已经洗了 \(m) 分钟" : "已经洗了 \(m) 分 \(s) 秒"
    }
}

/// Hero while showering (design §4.5). No estimated price.
struct ShowerHero: View {
    let start: Date
    let dorm: String?
    var body: some View {
        VStack(alignment:.leading, spacing:0) {
            // Dot sits on the first line even when a large text size wraps the label.
            HStack(alignment:.firstTextBaseline, spacing:7) {
                PulseDot().alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                Text(["正在洗澡", dorm].compactMap { $0 }.joined(separator:" · "))
                    .scaledFont(15, .semibold, relativeTo:.subheadline).foregroundStyle(Theme.accentText)
            }
            ShowerClock(start:start)
                .scaledFont(76, .semibold, design:.rounded, relativeTo:.largeTitle, cap:96)
                .monospacedDigit().tracking(-2).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top,6)
            Text("按水控上的出水键就有热水，结算后显示费用。")
                .scaledFont(15, relativeTo:.subheadline).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal:false, vertical:true)
                .padding(.top,10)
        }
        .frame(maxWidth:.infinity, alignment:.leading)
    }
}
