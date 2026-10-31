import XCTest
@testable import Core
import CoreTestSupport

/// 校园卡记录: paging back from today by whole days, which days are complete, the day totals and
/// the rows of each day.
final class CardHistoryTests: XCTestCase {
    let cal = SchoolCalendar.shanghai
    /// 2026-10-30 12:00 in Shanghai.
    var noon: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))! }

    func record(_ date: String, _ time: String, _ title: String = "POS消费示例面馆", _ yuan: String = "12.00",
                flag: String? = "1", balance: String? = nil) -> CardRecord {
        CardRecord(date: date, time: time, title: title, amount: Money(yuanString: yuan)!,
                   balanceAfter: balance.flatMap(Money.init(yuanString:)), direction: flag)
    }

    func moment(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// `n` distinct canteen records on `day`, newest first.
    func meals(_ day: String, _ n: Int, from hour: Int = 20) -> [CardRecord] {
        (0..<n).map { i in record(day, String(format: "%02d%02d00", hour - i / 60, 59 - i % 60), balance: String(100 + n - i)) }
    }

    // MARK: Paging by date range

    func testPagesGoBackFromTodayInWholeDayRanges() {
        var history = CardHistory(now: noon)
        let first = history.nextQuery
        XCTAssertEqual(first, CardHistoryQuery(begin: "20261017", end: "20261030", page: 1, pageSize: CardHistory.pageSize))
        history.receive(CardRecordPage(total: 2, rows: [record("20261030", "113000"), record("20261028", "120000")]), for: first!)
        XCTAssertEqual(history.nextQuery, CardHistoryQuery(begin: "20261003", end: "20261016", page: 1, pageSize: CardHistory.pageSize),
                       "the next range ends the day before the last one began")
        XCTAssertTrue(history.isComplete(day: "20261030"))
        XCTAssertTrue(history.isComplete(day: "20261017"))
        XCTAssertFalse(history.isComplete(day: "20261016"), "not read yet")
        XCTAssertEqual(history.records.count, 2)
        XCTAssertFalse(history.reachedEnd)
    }

    func testTheSchoolsDayDecidesTodayWhateverThePhonesZone() {
        // 00:30 on the 31st in Shanghai is still the 30th in most of the world.
        let lateNight = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 0, minute: 30))!
        XCTAssertEqual(CardHistory(now: lateNight).nextQuery?.end, "20261031")
        var history = CardHistory(now: lateNight)
        history.receive(CardRecordPage(total: 1, rows: [record("20261030", "233000")]), for: history.nextQuery!)
        let days = CardDays.groups(history: history, app: [], now: lateNight)
        XCTAssertEqual(days.map(\.title), ["昨天"])
        XCTAssertEqual(days.first?.items.first.map { CardDays.clock($0.date) }, "23:30")
    }

    /// The school pages by count inside a range: a day cut by the page boundary is incomplete
    /// until the next page of the same range has come.
    func testADayCutByThePageBoundaryIsCompletedByTheNextPage() {
        var history = CardHistory(now: noon)
        let rows = meals("20261030", 30) + meals("20261029", 25)
        let first = history.nextQuery!
        history.receive(CardRecordPage(total: 55, rows: Array(rows.prefix(50))), for: first)
        XCTAssertEqual(history.nextQuery, CardHistoryQuery(begin: first.begin, end: first.end, page: 2, pageSize: CardHistory.pageSize))
        XCTAssertTrue(history.isComplete(day: "20261030"), "newer than the cut")
        XCTAssertFalse(history.isComplete(day: "20261029"), "the cut day")
        XCTAssertFalse(history.isComplete(day: "20261028"))
        var groups = CardDays.groups(history: history, app: [], now: noon)
        XCTAssertNotNil(groups[0].total)
        XCTAssertNil(groups[1].total, "no 花了 for the cut day")
        XCTAssertEqual(groups[1].items.count, 20, "its rows so far are shown")

        history.receive(CardRecordPage(total: 55, rows: Array(rows.suffix(5))), for: history.nextQuery!)
        XCTAssertTrue(history.isComplete(day: "20261029"))
        XCTAssertTrue(history.isComplete(day: "20261017"))
        XCTAssertEqual(history.nextQuery?.page, 1)
        XCTAssertEqual(history.nextQuery?.end, "20261016")
        groups = CardDays.groups(history: history, app: [], now: noon)
        XCTAssertEqual(groups[1].items.count, 25)
        XCTAssertEqual(groups[1].total, Money(fen: 25 * 1200))
    }

    func testARecordRepeatedOnTheNextPageIsShownOnce() {
        var history = CardHistory(now: noon)
        let rows = meals("20261030", 51)
        history.receive(CardRecordPage(total: 51, rows: Array(rows.prefix(50))), for: history.nextQuery!)
        // A new record at the top pushed the 50th onto page 2.
        history.receive(CardRecordPage(total: 52, rows: [rows[49], rows[50]]), for: history.nextQuery!)
        XCTAssertEqual(history.records.count, 51)
    }

    func testAServerThatRepeatsTheSamePageEndsThatRangeWithoutATotalForTheCutDay() {
        var history = CardHistory(now: noon)
        let page = CardRecordPage(total: 200, rows: meals("20261030", 30) + meals("20261029", 20))
        history.receive(page, for: history.nextQuery!)
        history.receive(page, for: history.nextQuery!)
        XCTAssertEqual(history.nextQuery?.end, "20261016", "moved on instead of asking for page 3, 4 …")
        XCTAssertTrue(history.isComplete(day: "20261030"))
        XCTAssertFalse(history.isComplete(day: "20261029"))
        XCTAssertFalse(history.isComplete(day: "20261020"), "older days of that range may be missing too")
    }

    func testAnswersToAnOldQueryAreIgnored() {
        var history = CardHistory(now: noon)
        let first = history.nextQuery!
        history.receive(CardRecordPage(total: 0, rows: []), for: first)
        history.receive(CardRecordPage(total: 1, rows: [record("20261030", "113000")]), for: first)
        XCTAssertTrue(history.records.isEmpty)
    }

    func testEmptyRangesAreSkippedInOneLoadAndManyOfThemEndTheList() async {
        let calls = Box<[CardHistoryQuery]>([])
        let old = CardHistory(now: noon)
        let load = await CardHistory.loadMore(old) { query in
            calls.value.append(query)
            return query.end == "20260918" ? CardRecordPage(total: 1, rows: [self.record("20260915", "120000")])
                                           : CardRecordPage(total: 0, rows: [])
        }
        XCTAssertNil(load.failure)
        XCTAssertEqual(calls.value.map(\.end), ["20261030", "20261016", "20261002", "20260918"])
        XCTAssertEqual(load.history.records.count, 1, "one load runs until it has something to show")

        calls.value = []
        let empty = await CardHistory.loadMore(load.history) { query in
            calls.value.append(query)
            return CardRecordPage(total: 0, rows: [])
        }
        XCTAssertEqual(calls.value.count, CardHistory.emptyRangesBeforeEnd, "this many empty ranges in a row end the list")
        XCTAssertTrue(empty.history.reachedEnd)
        XCTAssertNil(empty.history.nextQuery)
        XCTAssertEqual(empty.history.records.count, 1)
    }

    func testAFailedPageKeepsTheRowsAndIsAskedForAgain() async {
        let first = await CardHistory.loadMore(CardHistory(now: noon)) { _ in
            CardRecordPage(total: 1, rows: [self.record("20261030", "113000")])
        }
        let pending = first.history.nextQuery
        let failed = await CardHistory.loadMore(first.history) { _ in throw ServiceError.offline }
        XCTAssertEqual(failed.failure, .offline)
        XCTAssertEqual(failed.history.records.count, 1, "rows stay")
        XCTAssertEqual(failed.history.nextQuery, pending, "the same page again")
        let retried = await CardHistory.loadMore(failed.history) { query in
            XCTAssertEqual(query, pending)
            return CardRecordPage(total: 1, rows: [self.record("20261010", "090000")])
        }
        XCTAssertNil(retried.failure)
        XCTAssertEqual(retried.history.records.count, 2)
    }

    /// A short page while the total says more: the range goes on, and if the rest never comes
    /// its days from the cut back stay without a total.
    func testAShortPageIsNotTheLastWhileTheTotalSaysMore() {
        var history = CardHistory(now: noon)
        let first = history.nextQuery!
        history.receive(CardRecordPage(total: 55, rows: meals("20261030", 12) + meals("20261029", 8)), for: first)
        XCTAssertEqual(history.nextQuery, CardHistoryQuery(begin: first.begin, end: first.end, page: 2, pageSize: CardHistory.pageSize),
                       "35 more records in this range")
        XCTAssertFalse(history.isComplete(day: "20261029"))

        history.receive(CardRecordPage(total: 55, rows: []), for: history.nextQuery!)
        XCTAssertEqual(history.nextQuery?.end, "20261016")
        XCTAssertTrue(history.isComplete(day: "20261030"), "newer than the cut")
        XCTAssertFalse(history.isComplete(day: "20261029"), "the school said there was more")
        XCTAssertFalse(history.isComplete(day: "20261017"))
        let groups = CardDays.groups(history: history, app: [], now: noon)
        XCTAssertNil(groups[1].total)
    }

    // MARK: Day totals

    func testADayTotalCountsMoneyOutOnly() {
        var history = CardHistory(now: noon)
        history.receive(CardRecordPage(total: 4, rows: [
            record("20261030", "113000", "POS消费示例面馆", "12.00"),
            record("20261030", "080000", "校园卡充值", "50.00", flag: nil),
            record("20261030", "074200", "POS消费示例早餐铺", "4.50"),
            record("20261029", "130500", "校园卡充值", "50.00", flag: nil),
        ]), for: history.nextQuery!)
        let days = CardDays.groups(history: history, app: [], now: noon)
        XCTAssertEqual(days.map(\.title), ["今天", "昨天"])
        XCTAssertEqual(days[0].total, Money(fen: 1650), "top-ups are not in it")
        XCTAssertEqual(days[0].totalText, "花了 ¥16.50")
        XCTAssertEqual(days[0].spokenTitle, "今天，花了 16.50 元")
        XCTAssertNil(days[1].total, "a day of top-ups only has no 花了")
        XCTAssertNil(days[1].totalText)
        XCTAssertEqual(days[1].spokenTitle, "昨天")
        XCTAssertEqual(days[1].items.first?.amountText, "+¥50.00")
    }

    func testARecordThatMayBeInOrOutLeavesItsDayWithoutATotal() {
        var history = CardHistory(now: noon)
        history.receive(CardRecordPage(total: 2, rows: [
            record("20261030", "113000"), record("20261030", "080000", "示例超市", "3.00", flag: "2"),
        ]), for: history.nextQuery!)
        XCTAssertNil(CardDays.groups(history: history, app: [], now: noon)[0].total)
    }

    func testOnlyTheAppsOwnRecordsAfterAFailedReadHaveNoTotals() {
        let app = [
            AppActivity(id: "s1", kind: .shower(minutes: 11), date: moment(10, 30, 7, 58), amount: Money(fen: 132)),
            AppActivity(id: "l1", kind: .laundry(program: "标准洗"), date: moment(10, 28, 9, 30), amount: Money(fen: 450)),
        ]
        let days = CardDays.groups(history: nil, app: app, now: noon)
        XCTAssertEqual(days.map(\.title), ["今天", "10月28日 周三"])
        XCTAssertEqual(days.map(\.items.count), [1, 1])
        XCTAssertTrue(days.allSatisfy { $0.total == nil && $0.totalText == nil })
        XCTAssertEqual(days[0].items[0].title, "热水 · 11 分钟")
    }

    // MARK: Rows

    func testHotWaterAndLaundryTakeTheAppsMinutesAndProgramAsOnHome() {
        var history = CardHistory(now: noon)
        history.receive(CardRecordPage(total: 3, rows: [
            record("20261030", "075900", "蓝牙热水(中卡)", "1.32"),
            record("20261029", "093000", "示例洗衣机", "4.50"),
            record("20261029", "070000", "蓝牙热水(中卡)", "0.90"),
        ]), for: history.nextQuery!)
        let app = [
            AppActivity(id: "s1", kind: .shower(minutes: 11), date: moment(10, 30, 7, 58), amount: Money(fen: 132)),
            AppActivity(id: "l1", kind: .laundry(program: "标准洗"), date: moment(10, 29, 9, 29), amount: nil),
            // Older than anything read yet: it waits for its day.
            AppActivity(id: "s0", kind: .shower(minutes: 9), date: moment(9, 1, 7, 0), amount: Money(fen: 100)),
        ]
        let days = CardDays.groups(history: history, app: app, now: noon)
        XCTAssertEqual(days.map(\.id), ["20261030", "20261029"])
        XCTAssertEqual(days[0].items.map(\.title), ["热水 · 11 分钟"])
        XCTAssertEqual(days[1].items.map(\.title), ["洗衣 · 标准洗", "热水"], "the app no longer has that shower: plain 热水")
        XCTAssertEqual(days[1].items[0].amount, Money(fen: 450), "the school's amount")
        XCTAssertEqual(days[1].total, Money(fen: 540))
    }

    func testDayTitlesGiveTheYearOnlyOutsideTheCurrentOne() {
        let jan = cal.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12))!
        var history = CardHistory(now: jan)
        history.receive(CardRecordPage(total: 3, rows: [
            record("20260102", "100000"), record("20251231", "100000"), record("20251230", "100000"),
        ]), for: history.nextQuery!)
        XCTAssertEqual(CardDays.groups(history: history, app: [], now: jan).map(\.title),
                       ["今天", "2025年12月31日 周三", "2025年12月30日 周二"])
        XCTAssertEqual(CardDays.title(day: moment(10, 28, 0), now: noon), "10月28日 周三")
        XCTAssertEqual(CardDays.title(day: moment(10, 29, 0), now: noon), "昨天")
    }

    func testNothingReadAndNothingLocalIsEmpty() async {
        let load = await CardHistory.loadMore(CardHistory(now: noon)) { _ in CardRecordPage(total: 0, rows: []) }
        XCTAssertTrue(load.history.reachedEnd)
        XCTAssertTrue(CardDays.groups(history: load.history, app: [], now: noon).isEmpty)
    }
}

