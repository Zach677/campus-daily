import SwiftUI
import WidgetKit
import Core

/// What the 「校日常」 widget shows (design-r2 §4). Built from the shared campus cache;
/// compiled into the widget and the app (DEBUG preview only).
struct CampusWidgetModel {
    /// Numbers to show. False = the empty state (see `loggedIn` for which copy).
    var signedIn: Bool
    /// A school login exists but nothing is cached yet: 「打开校日常⏎刷新一下」.
    var loggedIn = false
    var remainingKWh: Decimal?
    var balance: Decimal?
    /// 「昨天用了 X 度」: only when the meter reported it.
    var yesterdayKWh: Decimal?
    /// 「电费余额 ¥X」: the meter's money balance, only when a meter reading exists.
    var powerBalance: Decimal?
    var updated: Date?
    /// The user's reminder lines (Settings › 提醒), shared through the keychain; default 10 度 / 20 元.
    var lines = ReminderLines()

    static let signedOut = CampusWidgetModel(signedIn:false)
    static var needsRefresh: CampusWidgetModel { var model = signedOut; model.loggedIn = true; return model }

    init(signedIn: Bool, remainingKWh: Decimal? = nil, balance: Decimal? = nil, yesterdayKWh: Decimal? = nil,
         powerBalance: Decimal? = nil, updated: Date? = nil) {
        self.signedIn = signedIn; self.remainingKWh = remainingKWh; self.balance = balance
        self.yesterdayKWh = yesterdayKWh; self.powerBalance = powerBalance; self.updated = updated
    }

    /// Empty when nothing is stored (signed out: 「登录学校账号」) or nothing was ever read (「刷新一下」).
    /// A failed read keeps the last numbers and their time (the snapshot keeps them).
    init(snapshot: HomeSnapshot?) {
        guard let snapshot, snapshot != .empty else { self = .signedOut; return }
        guard snapshot.card.value != nil || snapshot.power.value != nil else { self = .needsRefresh; return }
        let meter = snapshot.power.value
        let stamps = [snapshot.card.fetchedAt, snapshot.power.fetchedAt].compactMap { $0 }
        self.init(signedIn:true, remainingKWh:meter?.remainingKWh, balance:snapshot.card.value?.yuan,
                  yesterdayKWh:meter?.dailyUseKWh, powerBalance:meter?.leftMoney?.yuan,
                  updated:stamps.max())
    }

    var powerLow: Bool { remainingKWh.map { $0 < lines.power } ?? false }
    var cardLow: Bool { balance.map { $0 < lines.card } ?? false }

    func accessibilityLabel(medium: Bool) -> String {
        guard signedIn else { return loggedIn ? "打开校日常，刷新一下" : "打开校日常，登录学校账号" }
        var parts: [String] = []
        if let remainingKWh { parts.append("宿舍电量 \(CampusFormat.kwh(remainingKWh)) 度") }
        if let balance { parts.append("校园卡余额 \(CampusFormat.plainYuan(balance)) 元") }
        if medium, let powerBalance { parts.append("电费余额 \(CampusFormat.plainYuan(powerBalance)) 元") }
        return parts.joined(separator:"，")
    }
}

/// Round-1 tokens for the widget, which has no asset catalog (values from App/Assets.xcassets/Theme).
enum CampusWidgetPalette {
    private static func dynamic(_ light: (CGFloat, CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red:c.0, green:c.1, blue:c.2, alpha:c.3)
        })
    }
    static let group = dynamic((1, 1, 1, 1), (0.110, 0.110, 0.118, 1))
    static let ink = dynamic((0.067, 0.067, 0.067, 1), (0.961, 0.961, 0.961, 1))
    static let ink2 = dynamic((0.431, 0.431, 0.431, 1), (0.549, 0.549, 0.549, 1))
    static let separator = dynamic((0, 0, 0, 0.08), (1, 1, 1, 0.09))
    static let accent = dynamic((0.949, 0.376, 0.047, 1), (1, 0.478, 0.180, 1))
    static let redLarge = dynamic((0.898, 0.200, 0.165, 1), (1, 0.271, 0.227, 1))
}

