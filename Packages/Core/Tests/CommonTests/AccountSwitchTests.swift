import XCTest
@testable import Core

/// Someone else signed in: the previous person's numbers and hot-water binding go, unless a
/// shower may still need the binding.
final class AccountSwitchTests: XCTestCase {
    struct Failed: Error {}

    func testHotWaterForEveryCase() {
        var deleted = 0
        XCTAssertEqual(AccountSwitch.clearHotWater(hasBinding: false, mayClear: true) { deleted += 1 }, .none)
        XCTAssertEqual(AccountSwitch.clearHotWater(hasBinding: true, mayClear: true) { deleted += 1 }, .cleared)
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(AccountSwitch.clearHotWater(hasBinding: true, mayClear: false) { deleted += 1 }, .keptForReview)
        XCTAssertEqual(deleted, 1, "a shower that may still need the binding keeps it")
        XCTAssertEqual(AccountSwitch.clearHotWater(hasBinding: true, mayClear: true) { throw Failed() }, .keptForReview)
        XCTAssertEqual([AccountSwitch.HotWater.none, .cleared, .keptForReview].map(\.noticed), [false, true, true])
    }

    /// The real stores: after the switch the shared snapshot holds no balance and the binding is gone.
    func testTheSnapshotThenTheBindingAreCleared() async throws {
        let store = InMemorySecureStore()
        let snapshots = SharedSnapshotStore(store: store)
        var old = HomeSnapshot(checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        old.card.succeed(Money(fen: 100), at: Date(timeIntervalSince1970: 1_800_000_000))
        try snapshots.saveSnapshot(old)
        try store.write(Data("{}".utf8), for: .showerBinding)
        let stack = SchoolRefreshStack(store: store, http: URLSessionHTTPClient(allowedHosts: []), role: "app",
                                       leaseWait: 0, diagnostic: { _ in })
        var order: [String] = []
        let result = await AccountSwitch.clearPreviousPerson(
            snapshot: { order.append("snapshot"); try await stack.refresher.clear() },
            hotWater: {
                order.append("hotWater")
                return AccountSwitch.clearHotWater(hasBinding: (try? store.read(.showerBinding)) != nil, mayClear: true) {
                    try store.delete(.showerBinding)
                }
            })
        XCTAssertEqual(result, .cleared)
        XCTAssertEqual(order, ["snapshot", "hotWater"])
        XCTAssertNil(try snapshots.loadSnapshot()?.card.value)
        XCTAssertNil(try store.read(.showerBinding))
    }

    func testAFailedSnapshotWriteStillClearsHotWater() async {
        let result = await AccountSwitch.clearPreviousPerson(snapshot: { throw Failed() }, hotWater: { .cleared })
        XCTAssertEqual(result, .cleared)
    }
}
