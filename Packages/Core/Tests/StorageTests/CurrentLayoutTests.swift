import XCTest
import Core

/// What this build writes is what the next launch reads: every item in its own group, read
/// back by the app and (shared items) by the widget, with nothing added, moved or deleted.
final class CurrentLayoutTests: XCTestCase {
    let app = FakeKeychain.app, shared = FakeKeychain.shared

    func testEveryItemReadsBackAndNothingIsMovedOrDeleted() throws {
        let kc = FakeKeychain(entitlements: [app, shared])
        let writer = KeychainSecureStore(backend: kc, accessGroup: shared, privateGroup: app)
        let keys = StoreKey.allCases
        for k in keys { try writer.write(Data(k.rawValue.utf8), for: k) }
        let written = kc.items

        // The next launch: a new store, every item read.
        kc.calls = []
        let relaunched = KeychainSecureStore(backend: kc, accessGroup: shared, privateGroup: app)
        for k in keys { XCTAssertEqual(try relaunched.read(k), Data(k.rawValue.utf8), k.rawValue) }
        let widget = KeychainSecureStore(backend: FakeKeychainView(kc, entitlements: [shared]), accessGroup: shared)
        for k in keys where k.isShared { XCTAssertEqual(try widget.read(k), Data(k.rawValue.utf8), k.rawValue) }

        XCTAssertEqual(kc.items, written, "nothing moved or deleted")
        XCTAssertFalse(kc.calls.contains { !$0.hasPrefix("copy") }, "reads only: \(kc.calls)")
    }
}
