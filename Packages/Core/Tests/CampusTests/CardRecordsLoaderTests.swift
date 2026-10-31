import XCTest
@testable import Core

/// 校园卡记录's reads: a pull while older pages load, reads that come back late, and which
/// failures leave rows on the page.
@MainActor final class CardRecordsLoaderTests: XCTestCase {
    let cal = SchoolCalendar.shanghai
    /// 2026-10-30 12:00 in Shanghai.
    var noon: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))! }
    nonisolated static let today = "20261030"

    nonisolated static func record(_ date: String, _ time: String, _ yuan: String = "12.00") -> CardRecord {
        CardRecord(date: date, time: time, title: "POS消费示例面馆", amount: Money(yuanString: yuan)!,
                   balanceAfter: nil, direction: "1")
    }

    func makeLoader(_ school: School) -> CardRecordsLoader {
        CardRecordsLoader(source: CardRecordsSource(stamp: { await school.nextStamp() },
                                                    page: { query, stamp in try await school.page(query, stamp: stamp) }),
                          now: { [noon] in noon })
    }

    /// The school, scripted: today's range answers with `todayRows`, older ranges with
    /// `olderRows`; a read waits while its key is held ("today" / "older").
    actor School {
        var todayRows: [CardRecord]
        var olderRows: [CardRecord] = []
        var failToday = false
        var failOlder = false
        var held: Set<String> = []
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        var calls: [(query: CardHistoryQuery, stamp: Int)] = []
        var stamps = 0

        init(today: [CardRecord]) { todayRows = today }

        func nextStamp() -> Int { stamps += 1; return stamps }
        func set(today: [CardRecord]) { todayRows = today }
        func set(older: [CardRecord]) { olderRows = older }
        func set(failToday: Bool, failOlder: Bool) { self.failToday = failToday; self.failOlder = failOlder }
        func hold(_ key: String) { held.insert(key) }
        func release(_ key: String) {
            held.remove(key)
            for c in waiting.removeValue(forKey: key) ?? [] { c.resume() }
        }
        func isWaiting(_ key: String) -> Bool { !(waiting[key] ?? []).isEmpty }
        func olderCalls() -> Int { calls.filter { $0.query.end != CardRecordsLoaderTests.today }.count }
        func stampsUsed() -> [Int] { calls.map(\.stamp) }

        func page(_ query: CardHistoryQuery, stamp: Int) async throws -> CardRecordPage {
            calls.append((query, stamp))
            let key = query.end == CardRecordsLoaderTests.today ? "today" : "older"
            if held.contains(key) { await withCheckedContinuation { waiting[key, default: []].append($0) } }
            if key == "today" {
                if failToday { throw ServiceError.offline }
                return CardRecordPage(total: todayRows.count, rows: todayRows)
            }
            if failOlder { throw ServiceError.offline }
            let rows = olderRows.filter { $0.date >= query.begin && $0.date <= query.end }
            return CardRecordPage(total: rows.count, rows: rows)
        }
    }

    func waitUntil(_ school: School, waitingOn key: String, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if await school.isWaiting(key) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("nothing waited on \(key)", file: file, line: line)
    }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: A pull while older pages load

    /// The list's end appears while a pull reads from today: no older page is asked for the
    /// list being replaced, and the pulled list is what stays.
    func testNoOlderPageIsReadWhileAPullRuns() async {
        let first = Self.record(Self.today, "090000")
        let school = School(today: [first])
        await school.set(older: [Self.record("20261010", "120000")])
        let loader = makeLoader(school)
        await loader.reload()
        XCTAssertEqual(loader.state.history?.records, [first])

        let pulled = Self.record(Self.today, "110000")
        await school.set(today: [pulled, first])
        await school.hold("today")
        let pull = Task { await loader.reload() }
        await waitUntil(school, waitingOn: "today")
        XCTAssertTrue(loader.state.reloading)

        // The end of the old list comes into view meanwhile; an older read would answer late.
        await school.hold("older")
        let more = Task { await loader.loadMore() }
        await settle()
        let olderAsked = await school.olderCalls()
        XCTAssertEqual(olderAsked, 0, "nothing older is read for a list being replaced")

        await school.release("today")
        await pull.value
        await school.release("older")
        await more.value
        XCTAssertEqual(loader.state.history?.records, [pulled, first], "the pulled list is not replaced by the old one")
        XCTAssertFalse(loader.state.loadingMore)
        XCTAssertFalse(loader.state.reloading)
    }

    /// An older page asked for before a pull, back after it: dropped, the pulled list stays.
    func testAnOlderPageBackAfterAPullIsDropped() async {
        let first = Self.record(Self.today, "090000")
        let school = School(today: [first])
        await school.set(older: [Self.record("20261010", "120000")])
        let loader = makeLoader(school)
        await loader.reload()

        await school.hold("older")
        let more = Task { await loader.loadMore() }
        await waitUntil(school, waitingOn: "older")
        XCTAssertTrue(loader.state.loadingMore)

        let pulled = Self.record(Self.today, "110000")
        await school.set(today: [pulled])
        await loader.reload()
        await school.release("older")
        await more.value
        XCTAssertEqual(loader.state.history?.records, [pulled])
        XCTAssertFalse(loader.state.loadingMore)
    }

    // MARK: Late reads from today

    /// Two pulls: the first one's answer, back last, is dropped, and older pages are read for
    /// the person the kept list was read for.
    func testAnEarlierPullBackLastIsDroppedAndItsStampWithIt() async {
        let early = Self.record(Self.today, "080000")
        let school = School(today: [early])
        let loader = makeLoader(school)
        await school.hold("today")
        let firstPull = Task { await loader.reload() }
        await waitUntil(school, waitingOn: "today")

        let late = Self.record(Self.today, "100000")
        await school.set(today: [late])
        await school.release("today")
        await loader.reload()
        await firstPull.value
        XCTAssertEqual(loader.state.history?.records.count, 1)

        // Whichever answered first, the list is the second pull's (stamp 2) …
        let stampsBefore = await school.stampsUsed()
        XCTAssertEqual(stampsBefore.last, 2)
        // … and the next older page is read with its stamp.
        await school.set(older: [Self.record("20261010", "120000")])
        await loader.loadMore()
        let stamps = await school.stampsUsed()
        XCTAssertEqual(stamps.last, 2)
    }

    // MARK: Failures

    func testAFirstReadThatFailsShowsTheLineAndNoRows() async {
        let school = School(today: [])
        await school.set(failToday: true, failOlder: false)
        let loader = makeLoader(school)
        await loader.reload()
        XCTAssertEqual(loader.state.phase, .failed)
        XCTAssertNil(loader.state.history)
        XCTAssertFalse(loader.state.moreFailed)
    }

    func testAnOlderPageThatFailsKeepsTheRows() async {
        let first = Self.record(Self.today, "090000")
        let school = School(today: [first])
        await school.set(failToday: false, failOlder: true)
        let loader = makeLoader(school)
        await loader.reload()
        await loader.loadMore()
        XCTAssertEqual(loader.state.phase, .loaded)
        XCTAssertEqual(loader.state.history?.records, [first])
        XCTAssertTrue(loader.state.moreFailed)
        XCTAssertFalse(loader.state.loadingMore)

        await school.set(failToday: false, failOlder: false)
        await school.set(older: [Self.record("20261010", "120000")])
        await loader.loadMore()
        XCTAssertFalse(loader.state.moreFailed)
        XCTAssertEqual(loader.state.history?.records.count, 2)
    }

    /// Nothing today and every older range failing: no rows came, so it is the failed line.
    func testAFirstReadWithNoRowsBeforeAFailureIsTheFailedLine() async {
        let school = School(today: [])
        await school.set(failToday: false, failOlder: true)
        let loader = makeLoader(school)
        await loader.reload()
        XCTAssertEqual(loader.state.phase, .failed)
    }
}