/// The read behind the page: the stored card session as is, nothing minted or written.
final class CardHistoryReadTests: XCTestCase {
    func testAPageIsReadWithTheStoredSessionAndNothingElse() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/card-getRecordList-ok")
        let before = try h.vault.ecyktSession()
        let session = h.session()
        let stamp = await session.personStamp()
        let page = try await session.cardHistoryPage(CardHistoryQuery(begin: "20261017", end: "20261030", page: 2, pageSize: 50),
                                                     since: stamp)
        XCTAssertEqual(page.rows.count, 5)
        let request = try XCTUnwrap(h.server.requests(path: "/card/getRecordList").first)
        XCTAssertEqual(request.bodyField("begin"), "20261017")
        XCTAssertEqual(request.bodyField("end"), "20261030")
        XCTAssertEqual(request.bodyField("pageNum"), "2")
        XCTAssertEqual(request.bodyField("pageSize"), "50")
        XCTAssertEqual(request.bodyField("custid"), T.custid)
        XCTAssertEqual(h.livenessCalls(), 0)
        XCTAssertEqual(h.loginBySysIdCalls(), 0)
        XCTAssertEqual(try h.vault.ecyktSession(), before, "nothing written")
    }

    func testSignedOutOrAnotherPersonGetsNoRecords() async throws {
        let h = Harness()
        let session = h.session()
        await T.expectError(.sessionExpired(.ecykt)) {
            _ = try await session.cardHistoryPage(CardHistoryQuery(begin: "20261017", end: "20261030", page: 1, pageSize: 50),
                                                  since: await session.personStamp())
        }
        try h.signedIn()
        try h.server.serve("ecykt/card-getRecordList-ok")
        let stamp = await session.personStamp()
        try await session.signOut()
        try h.signedIn()
        await T.expectError(.sessionExpired(.ecykt)) {
            _ = try await session.cardHistoryPage(CardHistoryQuery(begin: "20261017", end: "20261030", page: 1, pageSize: 50),
                                                  since: stamp)
        }
    }
}
