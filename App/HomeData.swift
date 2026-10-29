import Foundation
import SwiftUI
import WaterCore

/// Everything the home screen shows, derived from the models (or DEBUG demo data).
struct HomeData {
    enum Water: Equatable {
        case unconfigured
        case idle
        case starting
        case showering(Date)
        case settling(Date)
        /// A record that needs checking before another start (stage label).
        case unresolved(String)
        var showering: Date? {
            switch self { case .showering(let date), .settling(let date): return date; default: return nil }
        }
    }
    struct Recent: Identifiable, Equatable {
        let id: String
        let emoji: String
        let title: String
        let date: Date
        let detail: String?
        let amount: Decimal?
    }
    var signedIn = true
    var dorm: String?
    var powerBound = true
    var remainingKWh: Decimal?
    var yesterdayKWh: Decimal?
    var balance: Decimal?
    var balanceUpdated: Date?
    var cardLowLine: Decimal = 20
    var water = Water.idle
    var waterIssue: String?
    var lastShowerMinutes: Int?
    var lastShowerCost: Decimal?
    var laundryBound = false
    var laundryMachine: String?
    var laundryValue: String?
    var recents: [Recent] = []

    // MARK: Electricity estimate

    private var hoursLeft: Double? {
        guard let remainingKWh, let yesterdayKWh, yesterdayKWh > 0 else { return nil }
        return NSDecimalNumber(decimal:remainingKWh / yesterdayKWh).doubleValue * 24
    }
    /// floor(remaining / yesterday), only when yesterday > 0.
    var daysLeft: Int? { hoursLeft.map { Int(($0 / 24).rounded(.down)) } }
    var powerLow: Bool {
        guard let remainingKWh else { return false }
        return remainingKWh < 10 || (daysLeft ?? 99) <= 1
    }
    /// 「今晚」/「明晚」 when the estimate runs out today/tomorrow.
    func runsOutWord(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let hoursLeft else { return nil }
        let end = now.addingTimeInterval(hoursLeft * 3600)
        if calendar.isDate(end, inSameDayAs:now) { return "今晚" }
        if let tomorrow = calendar.date(byAdding:.day, value:1, to:now), calendar.isDate(end, inSameDayAs:tomorrow) { return "明晚" }
        return nil
    }
    var cardLow: Bool { balance.map { $0 < cardLowLine } ?? false }
    var powerSubtitle: String {
        if powerLow, let word = runsOutWord() { return "约" + word + "用完" }
        return daysLeft.map { "够用约 \($0) 天" } ?? ""
    }

    // MARK: Hero sentence

    struct Segment { let text: String; var color: Color? = nil }
    var hero: [Segment] {
        guard signedIn else { return [Segment(text:"先登录学校账号，\n电量和余额就会出现。")] }
        let power = remainingKWh, card = balance
        if powerLow && cardLow { return [Segment(text:"电和校园卡都快没了，记得充值。")] }
        if powerLow, let power {
            switch runsOutWord() {
            case "今晚": return [Segment(text:"电"), Segment(text:"今晚", color:Theme.redLarge), Segment(text:"就要用完了，\n记得充电费。")]
            case "明晚": return [Segment(text:"电只够到"), Segment(text:"明晚", color:Theme.redLarge), Segment(text:"了，\n记得充电费。")]
            default: return [Segment(text:"电只剩 "), Segment(text:Theme.kwh(power) + " 度", color:Theme.redLarge), Segment(text:" 了，\n记得充电费。")]
            }
        }
        if cardLow, let card {
            return [Segment(text:"卡里只剩 "), Segment(text:Theme.yuan(card), color:Theme.redLarge), Segment(text:" 了，\n记得充值。")]
        }
        var powerPart: [Segment] = []
        if let power {
            if let days = daysLeft { powerPart = [Segment(text:"电够用 "), Segment(text:"\(days) 天", color:Theme.accentLarge)] }
            else { powerPart = [Segment(text:"电还剩 "), Segment(text:Theme.kwh(power) + " 度", color:Theme.accentLarge)] }
        }
        let cardPart = card.map { [Segment(text:"卡里还有 "), Segment(text:Theme.yuan($0), color:Theme.accentLarge)] } ?? []
        switch (powerPart.isEmpty, cardPart.isEmpty) {
        case (false, false): return powerPart + [Segment(text:"，\n")] + cardPart + [Segment(text:"。")]
        case (false, true): return powerPart + [Segment(text:"。")]
        case (true, false): return cardPart + [Segment(text:"。")]
        case (true, true): return [Segment(text:"还没读到电量和余额，下拉刷新一下。")]
        }
    }
    var heroLabel: String { hero.map(\.text).joined().replacingOccurrences(of:"\n", with:"") }
}

// MARK: - Live data