/// Widget content without the container background (the widget adds `.containerBackground`,
/// the DEBUG preview draws its own rounded tile).
struct CampusWidgetFace: View {
    let model: CampusWidgetModel
    var medium = false
    private typealias P = CampusWidgetPalette
    var body: some View {
        Group {
            if !model.signedIn { signedOut }
            else if medium { mediumBody }
            else { smallBody }
        }
        .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.topLeading)
        .typesettingLanguage(Locale.Language(identifier:"zh-Hans"))
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(model.accessibilityLabel(medium:medium))
    }

    // MARK: Signed out

    private var signedOut: some View {
        // One sentence top-left in both sizes. The mascot only when truly signed out.
        VStack(alignment:.leading, spacing:10) {
            // The droplet body starts 10/64 into its box: pull it back so it sits on the 16pt margin like the text.
            if !model.loggedIn { MascotGlyph(size:28, color:P.accent).padding(.leading, -28 * 10 / 64) }
            Text(model.loggedIn ? "打开校日常\n刷新一下" : "打开校日常\n登录学校账号")
                .font(.system(size:17, weight:.semibold)).foregroundStyle(P.ink)
                .fixedSize(horizontal:false, vertical:true)
        }
    }

    // MARK: Small

    private var smallBody: some View {
        VStack(alignment:.leading, spacing:8) {
            smallStack(emoji:"⚡", number:model.remainingKWh.map(CampusFormat.kwh), unit:"度", low:model.powerLow, label:"宿舍电量")
            smallStack(emoji:"💳", number:model.balance.map(CampusFormat.yuan), unit:nil, low:model.cardLow, label:"校园卡")
            Spacer(minLength:0)
            updatedLine
        }
    }
    private func smallStack(emoji: String, number: String?, unit: String?, low: Bool, label: String) -> some View {
        VStack(alignment:.leading, spacing:4) {
            HStack(alignment:.firstTextBaseline, spacing:4) {
                Text(emoji).font(.system(size:15)).frame(width:22, alignment:.leading)
                HStack(alignment:.firstTextBaseline, spacing:3) {
                    numberText(number, size:30, low:low)
                    if let unit, number != nil { Text(unit).font(.system(size:14, weight:.medium)).foregroundStyle(P.ink2) }
                }
            }
            Text(label).font(.system(size:13, weight:.medium)).foregroundStyle(P.ink2).padding(.leading,26)
        }
    }

    // MARK: Medium

    private var mediumBody: some View {
        HStack(alignment:.top, spacing:0) {
            VStack(alignment:.leading, spacing:0) {
                header("⚡ 宿舍电量")
                HStack(alignment:.firstTextBaseline, spacing:3) {
                    numberText(model.remainingKWh.map(CampusFormat.kwh), size:34, low:model.powerLow)
                    if model.remainingKWh != nil { Text("度").font(.system(size:15, weight:.medium)).foregroundStyle(P.ink2) }
                }.padding(.top,8)
                VStack(alignment:.leading, spacing:2) {
                    if let yesterday = model.yesterdayKWh { mini("昨天用了", CampusFormat.kwh(yesterday), " 度") }
                    if let money = model.powerBalance { mini("电费余额", CampusFormat.yuan(money), "") }
                }.padding(.top,4)
                Spacer(minLength:0)
                updatedLine
            }
            .padding(.trailing,12)
            .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.topLeading)
            Rectangle().fill(P.separator).frame(width:0.5)
            VStack(alignment:.leading, spacing:0) {
                header("💳 校园卡")
                numberText(model.balance.map(CampusFormat.yuan), size:34, low:model.cardLow).padding(.top,8)
                if model.balance != nil {
                    Text("余额").font(.system(size:13)).foregroundStyle(P.ink2).padding(.top,4)
                }
                Spacer(minLength:0)
            }
            .padding(.leading,16)
            .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.topLeading)
        }
    }
    private func header(_ text: String) -> some View {
        Text(text).font(.system(size:13, weight:.semibold)).foregroundStyle(P.ink2).lineLimit(1)
    }
    /// 13 ink2, the number inside in ink medium.
    private func mini(_ lead: String, _ number: String, _ tail: String) -> some View {
        let value = Text(number).fontWeight(.medium).foregroundStyle(P.ink)
        return Text("\(lead) \(value)\(tail)").font(.system(size:13)).foregroundStyle(P.ink2).lineLimit(1)
    }

    // MARK: Shared pieces

    private func numberText(_ number: String?, size: CGFloat, low: Bool) -> some View {
        Text(number ?? "—")
            .font(.system(size:size, weight:.semibold, design:.rounded)).monospacedDigit().tracking(-0.4)
            .foregroundStyle(number == nil ? P.ink2 : low ? P.redLarge : P.ink)
            .lineLimit(1).minimumScaleFactor(0.6)
            .widgetAccentable()
    }
    @ViewBuilder private var updatedLine: some View {
        if let updated = model.updated {
            Text(CampusFormat.updated(updated)).font(.system(size:11)).monospacedDigit().foregroundStyle(P.ink2).lineLimit(1)
        }
    }
}
