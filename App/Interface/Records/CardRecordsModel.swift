import Foundation
import Core

/// Where 校园卡记录 reads its pages: the school session, or synthetic pages in a demo.
struct CardRecordsSource: Sendable {
    /// Who is signed in now (`SchoolSession.personStamp()`).
    var stamp: @Sendable () async -> Int
    var page: @Sendable (CardHistoryQuery, Int) async throws -> CardRecordPage

    @MainActor static var live: CardRecordsSource {
        let session = AppEnvironment.school
        return CardRecordsSource(stamp:{ await session.personStamp() },
                                 page:{ query, stamp in try await session.cardHistoryPage(query, since:stamp) })
    }
}

/// 校园卡记录's state: the records read so far (`CardHistory`), and what the page shows
/// around them. Nothing is stored: every visit (and every pull) starts from today.
@MainActor final class CardRecordsModel: ObservableObject {
    enum Phase: Equatable {
        /// The first read is running and nothing is shown yet.
        case loading
        /// The first read failed: the line, and the app's own records only.
        case failed
        case loaded
    }
    @Published private(set) var phase = Phase.loading
    @Published private(set) var history: CardHistory?
    @Published private(set) var loadingMore = false
    /// The last 「load more」 failed: the footer offers to try again. The rows stay.
    @Published private(set) var moreFailed = false
    private let source: CardRecordsSource
    private var stamp = 0
    /// Bumped by `reload()`: a load that returns afterwards is dropped.
    private var generation = 0

    init(source: CardRecordsSource) { self.source = source }

    /// From today again (first visit, pull).
    func reload() async {
        generation += 1
        let mine = generation
        loadingMore = false
        let stamp = await source.stamp()
        let load = await Self.load(CardHistory(now:Date()), source:source, stamp:stamp)
        guard mine == generation else { return }
        self.stamp = stamp
        if load.history.records.isEmpty, load.failure != nil {
            history = nil; phase = .failed; moreFailed = false
        } else {
            history = load.history; phase = .loaded; moreFailed = load.failure != nil
        }
    }

    /// Older records: when the list's end appears, or 「点这里再试」.
    func loadMore() async {
        guard phase == .loaded, !loadingMore, let current = history, !current.reachedEnd else { return }
        let mine = generation
        loadingMore = true; moreFailed = false
        let load = await Self.load(current, source:source, stamp:stamp)
        guard mine == generation else { return }
        history = load.history
        moreFailed = load.failure != nil
        loadingMore = false
    }

    private nonisolated static func load(_ history: CardHistory, source: CardRecordsSource, stamp: Int) async -> CardHistory.Load {
        let page = source.page
        return await CardHistory.loadMore(history) { query in try await page(query, stamp) }
    }
}
