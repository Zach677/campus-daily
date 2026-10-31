import XCTest
import Core

/// The meter page opened where the lookup stopped: the matched levels on one line with 「重选」,
/// then this level's list under 「选…」, the row that may be the dorm's first.
final class MeterPickerTextTests: XCTestCase {
    static let address = DormAddress.parse("星湖校区99栋9号1层991房")!
    func nodes(_ names: String...) -> [PowerNode] { names.enumerated().map { PowerNode(id: "99\($0.offset)", name: $0.element) } }

    func testEachLevelNamesItsList() {
        XCTAssertEqual(MeterLevel.allCases.map(MeterPageText.header), ["选校区", "选公寓", "选楼栋", "选楼层", "选房间"])
        XCTAssertEqual(MeterPageText.suggestion, "可能是这个")
        XCTAssertEqual(MeterPageText.rechoose, "重选")
        XCTAssertEqual(MeterPageText.finding, "正在找电表…")
    }

    /// The levels already matched, floors left out as in every location.
    func testTheMatchedLevelsOnOneLine() {
        XCTAssertEqual(MeterPageText.matchedLine(nodes("星湖校区", "半山公寓", "99栋", "1楼")), "星湖校区 · 半山公寓 · 99栋")
        XCTAssertEqual(MeterPageText.matchedLine([]), "")
    }

    /// Suggested rows come first, in the order read; the others keep theirs.
    func testTheSuggestedRowsComeFirst() {
        let options = nodes("989", "990", "991", "992")
        let rows = MeterPageText.rows(options, suggested: ["992", "993"])
        XCTAssertEqual(rows.map(\.node.name), ["991", "992", "989", "990"])
        XCTAssertEqual(rows.map(\.suggested), [true, true, false, false])
        XCTAssertEqual(MeterPageText.rows(options, suggested: []).map(\.node), options)
        XCTAssertEqual(MeterPageText.rows(options, suggested: []).map(\.suggested), [false, false, false, false])
    }

    /// Below the stop, the user walks on by hand: each list's dorm row is offered first.
    /// Apartments are not named by the portal, so none is suggested there.
    func testTheDormsRowIsSuggestedAtEachLevel() {
        XCTAssertEqual(MeterPageText.suggested(nodes("星湖校区", "大旺校区"), at: .campus, for: Self.address), ["990"])
        XCTAssertEqual(MeterPageText.suggested(nodes("半山公寓", "樱花公寓"), at: .apartment, for: Self.address), [])
        XCTAssertEqual(MeterPageText.suggested(nodes("1栋", "99栋", "99 栋"), at: .building, for: Self.address), ["991", "992"])
        XCTAssertEqual(MeterPageText.suggested(nodes("1楼", "2楼"), at: .floor, for: Self.address), ["990"])
        XCTAssertEqual(MeterPageText.suggested(nodes("989", "991房"), at: .room, for: Self.address), ["991"])
        XCTAssertEqual(MeterPageText.suggested(nodes("星湖校区"), at: .campus, for: nil), [], "no dorm known")
    }

    /// What the next list is, from where the user was and what it holds.
    func testTheNextLevelIsToldFromItsRows() {
        XCTAssertEqual(MeterLevel.next(after: nil, options: nodes("星湖校区")), .campus)
        XCTAssertEqual(MeterLevel.next(after: .campus, options: nodes("半山公寓", "樱花公寓")), .apartment)
        XCTAssertEqual(MeterLevel.next(after: .campus, options: nodes("98栋", "99栋")), .building)
        XCTAssertEqual(MeterLevel.next(after: .apartment, options: nodes("1栋", "99幢", "3号楼")), .building)
        XCTAssertEqual(MeterLevel.next(after: .building, options: nodes("1楼", "2楼", "十二层")), .floor)
        XCTAssertEqual(MeterLevel.next(after: .building, options: nodes("101", "102")), .room, "rooms right under the building")
        XCTAssertEqual(MeterLevel.next(after: .floor, options: nodes("989", "990")), .room)
        XCTAssertEqual(MeterLevel.next(after: .room, options: nodes("A", "B")), .room)
    }

    /// The search field names what the list holds: buildings and rooms (the school's own names,
    /// e.g. 「99栋」, are shown as they are).
    func testTheSearchFieldAsksForABuildingOrRoom() {
        XCTAssertEqual(MeterPageText.searchPrompt, "搜索楼栋或房间")
    }

    /// Above a stopped level's list: only a failure is said; a lookup running again shows its
    /// spinner by the list header and nothing else.
    func testAboveAStoppedLevelOnlyAFailureIsSaid() {
        XCTAssertNil(MeterPageText.noteAtStop(finding: true, issue: nil), "no 「正在找电表…」 group")
        XCTAssertNil(MeterPageText.noteAtStop(finding: true, issue: ServiceError.timedOut.userMessage))
        XCTAssertNil(MeterPageText.noteAtStop(finding: false, issue: nil))
        XCTAssertNil(MeterPageText.noteAtStop(finding: false, issue: MeterPageText.stoppedIssue), "the list is the answer")
        XCTAssertEqual(MeterPageText.noteAtStop(finding: false, issue: ServiceError.timedOut.userMessage), "学校那边太慢了，等一下再找。")
        XCTAssertEqual(MeterPageText.noteAtStop(finding: false, issue: ServiceError.offline.userMessage), ServiceError.offline.userMessage)
        XCTAssertEqual(MeterPageText.stoppedIssue, "没自动找到电表，去「电表」里选一下。")
    }
}
