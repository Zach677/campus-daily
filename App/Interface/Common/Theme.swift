import SwiftUI
import Core

/// Design tokens. Each resolves from the active theme (`ThemeStore`, 暖橙 or 清爽): a view that
/// reads one in its body is drawn again when the theme changes.
enum Theme {
    /// The app's theme; the store the Settings › 外观 › 主题 page writes.
    static let store = ThemeStore(preference:ThemePreference(storage:ThemePreference.sharedStorage()), lock:AppEnvironment.sharedLock)
    static var current: AppTheme { store.theme }
    private static var palette: ThemePalette { .of(store.theme) }

    static var bg: Color { palette.bg }
    static var group: Color { palette.group }
    static var ink: Color { palette.ink }
    static var ink2: Color { palette.ink2 }
    static var ink3: Color { palette.ink3 }
    static var separator: Color { palette.separator }
    static var fill: Color { palette.fill }
    static var accent: Color { palette.accent }
    static var accentLarge: Color { palette.accentLarge }
    static var accentText: Color { palette.accentText }
    /// Label on an `accent` background: white in light, #111 in dark (清爽: white in both).
    static var accentInk: Color { palette.accentInk }
    static var redLarge: Color { palette.redLarge }
    static var redText: Color { palette.redText }
    static var pill: Color { palette.pill }
    static var pillInk: Color { palette.pillInk }
    /// Problems that aren't "running out": errors, 「暂停」, what the school refused. accentText in 暖橙.
    static var notice: Color { palette.notice }
    /// Line icons at the start of rows and beside labels: ink2 in 暖橙, accentText in 清爽.
    static var icon: Color { store.theme == .clear ? palette.accentText : palette.ink2 }

    /// Corner radius of a custom `group` container (sign-in form, result panel): its 暖橙 value,
    /// 16 in 清爽.
    static func cardRadius(_ warm: CGFloat) -> CGFloat { store.theme == .clear ? 16 : warm }
    static var buttonShape: ThemeButtonShape { ThemeButtonShape(rounded:store.theme == .clear) }
    /// Big numbers: rounded in 暖橙, the default design in 清爽 (monospaced digits in both).
    static var numberDesign: Font.Design { store.theme == .clear ? .default : .rounded }
    /// Home's 校园卡 and 电量 numbers.
    static var heroSize: CGFloat { store.theme == .clear ? 34 : 40 }
    static var titleFont: ThemeTitleFont { store.theme == .clear ? .clear : .warm }

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
    /// 「10:32 更新」/「昨天 22:10 更新」/「10月26日更新」 (shared with the widget).
    static func updated(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        CampusFormat.updated(date, now:now, calendar:calendar)
    }
    /// Recent-row time: 「刚刚」/「今天 09:12」/「昨天 22:14」/「周一 19:02」/「10月20日 19:02」
    static func when(_ date: Date, now: Date = Date()) -> String {
        UpdateTimeText.recent(date, now:now)
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
