import XCTest
@testable import Core

/// Whether the recharge page, when it could not be prepared, offers signing in again.
final class RechargeOpenIssueTests: XCTestCase {
    /// The widget is refreshing (it holds the lease): nothing is wrong with the login.
    func testAnUpdateInProgressAsksToWaitAndOffersNoSignIn() {
        let issue = RechargeOpenIssue(SchoolLoginFailure.busy)
        XCTAssertFalse(issue.offersSignIn)
    }

    func testAnExpiredLoginOffersSignIn() {
        let issue = RechargeOpenIssue(ServiceError.sessionExpired(.ecykt))
        XCTAssertEqual(issue.text, ServiceError.sessionExpired(.ecykt).userMessage)
        XCTAssertTrue(issue.offersSignIn)
    }

    func testAnythingElseSaysThePageDidNotOpen() {
        let issue = RechargeOpenIssue(CocoaError(.fileReadUnknown))
        XCTAssertTrue(issue.offersSignIn)
    }
}
