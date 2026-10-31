import Foundation

/// The lookup stopped with rooms of the dorm's name in several apartments (or campuses): the
/// question asked in onboarding's 「你住哪间」 step and on the meter page, one row per room.
public struct MeterQuestion: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var candidate: MeterCandidate
        /// The apartment (or campus) the room lies under, 「半山公寓」.
        public var title: String
        public var id: String { candidate.id }
        /// 「星湖校区 · 半山公寓 · 3 栋 · 108」.
        public var location: String { candidate.location }
        /// VoiceOver: 「半山公寓，星湖校区 半山公寓 3 栋 108」.
        public var spoken: String { title + "，" + location.replacingOccurrences(of: " · ", with: " ") }
    }

    /// 「2 个公寓都有 3 栋 108，你住哪个？」.
    public var text: String
    public var rows: [Row]

    /// nil for a stop without rooms to choose from, or without the dorm.
    public init?(_ stop: MeterWalkStop, address: DormAddress?) {
        guard let text = MeterPageText.question(stop, address: address) else { return nil }
        self.text = text
        rows = stop.candidates.map { Row(candidate: $0, title: stop.branchName($0)) }
    }
}

/// What onboarding's 「你住哪间」 step says about the meter under the dorm.
public enum DormStepMeter: Sendable, Equatable {
    /// Nothing: bound, a plain stop (home says 「还没找到电表」), or no lookup.
    case hidden
    /// 「正在找电表…」 with a spinner.
    case finding
    /// The apartments to choose from; a tap binds.
    case ask(MeterQuestion)
    /// The lookup failed (the page's words), with 「再找一次电表」 and `skipNote`.
    case failed(String)

    public static let retry = "再找一次电表"
    public static let skipNote = "电表先跳过，之后在设置 › 电表里选。"

    public var text: String? {
        switch self {
        case .hidden: return nil
        case .finding: return MeterPageText.finding
        case .ask(let q): return q.text
        case .failed(let text): return text
        }
    }

    /// `running`: the lookup runs (again); `bound`: a meter is bound; `stop` and `issue`: what
    /// the last lookup left.
    public init(running: Bool, bound: Bool, stop: MeterWalkStop?, issue: String?, address: DormAddress?) {
        if running { self = .finding; return }
        guard !bound else { self = .hidden; return }
        if let stop, let q = MeterQuestion(stop, address: address) { self = .ask(q); return }
        if let issue, issue != MeterPageText.stoppedIssue { self = .failed(MeterPageText.issue(issue)); return }
        self = .hidden
    }
}
