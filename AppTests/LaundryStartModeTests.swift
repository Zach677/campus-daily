import XCTest
import Core
@testable import XiaoRiChang

/// 立刻洗衣 in the pay sheet and on the order card: the words, the spoken labels and the demo
/// records the screenshots open on (nothing is started from them).
@MainActor
final class LaundryStartModeTests: XCTestCase {
    func testThePaySheetWords() {
        XCTAssertEqual(LaundryStartCopy.section, "洗衣方式")
        XCTAssertEqual(LaundryStartCopy.normal, "正常洗衣")
        XCTAssertEqual(LaundryStartCopy.normalNote, "付完款，照常到机器上启动。")
        XCTAssertEqual(LaundryStartCopy.immediate + "（" + LaundryStartCopy.trial + "）", "立刻洗衣（试用）")
        XCTAssertEqual(LaundryStartCopy.immediateNotes.map(\.text).joined(),
                       "先放好衣服和洗衣液，关好门。付完款回到校日常，它会帮你启动机器。下单后 10 分钟内有效，没启动的话去 U净 App 里启动。")
        XCTAssertEqual(LaundryStartCopy.immediateNotes.map(\.symbol), ["tshirt", "arrow.uturn.backward", "clock"])
        XCTAssertEqual(LaundryStartCopy.amountNote, "实际金额以支付宝里显示的为准。")
        XCTAssertTrue(ClearLaundryCopy.caution.hasSuffix(LaundryStartCopy.amountNote))
    }

    func testTheLineIsSpokenInFullWithANoticePrefix() {
        let refused = LaundryStartLine(kind: .refused, text: "U净 没让启动：设备未关门", detail: "去 U净 App 里启动。")
        XCTAssertEqual(ImmediateStartLine.spoken(refused), "注意，U净 没让启动：设备未关门，去 U净 App 里启动。")
        let sent = LaundryStartLine(kind: .sent, text: "启动指令发出去了，等机器响应。")
        XCTAssertEqual(ImmediateStartLine.spoken(sent), "启动指令发出去了，等机器响应。")
    }

    func testIcons() {
        XCTAssertEqual(ImmediateStartLine.symbol(.armed), "bolt")
        XCTAssertEqual(ImmediateStartLine.symbol(.ready), "bolt")
        XCTAssertEqual(ImmediateStartLine.symbol(.sent), "paperplane")
        for kind in [LaundryStartLine.Kind.uncertain, .blocked, .refused] {
            XCTAssertEqual(ImmediateStartLine.symbol(kind), "exclamationmark.circle")
        }
    }

    func testDemoRecordsCarryTheirLine() {
        let cases: [(LaundryDemo.Kind, LaundryStartLine.Kind)] = [
            (.nowUnpaid, .armed), (.nowReady, .ready), (.nowChecking, .checking), (.nowSent, .sent),
            (.nowUncertain, .uncertain), (.nowUnsupported, .blocked), (.nowExpired, .blocked), (.nowRefused, .refused),
        ]
        for (kind, line) in cases {
            let demo = LaundryDemo.make(kind)
            XCTAssertEqual(demo.facts.startLine?.kind, line, kind.rawValue)
            XCTAssertEqual(demo.facts.record?.immediate, true, kind.rawValue)
        }
        XCTAssertEqual(LaundryDemo.make(.nowExpired).facts.startLine?.text, "下单超过 10 分钟，没帮你启动。")
        XCTAssertNil(LaundryDemo.make(.unpaid).facts.startLine, "a normal order has no line")
        let confirmNow = LaundryDemo.make(.confirmNow)
        XCTAssertTrue(confirmNow.immediate)
        XCTAssertEqual(confirmNow.sheet, .confirm)
        XCTAssertFalse(LaundryDemo.make(.confirm).immediate, "the sheet opens on 正常洗衣")
    }
}
