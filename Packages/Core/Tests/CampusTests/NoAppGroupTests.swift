import XCTest
@testable import Core
import CoreTestSupport

/// A build signed without the App Group (re-signed under another group) has no lease file. The
/// app then reads, signs in and recharges without the lease instead of reporting "busy"
/// forever; the widget leaves every school read to the app, so the two never read at once.
final class NoAppGroupTests: XCTestCase {
    func stack(_ h: Harness, role: String) -> SchoolRefreshStack {
        SchoolRefreshStack(store: h.store, http: h.server.makeClient(), role: role, leaseWait: 5, leaseFile: nil, diagnostic: { _ in })
    }

    func testAppSignsInWithoutTheLease() async throws {
        let value = try await stack(Harness(), role: "app").refresher.holdingLease { _ in 7 }
        XCTAssertEqual(value, 7)
    }

    func testAppReadsWithoutTheLease() async throws {
        let h = Harness()
        try h.signedIn()
        try h.server.serve("ecykt/getSysBindCustInfo-ok")
        try h.server.serve("ecykt/getUserBalance-ok")
        try h.server.serve("ecykt/card-getRecordList-ok")
        let report = await stack(h, role: "app").refresher.refresh(inBackground: false)
        XCTAssertFalse(report.leaseBusy)
        XCTAssertEqual(report.snapshot.card.value, Money(fen: 790))
        XCTAssertTrue(report.snapshotSaved)
    }

    func testWidgetLeavesTheReadToTheApp() async throws {
        let h = Harness()
        try h.signedIn()
        let report = await stack(h, role: "widget").refresher.refresh(inBackground: true)
        XCTAssertTrue(report.leaseBusy)
        XCTAssertTrue(h.server.requests.isEmpty, "nothing is sent")
    }

    /// A lease without a file can never be taken: a login under it runs without the lease
    /// rather than waiting and failing as busy.
    func testLoginUnderALeaseWithoutAFileRunsWithoutIt() async throws {
        let h = Harness()
        let refresher = SnapshotRefresher(school: h.session(), store: h.snapshots,
                                          lease: RefreshLease(file: nil, owner: "app-1"), leaseWait: 5,
                                          sleep: { _ in XCTFail("nothing to wait for") })
        let value = try await refresher.holdingLease { owning -> Int in
            XCTAssertEqual(try owning.write { 1 }, 1, "writes are not blocked")
            return 2
        }
        XCTAssertEqual(value, 2)
    }
}
