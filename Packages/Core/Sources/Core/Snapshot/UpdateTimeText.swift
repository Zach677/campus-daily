import Foundation

/// How the time of the last good update is written, so a reading from yesterday or earlier
/// never looks like today's. Pure text; the widget and the home screen pass their calendar.
public enum UpdateTimeText {
    /// 「8:10」
    public static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 「22:10」 today, 「昨天 22:10」 yesterday, 「10月29日 22:10」 earlier (and for a time
    /// after `now`, which only a clock change makes).
    public static func stamp(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, calendar: calendar) }
        if isYesterday(date, now: now, calendar: calendar) { return "昨天 " + clock(date, calendar: calendar) }
        return monthDay(date, calendar: calendar) + " " + clock(date, calendar: calendar)
    }

    /// The widget footer: 「22:10 更新」/「昨天 22:10 更新」/「10月29日 22:10 更新」.
    public static func widgetUpdated(_ date: Date, now: Date, calendar: Calendar) -> String {
        stamp(date, now: now, calendar: calendar) + " 更新"
    }

    /// The small widget's stale line has room for one of them only: 「8:10」 today, else the day
    /// alone, 「昨天」 or 「10月29日」 (the day matters more than the clock once it is not today).
    public static func dayOrClock(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, calendar: calendar) }
        if isYesterday(date, now: now, calendar: calendar) { return "昨天" }
        return monthDay(date, calendar: calendar)
    }

    static func monthDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}
