import Foundation
import SwiftUI
import Core

/// Everything the home screen shows, derived from the models (or DEBUG demo data).
struct HomeData {
    enum Shower: Equatable {
        case unconfigured
        /// Hot water can't be used in this build or at this school (no start); the reason is the subtitle.
        case unavailable(String)
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
    /// Home 🧺 row (Camo r2 home-row table).
    enum Laundry: Equatable {
        case unknown, idle, unpaid, starting, done, inUse, unresolved
        case running(program: String, end: Date)
        case unavailable(LaundryFacts.Unavailable)
        var subtitle: String {
            switch self {
            case .unknown, .idle: return "常用"
            case .unpaid: return "订单还没付款"
            case .starting: return "已付款，等机器启动"
            case .running(let program, let end): return program + " · " + LaundryFormat.clock(end) + " 洗完"
            case .done: return "刚刚洗完"
            case .inUse: return "有人在用"
            case .unavailable(.offline): return "机器离线"
            case .unavailable(.broken): return "机器故障"
            case .unavailable(.disabled): return "机器停用"
            case .unresolved: return "上次订单还没确认"
            }
        }
        var value: RowValue? {
            switch self {
            case .unknown, .unavailable: return nil
            case .idle: return .word("空闲")
            case .unpaid: return .word("待付款")
            case .starting: return .word("启动中")
            case .running(_, let end): return .countdown(end:end)
            case .done: return .word("洗好了")
            case .inUse: return .word("使用中")
            case .unresolved: return .accentWord("待核对")
            }
        }
        /// VoiceOver words for the trailing value.
        func spokenValue(now: Date = Date()) -> String? {
            switch value {
            case .word(let word)?, .accentWord(let word)?: return word
            case .countdown(let end)?: return "还剩 \(LaundryFormat.minutesLeft(until:end, now:now)) 分钟"
            default: return nil
            }
        }
    }
    struct LaundryDone: Equatable {
        let id: String
        let amount: Decimal?
        let detail: String
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
    /// Settings › 学校账号 (nil after a web sign-in).
    var schoolAccount: SchoolAccount?
    var passwordSaved: Bool { schoolAccount?.password != nil }
    /// DEBUG demo only: why Settings › 高级 › 重置校日常 is locked (the live value comes from the shower).
    var resetLock: AppReset.Lock?
    var dorm: String?
    var powerBound = true
    var remainingKWh: Decimal?
    var yesterdayKWh: Decimal?
    var balance: Decimal?
    var balanceUpdated: Date?
    /// Last campus refresh problem (e.g. login expired); the balance shown is then the old one.
    var campusIssue: String?
    /// Last power read failed; the kWh shown (if any) is the previous reading.
    var powerIssue: String?
    var cardLowLine: Decimal = 20
    var powerLowLine: Decimal = 10
    var water = Shower.idle
    var waterIssue: String?
    /// Showering, but the device never confirmed the authorization write (adds one line under the timer).
    var showerUnconfirmed = false
    var lastShowerMinutes: Int?
    var lastShowerCost: Decimal?
    /// 「学校洗衣机」 on. Off: no laundry row, recent, scan button or done panel.
    var laundryEnabled = true
    /// The 学校洗衣机 switch can't be turned off yet (an order is unfinished).
    var laundryLocked = false
    var laundryBound = false
    var laundryMachine: String?
    var laundry = Laundry.unknown
    /// A recently finished order, for the once-per-order done panel.
    var laundryDone: LaundryDone?
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
        return remainingKWh < powerLowLine || (daysLeft ?? 99) <= 1
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
    @MainActor init(campus: CampusModel, water model: ShowerModel, laundry: LaundryModel, now: Date = Date()) {
        signedIn = campus.configured
        schoolAccount = campus.account
        dorm = Theme.dorm(campus.room)
        let snapshot = campus.snapshot
        powerBound = campus.powerConfigured
        remainingKWh = snapshot.power.value?.remainingKWh
        yesterdayKWh = snapshot.power.value?.dailyUseKWh
        balance = snapshot.card.value?.yuan
        balanceUpdated = snapshot.card.fetchedAt
        campusIssue = campus.configured ? campus.issue : nil
        powerIssue = campus.configured && powerBound ? snapshot.power.error?.userMessage : nil
        let lines = ReminderKey.lines
        powerLowLine = lines.power; cardLowLine = lines.card

        let state = model.state
        if !model.configured { water = .unconfigured }
        else if state.canFinish, let start = model.sessionStarted { water = model.busy ? .settling(start) : .showering(start) }
        else if let start = state.startedAt, state.phase == .closing || state.phase == .settling { water = .settling(start) }
        else if state.phase == .authorizing || (model.busy && (state.phase == .idle || state.phase == .done)) { water = .starting }
        else if state.phase == .failed, state.failure?.needsReview == true {
            water = .unresolved(model.unresolvedClose ? "上次结算还没确认" : ShowerDisplay.failureTitle(state.failure))
        }
        else if model.platformMissing { water = .unavailable(ShowerModel.platformMissingText) }
        else { water = .idle }
        if model.problem, water == .idle { waterIssue = model.status }
        showerUnconfirmed = state.phase == .writePending && water.showering != nil
        var recents: [Recent] = []
        if state.phase == .done, let start = model.sessionStarted, let end = model.lastEnded {
            let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
            lastShowerMinutes = minutes; lastShowerCost = model.lastCost
            recents.append(Recent(id:"water-\(start.timeIntervalSince1970)", emoji:"🚿", title:"热水 · \(minutes) 分钟",
                                  date:end, detail:nil, amount:model.lastCost))
        }

        laundryEnabled = laundry.schoolEnabled
        laundryLocked = laundry.schoolSwitchLocked
        laundryBound = laundry.configured
        if let device = laundry.snapshot { laundryMachine = device.deviceNo }
        let facts = LaundryFacts(model:laundry)
        self.laundry = Self.laundryRow(facts, now:now)
        laundryDone = laundryEnabled ? Self.laundryDone(facts, now:now) : nil
        if laundryEnabled, let record = laundry.checkout, record.inFlight, let created = record.createdAt {
            recents.append(Recent(id:"laundry-\(record.orderId ?? created.description)", emoji:"🧺",
                                  title:"洗衣 · " + record.programName, date:created,
                                  detail:record.draft.map { "\($0.machineName) 号机" }, amount:facts.amount))
        }
        self.recents = Array(recents.sorted { $0.date > $1.date }.prefix(4))
    }
}

extension HomeData {
    static func laundryRow(_ facts: LaundryFacts, now: Date = Date()) -> Laundry {
        switch facts.phase(now:now) {
        case .empty, .unknown: return .unknown
        case .idle: return .idle
        case .inUse: return .inUse
        case .unavailable(let kind): return .unavailable(kind)
        case .unpaid(let payable): return payable ? .unpaid : .unresolved
        case .starting: return .starting
        case .running(let end): return .running(program:facts.record?.programName ?? "洗衣", end:end)
        case .check: return .unresolved
        case .done: return .done
        }
    }
    static func laundryDone(_ facts: LaundryFacts, now: Date = Date()) -> LaundryDone? {
        guard let id = facts.doneOrderID(now:now), let record = facts.record else { return nil }
        let program = facts.recordProgram.map(LaundryFormat.program) ?? record.programName
        return LaundryDone(id:id, amount:facts.amount,
                           detail:[program, facts.machine.map(LaundryFormat.machine)].compactMap { $0 }.joined(separator:" · "))
    }
}

/// Settlement result panel content.
enum SettlementResult: Equatable {
    case settled(minutes: Int?, amount: Decimal?)
    case unconfirmed
    /// Laundry order 50 (r2 §1.7): 「衣服洗好了」 · amount · 「标准洗 · 45 分钟 · 3 号机」.
    case laundryDone(amount: Decimal?, detail: String)
}

#if DEBUG
// MARK: - DEBUG demo data (campusdaily://demo/<state>); never compiled into Release.

enum HomeDemo: String, CaseIterable {
    case normal, low, empty, shower, settled, unconfirmed, off, settings
    /// 学校洗衣机 off: home without laundry / settings with the switch off / switch locked by an order.
    case laundryOff = "home-laundry-off"
    case settingsLaundryOff = "settings-laundry-off"
    case settingsLaundryLocked = "settings-laundry-locked"
    case settingsOff = "settings-notif-off"
    case settingsAsk = "settings-ask"
    /// Settings › 学校账号 with the password saved (synthetic account and password).
    case settingsPassword = "settings-password-on"
    /// Settings › 学校账号 with automatic sign-in paused: password refused / login got no answer.
    case settingsPaused = "settings-paused"
    case settingsPausedNoAnswer = "settings-paused-noanswer"
    /// Settings › 高级 › 重置校日常 locked: showering / a settlement to check.
    case settingsResetShower = "settings-reset-shower"
    case settingsResetUnsure = "settings-reset-unsure"
    case settingsResetLaundry = "settings-reset-laundry"
    case unconfirmedRow = "unconfirmed-row"
    /// Showering while the authorization write is unconfirmed (stage .authorizationWritePending).
    case showerUnconfirmed = "shower-unconfirmed"
    case laundryRun = "home-laundry-run"
    case laundryCheck = "home-laundry-check"
    /// Hot-water row when the build has no bundled platform profile (OnboardingError.platform).
    case noPlatform = "no-platform"
    /// Hot-water row when the service says this school isn't open (transactions_not_enabled).
    case notOpen = "not-open"

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
        data.schoolAccount = SchoolAccount(account:"99100991")
        data.remainingKWh = Decimal(string:"42.6"); data.yesterdayKWh = Decimal(string:"4.6")
        data.balance = Decimal(string:"86.50"); data.balanceUpdated = now.addingTimeInterval(-25 * 60)
        data.lastShowerMinutes = 11; data.lastShowerCost = Decimal(string:"1.32")
        data.laundryBound = true; data.laundryMachine = "3"; data.laundry = .idle
        let yesterday = calendar.date(bySettingHour:22, minute:14, second:0, of:calendar.date(byAdding:.day, value:-1, to:now)!)!
        let twoDays = calendar.date(bySettingHour:19, minute:2, second:0, of:calendar.date(byAdding:.day, value:-2, to:now)!)!
        data.recents = [
            .init(id:"demo-water", emoji:"🚿", title:"热水 · 11 分钟", date:yesterday, detail:nil, amount:Decimal(string:"1.32")),
            .init(id:"demo-laundry", emoji:"🧺", title:"洗衣 · 标准洗", date:twoDays, detail:"3 号机", amount:Decimal(string:"4.00")),
        ]
        switch self {
        case .normal, .settings, .settingsOff, .settingsAsk: return (data, nil)
        case .settingsResetShower:
            data.water = .showering(now.addingTimeInterval(-(8 * 60 + 42)))
            data.resetLock = .showering
            return (data, nil)
        case .settingsResetUnsure:
            data.water = .unresolved("上次结算还没确认")
            data.resetLock = .unsettled
            return (data, nil)
        case .settingsResetLaundry:
            data.resetLock = .laundry
            return (data, nil)
        case .settingsPassword:
            data.schoolAccount = SchoolAccount(account:"99100991", password:"demo-password")
            return (data, nil)
        case .settingsPaused:
            data.schoolAccount = SchoolAccount(account:"99100991", password:"demo-password", paused:true)
            return (data, nil)
        case .settingsPausedNoAnswer:
            data.schoolAccount = SchoolAccount(account:"99100991", password:"demo-password", unansweredAt:now)
            return (data, nil)
        case .laundryOff, .settingsLaundryOff:
            data.laundryEnabled = false
            data.recents.removeAll { $0.emoji == "🧺" }
            return (data, nil)
        case .settingsLaundryLocked:
            data.laundryLocked = true
            data.laundry = .running(program:"标准洗", end:now.addingTimeInterval(18 * 60 - 30))
            return (data, nil)
        case .laundryRun:
            data.laundry = .running(program:"标准洗", end:now.addingTimeInterval(18 * 60 - 30))
            return (data, nil)
        case .laundryCheck:
            data.laundry = .unresolved
            return (data, nil)
        case .unconfirmedRow:
            data.water = .unresolved("上次结算还没确认")
            return (data, nil)
        case .low:
            // Runs out tomorrow evening, so the sentence reads 「明晚」.
            let target = calendar.date(bySettingHour:21, minute:0, second:0, of:calendar.date(byAdding:.day, value:1, to:now)!)!
            let days = target.timeIntervalSince(now) / 86400
            data.remainingKWh = Decimal(string:"4.8")
            data.yesterdayKWh = Decimal(4.8 / days)
            data.laundry = .running(program:"标准洗", end:now.addingTimeInterval(18 * 60 - 30))
            return (data, nil)
        case .empty:
            var empty = HomeData(); empty.signedIn = false; empty.dorm = "3 栋 108"
            return (empty, nil)
        case .shower:
            data.water = .showering(now.addingTimeInterval(-(8 * 60 + 42)))
            return (data, nil)
        case .showerUnconfirmed:
            data.water = .showering(now.addingTimeInterval(-(8 * 60 + 42)))
            data.showerUnconfirmed = true
            return (data, nil)
        case .settled:
            data.recents.insert(.init(id:"demo-new", emoji:"🚿", title:"热水 · 11 分钟", date:now, detail:nil, amount:Decimal(string:"1.32")), at:0)
            return (data, .settled(minutes:11, amount:Decimal(string:"1.32")))
        case .unconfirmed:
            return (data, .unconfirmed)
        case .off:
            data.water = .unconfigured
            return (data, nil)
        case .noPlatform:
            // Live path: ShowerModel.platformMissing (direct dorm saved, no bundled platform profile).
            data.water = .unavailable(ShowerModel.platformMissingText)
            return (data, nil)
        case .notOpen:
            data.water = .unavailable("本校暂未开放")
            return (data, nil)
        }
    }
}

/// campusdaily://demo/onboard/{1,1-filled,1-loading,1-wrong,1-fallback,2,2-missing,2-samename,3,done}
/// The login states use a synthetic account; tapping 登录 only moves to the next step.
enum OnboardingDemo {
    static func handle(_ url: URL) -> (OnboardingView.Step, OnboardingView.Preview)? {
        let parts = Array(url.pathComponents.dropFirst())
        guard url.scheme == "campusdaily", url.host == "demo", parts.first == "onboard" else { return nil }
        var preview = OnboardingView.Preview(dorm:"3 栋 108")
        switch parts.count > 1 ? parts[1] : "1" {
        case "2": return (.dorm, preview)
        case "2-missing": preview.dorm = nil; return (.dorm, preview)
        case "2-samename":
            // Upstream 0.8.0-beta.2 same-name building picker, with sample directory labels.
            preview.powerChoices = ["半山公寓 · 3 栋", "兰香公寓 · 3 栋"]
            return (.dorm, preview)
        case "1-filled", "1-loading", "1-wrong", "1-fallback":
            preview.account = "99100991"
            preview.password = parts[1] == "1-wrong" ? "" : "demo-password"
            preview.savePassword = parts[1] != "1-wrong"
            preview.loginState = ["1-loading":.loading, "1-wrong":.wrong, "1-fallback":.cannotDirect][parts[1]] ?? .idle
            return (.login, preview)
        case "3": return (.washer, preview)
        case "done": return (.done, preview)
        default: return (.login, preview)
        }
    }
}
#endif
