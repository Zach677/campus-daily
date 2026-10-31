import XCTest
import Core

/// The lookup stopped with rooms in several apartments: onboarding's 「你住哪间」 step and the
/// meter page ask which apartment, one row per room. The step also says when the lookup is
/// still looking or the school was too slow, and nothing for a plain stop.
final class MeterQuestionTests: XCTestCase {
    static let address = DormAddress.parse("星湖校区99栋9号1层991房")!
    static let campus = PowerNode(id: "991001", name: "星湖校区")
    static let banshan = PowerNode(id: "991001001", name: "半山公寓")
    static let lanxiang = PowerNode(id: "991001007", name: "兰香公寓")

    static func candidate(_ apartment: PowerNode, _ room: String) -> MeterCandidate {
        MeterCandidate(meter: Meter(comAddress: "99000000" + room, name: "99栋991"),
                       path: [campus, apartment, PowerNode(id: apartment.id + "099", name: "99栋"),
                              PowerNode(id: apartment.id + "0991", name: "1楼"), PowerNode(id: apartment.id + room, name: "991")])
    }

    static let asking = MeterWalkStop(level: .apartment, path: [campus], options: [banshan, lanxiang],
                                      suggested: [banshan.id, lanxiang.id],
                                      candidates: [candidate(banshan, "1991"), candidate(lanxiang, "7991")])
    static let plain = MeterWalkStop(level: .apartment, path: [campus], options: [banshan, lanxiang], suggested: [banshan.id, lanxiang.id])

    func testTheQuestionHasARowPerRoomTitledByApartment() throws {
        let q = try XCTUnwrap(MeterQuestion(Self.asking, address: Self.address))
        XCTAssertEqual(q.text, "2 个公寓都有 99 栋 991，你住哪个？")
        XCTAssertEqual(q.rows.map(\.title), ["半山公寓", "兰香公寓"])
        XCTAssertEqual(q.rows.map(\.location), ["星湖校区 · 半山公寓 · 99栋 · 991", "星湖校区 · 兰香公寓 · 99栋 · 991"])
        XCTAssertEqual(q.rows.map(\.spoken), ["半山公寓，星湖校区 半山公寓 99栋 991", "兰香公寓，星湖校区 兰香公寓 99栋 991"])
        XCTAssertEqual(q.rows.map(\.candidate), Self.asking.candidates)
        XCTAssertEqual(Set(q.rows.map(\.id)).count, 2)
        XCTAssertNil(MeterQuestion(Self.plain, address: Self.address))
        XCTAssertNil(MeterQuestion(Self.asking, address: nil))
    }

    func testTheDormStepSaysWhatTheLookupIsDoing() throws {
        let q = try XCTUnwrap(MeterQuestion(Self.asking, address: Self.address))
        func state(running: Bool = false, bound: Bool = false, stop: MeterWalkStop? = nil, issue: String? = nil) -> DormStepMeter {
            DormStepMeter(running: running, bound: bound, stop: stop, issue: issue, address: Self.address)
        }
        XCTAssertEqual(state(running: true), .finding)
        XCTAssertEqual(state(running: true, stop: Self.asking), .finding, "looking again: the spinner")
        XCTAssertEqual(state(stop: Self.asking, issue: MeterPageText.stoppedIssue), .ask(q))
        XCTAssertEqual(state(stop: Self.plain, issue: MeterPageText.stoppedIssue), .hidden, "no such room: nothing here")
        XCTAssertEqual(state(issue: ServiceError.timedOut.userMessage), .failed("学校那边太慢了，等一下再找。"))
        XCTAssertEqual(state(issue: ServiceError.offline.userMessage), .failed(ServiceError.offline.userMessage))
        XCTAssertEqual(state(bound: true), .hidden, "matched: the row goes, nothing said")
        XCTAssertEqual(state(bound: true, issue: ServiceError.timedOut.userMessage), .hidden)
        XCTAssertEqual(state(), .hidden)
        XCTAssertEqual(DormStepMeter.finding.text, "正在找电表…")
        XCTAssertEqual(DormStepMeter.retry, "再找一次电表")
        XCTAssertEqual(DormStepMeter.skipNote, "电表先跳过，之后在设置 › 电表里选。")
    }
}
