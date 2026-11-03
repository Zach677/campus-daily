import Foundation

/// The status line of 清爽 home's 热水 tile: the words 暖橙's home shower button and its caption
/// use for the same state, and how the tile behaves.
public struct ShowerTileStatus: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case secondary, notice, accent }

    public var text: String
    public var tone: Tone
    /// Showering: a running mm:ss follows the text, counted from here.
    public var timerStart: Date?
    /// Hot water can't be used here (not set up, not available): the tile is dimmed but still
    /// opens its page.
    public var dimmed = false
    /// Signed out: the tile opens the first-run checklist instead of the page.
    public var opensSetup = false

    public init(text: String, tone: Tone = .secondary, timerStart: Date? = nil, dimmed: Bool = false, opensSetup: Bool = false) {
        self.text = text; self.tone = tone; self.timerStart = timerStart; self.dimmed = dimmed; self.opensSetup = opensSetup
    }

    /// `issue`: the last start's problem (shown instead of the last shower).
    public static func of(_ status: ShowerHomeStatus, signedIn: Bool, lastMinutes: Int?, lastCost: Decimal?,
                          issue: String?) -> ShowerTileStatus {
        if status.asksForSchoolSignIn(signedIn: signedIn) { return ShowerTileStatus(text: "登录学校账号", opensSetup: true) }
        switch status {
        case .unconfigured: return ShowerTileStatus(text: "先在设置里选好宿舍", dimmed: true)
        case .unavailable(let reason): return ShowerTileStatus(text: reason, dimmed: true)
        case .idle:
            if let issue { return ShowerTileStatus(text: issue) }
            guard let lastMinutes else { return ShowerTileStatus(text: "") }
            let cost = lastCost.map { " · " + Money(yuan: $0).description } ?? ""
            return ShowerTileStatus(text: "上次 \(lastMinutes) 分钟" + cost)
        case .starting: return ShowerTileStatus(text: "正在连接水控…")
        case .showering(let start): return ShowerTileStatus(text: "正在洗澡", tone: .accent, timerStart: start)
        case .settling: return ShowerTileStatus(text: "正在结算…")
        case .unresolved(let review): return ShowerTileStatus(text: review.caption, tone: .notice)
        case .needsCheck: return ShowerTileStatus(text: "核对上次洗澡", tone: .notice)
        }
    }
}