extension HomeData {
    @MainActor init(campus: CampusModel, water model: WaterModel, laundry: LaundryModel, now: Date = Date()) {
        signedIn = campus.configured
        dorm = Theme.dorm(campus.room)
        let snapshot = campus.snapshot
        powerBound = campus.powerConfigured
        remainingKWh = snapshot?.electricity?.remainingKWh
        yesterdayKWh = snapshot?.electricity?.yesterdayKWh
        balance = snapshot?.balance
        balanceUpdated = snapshot?.balanceFetchedAt

        let stage = model.stage
        if !model.configured { water = .unconfigured }
        else if let stage, stage.mayClose, let start = model.sessionStarted { water = model.busy ? .settling(start) : .showering(start) }
        else if model.busy && (stage == nil || stage == .settled) { water = .starting }
        else if let stage, stage != .settled {
            water = .unresolved(stage == .closeWritePending || stage == .settlementPending ? "上次结算还没确认" : stage.label)
        }
        else { water = .idle }
        if model.problem, water == .idle { waterIssue = model.status }
        var recents: [Recent] = []
        if stage == .settled, let start = model.sessionStarted, let end = model.lastEnded {
            let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
            lastShowerMinutes = minutes; lastShowerCost = model.lastCost
            recents.append(Recent(id:"water-\(start.timeIntervalSince1970)", emoji:"🚿", title:"热水 · \(minutes) 分钟",
                                  date:end, detail:nil, amount:model.lastCost))
        }

        laundryBound = laundry.configured
        if let device = laundry.snapshot { laundryMachine = device.deviceNo }
        if let order = laundry.checkout?.order, laundry.checkout?.stage != .completed, order.running,
           let seconds = order.remainTime, seconds > 0 {
            laundryValue = "还剩 \((seconds + 59) / 60) 分钟"
        } else if let device = laundry.snapshot { laundryValue = device.stateLabel }
        if let record = laundry.checkout {
            let machine = laundry.snapshot?.deviceId == record.deviceId ? laundry.snapshot?.deviceNo : nil
            recents.append(Recent(id:"laundry-\(record.orderId ?? record.createdAt.description)", emoji:"🧺",
                                  title:"洗衣 · " + record.programName, date:record.createdAt,
                                  detail:machine.map { "\($0) 号机" }, amount:record.order?.payPrice ?? record.expectedPrice))
        }
        self.recents = Array(recents.sorted { $0.date > $1.date }.prefix(4))
    }
}

/// Settlement result panel content.
enum SettlementResult: Equatable {
    case settled(minutes: Int?, amount: Decimal?)
    case unconfirmed
}

#if DEBUG
// MARK: - DEBUG demo data (campusdaily://demo/<state>); never compiled into Release.

enum HomeDemo: String, CaseIterable {
    case normal, low, empty, shower, settled, unconfirmed, off, settings
    case unconfirmedRow = "unconfirmed-row"

    static func handle(_ url: URL) -> (HomeData, SettlementResult?)?? {
        guard url.scheme == "campusdaily", url.host == "demo" else { return nil }
        let name = url.pathComponents.dropFirst().first ?? "normal"
        if name == "exit" { return .some(nil) }
        guard let demo = HomeDemo(rawValue:name) else { return nil }
        return .some(demo.content())
    }

    func content(now: Date = Date()) -> (HomeData, SettlementResult?) {
        let calendar = Calendar.current
        var data = HomeData()
        data.dorm = "3 栋 108"
        data.remainingKWh = Decimal(string:"42.6"); data.yesterdayKWh = Decimal(string:"4.6")
        data.balance = Decimal(string:"86.50"); data.balanceUpdated = now.addingTimeInterval(-25 * 60)
        data.lastShowerMinutes = 11; data.lastShowerCost = Decimal(string:"1.32")
        data.laundryBound = true; data.laundryMachine = "3"; data.laundryValue = "空闲"
        let yesterday = calendar.date(bySettingHour:22, minute:14, second:0, of:calendar.date(byAdding:.day, value:-1, to:now)!)!
        let twoDays = calendar.date(bySettingHour:19, minute:2, second:0, of:calendar.date(byAdding:.day, value:-2, to:now)!)!
        data.recents = [
            .init(id:"demo-water", emoji:"🚿", title:"热水 · 11 分钟", date:yesterday, detail:nil, amount:Decimal(string:"1.32")),
            .init(id:"demo-laundry", emoji:"🧺", title:"洗衣 · 标准洗", date:twoDays, detail:"3 号机", amount:Decimal(string:"4.00")),
        ]
        switch self {
        case .normal, .settings: return (data, nil)
        case .unconfirmedRow:
            data.water = .unresolved("上次结算还没确认")
            return (data, nil)
        case .low:
            // Runs out tomorrow evening, so the sentence reads 「明晚」.
            let target = calendar.date(bySettingHour:21, minute:0, second:0, of:calendar.date(byAdding:.day, value:1, to:now)!)!
            let days = target.timeIntervalSince(now) / 86400
            data.remainingKWh = Decimal(string:"4.8")
            data.yesterdayKWh = Decimal(4.8 / days)
            data.laundryValue = "还剩 18 分钟"
            return (data, nil)
        case .empty:
            var empty = HomeData(); empty.signedIn = false; empty.dorm = "3 栋 108"
            return (empty, nil)
        case .shower:
            data.water = .showering(now.addingTimeInterval(-(8 * 60 + 42)))
            return (data, nil)
        case .settled:
            data.recents.insert(.init(id:"demo-new", emoji:"🚿", title:"热水 · 11 分钟", date:now, detail:nil, amount:Decimal(string:"1.32")), at:0)
            return (data, .settled(minutes:11, amount:Decimal(string:"1.32")))
        case .unconfirmed:
            return (data, .unconfirmed)
        case .off:
            data.water = .unconfigured
            return (data, nil)
        }
    }
}

/// campusdaily://demo/onboard/{1,2,2-missing,3,done}
enum OnboardingDemo {
    static func handle(_ url: URL) -> (OnboardingView.Step, OnboardingView.Preview)? {
        let parts = Array(url.pathComponents.dropFirst())
        guard url.scheme == "campusdaily", url.host == "demo", parts.first == "onboard" else { return nil }
        var preview = OnboardingView.Preview(dorm:"3 栋 108")
        switch parts.count > 1 ? parts[1] : "1" {
        case "2": return (.dorm, preview)
        case "2-missing": preview.dorm = nil; return (.dorm, preview)
        case "3": return (.washer, preview)
        case "done": return (.done, preview)
        default: return (.login, preview)
        }
    }
}
#endif
