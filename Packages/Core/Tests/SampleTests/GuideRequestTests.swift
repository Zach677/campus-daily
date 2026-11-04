import XCTest
import Core

/// Leaving the sample shows the live root again: on a fresh install its first-run check asks for
/// the guide at once, and 去登录 or a login link asks again a moment later. The second ask must
/// not replace the guide already up: a replaced cover or sheet is dismissed (which marks the
/// setup seen) and presented again.
@MainActor
final class GuideRequestTests: XCTestCase {
    private enum Step: Equatable { case login, washer }

    /// 暖橙: first-run and the login link both ask for the login step: one presentation.
    func testSecondAskForTheSameStepKeepsThePresentation() {
        let first = GuideRequest<Step>.ask(.login, over: nil)
        let second = GuideRequest<Step>.ask(.login, over: first)
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.contentID, first.contentID)
    }

    /// 清爽: first-run opens the checklist, the login link then asks for 学校账号 on it: the same
    /// sheet (same id), its content started again with that row pushed.
    func testMoreSpecificAskUpdatesTheGuideInPlace() {
        let first = GuideRequest<SetupChecklist.Row>.ask(nil, over: nil)
        let second = GuideRequest<SetupChecklist.Row>.ask(.account, over: first)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.start, .account)
        XCTAssertNotEqual(second.contentID, first.contentID)
        // The other order: first-run after the link keeps 学校账号.
        let third = GuideRequest<SetupChecklist.Row>.ask(nil, over: second)
        XCTAssertEqual(third, second)
    }

    /// Once closed (nothing up), the next ask is a new presentation.
    func testAskAfterCloseIsANewPresentation() {
        let first = GuideRequest<Step>.ask(.login, over: nil)
        let next = GuideRequest<Step>.ask(.login, over: nil)
        XCTAssertNotEqual(next.id, first.id)
    }

    /// The two ways out of the sample onto a fresh install: 去登录, and a login link (a widget).
    /// Each time the live root is built again and asks twice (first-run as it appears, then the
    /// login a moment later), and presents once; no ask dismisses the guide, so 「seen」 is not
    /// written for it.
    func testLeavingTheSampleOpensTheGuideOnce() throws {
        let login = try XCTUnwrap(URL(string: "campusdaily://login"))
        let ways: [@MainActor (SampleMode) -> Bool] = [
            { $0.leave(); return $0.takeLogin() },
            { $0.open(login) == .leftSample && $0.takePendingLink() == .login },
        ]
        for leave in ways {
            let sample = SampleMode()
            let seen = SeenCounter()
            var shown: GuideRequest<Step>?   // the live root's, new after the sample
            var presentations = 0
            func ask(_ step: Step) {
                let next = GuideRequest<Step>.ask(step, over: shown)
                if let old = shown, old.id != next.id { QuickSetupSeen.closed(in: seen, coveredBySample: sample.isActive) }
                if shown?.id != next.id { presentations += 1 }
                shown = next
            }
            sample.enter()
            let due = leave(sample)
            XCTAssertFalse(sample.isActive)
            ask(.login)                 // first-run, as the live root appears
            XCTAssertTrue(due); ask(.login)  // the login asked for on the way out
            XCTAssertEqual(presentations, 1)
            XCTAssertEqual(seen.writes, 0)
        }
    }
}

private final class SeenCounter: PreferenceStorage {
    var writes = 0
    func object(forKey key: String) -> Any? { nil }
    func set(_ value: Any?, forKey key: String) { writes += 1 }
}
