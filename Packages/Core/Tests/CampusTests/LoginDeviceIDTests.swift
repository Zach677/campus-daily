import XCTest
@testable import Core
import CoreTestSupport

final class LoginDeviceIDTests: XCTestCase {
    /// A new device id that could not be stored is not sent: the school would see a new
    /// browser on every login.
    func testANewDeviceIdThatCannotBeStoredIsNotSent() async throws {
        let login = FakePasswordLogin(.success(SchoolPasswordSignInTests.freshToken))
        var h = Harness()
        h.passwordLogin = login
        h.store.failWrites(to: .schoolDevice)
        do {
            _ = try await h.session().signIn(account: "99100991", password: "synthetic-pw-991", savePassword: false, owning: .unchecked)
            XCTFail("signed in with a device id that was never stored")
        } catch {
            XCTAssertEqual(error as? SchoolLoginFailure, .busy)
        }
        XCTAssertTrue(login.calls.isEmpty)
    }
}
