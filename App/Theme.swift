import SwiftUI

/// Round-1 design tokens (Assets.xcassets/Theme, Any/Dark).
enum Theme {
    static let bg = Color("Theme/bg")
    static let group = Color("Theme/group")
    static let ink = Color("Theme/ink")
    static let ink2 = Color("Theme/ink2")
    static let ink3 = Color("Theme/ink3")
    static let separator = Color("Theme/separator")
    static let fill = Color("Theme/fill")
    static let accent = Color("Theme/accent")
    static let accentLarge = Color("Theme/accentLarge")
    static let accentText = Color("Theme/accentText")
    /// Label on an `accent` background: white in light, #111 in dark.
    static let accentInk = Color("Theme/accentInk")
    static let redLarge = Color("Theme/redLarge")
    static let redText = Color("Theme/redText")
    static let pill = Color("Theme/pill")
    static let pillInk = Color("Theme/pillInk")

    /// UI copy language for `.typesettingLanguage(_:)`.
    static let typesetting = Locale.Language(identifier:"zh-Hans")

    static let spring = Animation.spring(response:0.45, dampingFraction:0.82)
    static let pressSpring = Animation.spring(response:0.3, dampingFraction:0.6)

    /// "3栋108" → "3 栋 108"; nil when unknown.
    static func dorm(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in:.whitespaces)
        guard !value.isEmpty, value != "未配置" else { return nil }
        let parts = value.split(separator:"栋", maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { return parts[0] + " 栋 " + parts[1] }
        return value
    }
    static func yuan(_ value: Decimal) -> String { CampusFormat.yuan(value) }
    static func kwh(_ value: Decimal) -> String { CampusFormat.kwh(value) }
    static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        "周" + ["日","一","二","三","四","五","六"][calendar.component(.weekday, from:date) - 1]
    }
    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "HH:mm"
        return formatter.string(from:date)
    }
    /// 「10:32 更新」/「昨天 22:10 更新」/「10月26日更新」 (shared with the widget).
    static func updated(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        CampusFormat.updated(date, now:now, calendar:calendar)
    }
    /// Recent-row time: 「刚刚」/「今天 09:12」/「昨天 22:14」/「周一 19:02」/「10月20日 19:02」
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let age = now.timeIntervalSince(date)
        if age >= 0, age < 300 { return "刚刚" }
        if calendar.isDate(date, inSameDayAs:now) { return "今天 " + clock(date) }
        if calendar.isDateInYesterday(date) { return "昨天 " + clock(date) }
        if age > 0, age < 6 * 86400 { return weekday(date, calendar:calendar) + " " + clock(date) }
        let parts = calendar.dateComponents([.month,.day], from:date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日 " + clock(date)
    }
}

/// System font at a Dynamic Type–scaled size.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let cap: CGFloat?
    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle, cap: CGFloat?) {
        _size = ScaledMetric(wrappedValue:size, relativeTo:style)
        self.weight = weight; self.design = design; self.cap = cap
    }
    func body(content: Content) -> some View {
        content.font(.system(size:cap.map { min(size, $0) } ?? size, weight:weight, design:design))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body, cap: CGFloat? = nil) -> some View {
        modifier(ScaledFont(size:size, weight:weight, design:design, relativeTo:style, cap:cap))
    }
}

/// Dock pills / round button: scale 0.96 on press.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.pressSpring, value:configuration.isPressed)
    }
}

/// List rows: opacity 0.5 on press, no highlight fill.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1).contentShape(Rectangle())
    }
}

/// 0.5pt hairline in `separator`.
struct Hairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View { Rectangle().fill(Theme.separator).frame(height:1 / scale) }
}
