import XCTest
@testable import Core
import CoreTestSupport

/// 最近 and 昨天花了: short names, merchant names, one row per shower or order, the school's day.
final class RecentFeedTests: XCTestCase {
    let cal = SchoolCalendar.shanghai
    /// 2026-10-30 12:00 in Shanghai.
    var noon: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))! }

    func record(_ date: String, _ time: String, _ title: String, _ yuan: String) -> CardRecord {
        CardRecord(date: date, time: time, title: title, amount: Money(yuanString: yuan)!, balanceAfter: nil, direction: "1")
    }

    func moment(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: Short names

    func testRecordNamesMapToShortNames() {
        let cases: [(String, CardRecordKind)] = [
            ("蓝牙热水(中卡)(蓝牙热水(中卡))热水POS01(中卡)", .shower),
            ("POS消费(示例饭堂POS)(示例饭堂POS)01档口示例面馆", .canteen),
            ("示例食堂二楼", .canteen),
            ("校园卡充值", .topUp),
            ("银行圈存", .topUp),
            ("示例洗衣机", .laundry),
            ("购电(99栋)", .electricity),
            ("电费缴纳", .electricity),
            ("示例超市", .other),
        ]
        for (name, kind) in cases { XCTAssertEqual(CardRecordKind.of(name: name), kind, name) }
        XCTAssertEqual(CardRecordKind.allCases.map(\.title), ["食堂", "热水", "洗衣", "电费", "充值", "其他"])
        XCTAssertEqual(CardRecordKind.allCases.filter(\.isIncome), [.topUp])
    }

    func testTheFixtureRecordsAreClassified() throws {
        let data = try Data(contentsOf: FixtureLoader.root.appendingPathComponent("ecykt/card-getRecordList-ok.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = (root["response"] as? [String: Any])?["body"] as? [String: Any]
        let rows = try XCTUnwrap((body?["data"] as? [String: Any])?["rows"] as? [[String: Any]])
        let kinds = rows.map { CardRecordKind.of(name: $0["transname"] as? String ?? "") }
        XCTAssertEqual(kinds, [.shower, .shower, .shower, .shower, .canteen])
    }

    // MARK: Merchant names

    func testMerchantNamesLoseTheSchoolsWords() {
        XCTAssertEqual(MerchantName.clean("POS消费(示例饭堂POS)(示例饭堂POS)01档口示例面馆"), "示例面馆")
        XCTAssertNil(MerchantName.clean("蓝牙热水(中卡)(蓝牙热水(中卡))热水POS01(中卡)"), "nothing beyond the kind")
        XCTAssertEqual(MerchantName.clean("POS消费(示例饭堂POS)"), "示例饭堂")
        XCTAssertNil(MerchantName.clean("消费"))
        XCTAssertNil(MerchantName.clean("校园卡充值"))
        XCTAssertEqual(MerchantName.clean("示例超市（一楼）"), "示例超市")
        for raw in ["POS消费(示例饭堂POS)(示例饭堂POS)01档口示例面馆", "银行圈存", "POS消费", "交易扣款"] {
            let shown = MerchantName.clean(raw) ?? ""
            for word in MerchantName.hidden { XCTAssertFalse(shown.contains(word), "\(raw) → \(shown)") }
        }
    }

    // MARK: Record times

    func testRecordTimesAreSchoolTime() {
        XCTAssertEqual(record("20261029", "235959", "x", "1").moment(), moment(29, 23, 59).addingTimeInterval(59))
        XCTAssertEqual(record("20261030", "70500", "x", "1").moment(), moment(30, 7, 5), "a leading zero left out")
        XCTAssertNil(record("2026103", "120000", "x", "1").moment())
        XCTAssertNil(record("20260231", "120000", "x", "1").moment(), "no such day")
        XCTAssertNil(record("20261030", "250000", "x", "1").moment())
    }

    // MARK: Merge

    func testNewestFirstAtMostFour() {
        let card = (0..<6).map { record("20261030", String(format: "%02d0000", 6 + $0), "示例超市", "1") }
        let items = RecentFeed.items(card: card, app: [])
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.map(\.date), [moment(30, 11), moment(30, 10), moment(30, 9), moment(30, 8)])
    }

    /// The card's hot-water record and the app's shower within the window, same amount: one row,
    /// the app's (it knows the minutes).
    func testTheSameShowerAppearsOnceAsTheAppsRecord() {
        let card = [record("20261030", "080500", "蓝牙热水(中卡)热水POS01", "1.32"),
                    record("20261030", "074000", "POS消费(示例饭堂POS)01档口示例面馆", "6.8")]
        let shower = AppActivity(id: "s1", kind: .shower(minutes: 11), date: moment(30, 8, 2), amount: Money(fen: 132))
        let items = RecentFeed.items(card: card, app: [shower])
        XCTAssertEqual(items.map(\.title), ["热水 · 11 分钟", "食堂"])
        XCTAssertEqual(items.first?.source, .app)
        XCTAssertEqual(items.last?.detail, "示例面馆")
    }

    func testOnlyACloseRecordOfTheSameKindAndAmountIsTheSameEvent() {
        let shower = AppActivity(id: "s1", kind: .shower(minutes: 9), date: moment(30, 8), amount: Money(fen: 100))
        let far = record("20261030", "090100", "蓝牙热水", "1")
        let otherAmount = record("20261030", "080100", "蓝牙热水", "2")
        let otherKind = record("20261030", "080100", "示例洗衣机", "1")
        for card in [[far], [otherAmount], [otherKind]] {
            XCTAssertEqual(RecentFeed.items(card: card, app: [shower]).count, 2, card[0].title)
        }
        let inside = record("20261030", "082900", "蓝牙热水", "1")
        XCTAssertEqual(RecentFeed.items(card: [inside], app: [shower]).count, 1)
    }

    /// An app record without an amount takes the card's.
    func testAnAppRecordWithoutAnAmountTakesTheCards() {
        let order = AppActivity(id: "l1", kind: .laundry(program: "标准洗"), date: moment(30, 9), amount: nil, detail: "3 号机")
        let items = RecentFeed.items(card: [record("20261030", "090200", "示例洗衣机", "4")], app: [order])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "洗衣 · 标准洗")
        XCTAssertEqual(items[0].amount, Money(fen: 400))
        XCTAssertEqual(items[0].amountText, "−¥4.00")
    }

    /// Records that can't be read: the app's own records only.
    func testUnreadableRecordsLeaveTheAppsRecords() {
        let shower = AppActivity(id: "s1", kind: .shower(minutes: nil), date: moment(30, 8), amount: nil)
        XCTAssertEqual(RecentFeed.items(card: nil, app: [shower]).map(\.title), ["热水"])
    }

    func testAmountsReadAndSpoken() {
        let topUp = RecentItem(id: "a", kind: .topUp, title: "充值", date: noon, detail: nil, amount: Money(fen: 5000), source: .card)
        let canteen = RecentItem(id: "b", kind: .canteen, title: "食堂", date: noon, detail: nil, amount: Money(fen: 1250), source: .card)
        XCTAssertEqual(topUp.amountText, "+¥50.00")
        XCTAssertEqual(topUp.spokenAmount, "充了 50 元")
        XCTAssertEqual(canteen.amountText, "−¥12.50")
        XCTAssertEqual(canteen.spokenAmount, "花了 12.5 元")
    }

    // MARK: 昨天花了

    func activity(_ records: [CardRecord], fetchedAt: Date, complete: Bool = true,
                  begin: String = "20261028", end: String = "20261030") -> Tile<CardActivity> {
        Tile(value: CardActivity(records: records, begin: begin, end: end, complete: complete), fetchedAt: fetchedAt)
    }

    /// Yesterday in Shanghai, from 00:00:00 to 23:59:59; top-ups don't count.
    func testYesterdayIsTheSchoolsDayAndCountsMoneyOutOnly() {
        let records = [record("20261029", "000000", "示例超市", "1"),
                       record("20261029", "235959", "POS消费(示例饭堂POS)", "2.5"),
                       record("20261029", "120000", "校园卡充值", "50"),
                       record("20261030", "000000", "示例超市", "7"),
                       record("20261028", "235959", "示例超市", "9")]
        XCTAssertEqual(CardSpending.yesterday(activity(records, fetchedAt: noon), now: noon), Money(fen: 350))
        // 00:30 in Shanghai is still the previous evening in UTC: the school's day counts.
        let earlyMorning = moment(30, 0, 30)
        XCTAssertEqual(CardSpending.yesterday(activity(records, fetchedAt: earlyMorning), now: earlyMorning), Money(fen: 350))
    }

    func testNoSpendingYesterdayIsZero() {
        let records = [record("20261030", "080000", "示例超市", "1"), record("20261029", "080000", "校园卡充值", "50")]
        XCTAssertEqual(CardSpending.yesterday(activity(records, fetchedAt: noon), now: noon), .zero)
    }

    /// Nothing is said when the records can't tell.
    func testUnknownYesterdayIsHidden() {
        let records = [record("20261029", "080000", "示例超市", "1")]
        XCTAssertNil(CardSpending.yesterday(nil, now: noon), "never read")
        XCTAssertNil(CardSpending.yesterday(Tile<CardActivity>(error: .offline, errorAt: noon), now: noon), "unreadable")
        XCTAssertNil(CardSpending.yesterday(activity(records, fetchedAt: noon, complete: false), now: noon), "page cut short")
        XCTAssertNil(CardSpending.yesterday(activity(records, fetchedAt: moment(29, 22)), now: noon), "read before today")
        XCTAssertNil(CardSpending.yesterday(activity(records, fetchedAt: noon, begin: "20261030"), now: noon), "range without it")
        let unreadable = records + [record("20261029", "xx", "示例超市", "1")]
        XCTAssertNil(CardSpending.yesterday(activity(unreadable, fetchedAt: noon), now: noon), "a time that can't be read")
    }

    func testTheRangeIsThreeSchoolDays() {
        let r = CardActivity.range(at: moment(30, 0, 10))
        XCTAssertEqual(r.begin, "20261028")
        XCTAssertEqual(r.end, "20261030")
    }
}
