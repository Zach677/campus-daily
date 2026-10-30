import XCTest
import Core

/// Cancelled recharge navigations are logged by host only.
final class RechargeBlockedHostTests: XCTestCase {
    func testOnlyTheHostIsLogged() {
        let url = URL(string: "https://pay.example.invalid:443/cashier/index.html?orderId=99001&token=SYNTH-SECRET#frag")!
        let event = RechargeNavigation.blockedEvent(url)
        XCTAssertEqual(event, "recharge.blocked https://pay.example.invalid")
        for part in ["cashier", "orderId", "99001", "SYNTH-SECRET", "frag", "443"] { XCTAssertFalse(event.contains(part), part) }
    }

    func testSchemeOnlyLinksAndOddHosts() {
        XCTAssertEqual(RechargeNavigation.blockedEvent(URL(string: "alipays://platformapi/startapp?appId=1&qrcode=SYNTH")!),
                       "recharge.blocked alipays://platformapi")
        XCTAssertEqual(RechargeNavigation.blockedEvent(URL(string: "weixin:pay?token=SYNTH")!), "recharge.blocked weixin:")
        XCTAssertEqual(RechargeNavigation.blockedEvent(URL(string: "https://user:pw@Pay.Example.INVALID/")!),
                       "recharge.blocked https://pay.example.invalid")
        let long = URL(string: "https://" + String(repeating: "a", count: 200) + ".example/")!
        XCTAssertLessThanOrEqual(RechargeNavigation.blockedEvent(long).count, 80, "fits one diagnostic entry")
    }
}
