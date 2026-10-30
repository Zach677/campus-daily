import XCTest
import Core

final class DormAddressTests: XCTestCase {
    func testParsesPortalAddressWithUnit() throws {
        let a = try XCTUnwrap(DormAddress.parse("星湖校区9栋9号1层199房"))
        XCTAssertEqual(a, DormAddress(campus: "星湖校区", building: "9", unit: "9", floor: 1, room: "199"))
        XCTAssertEqual(a.meterName, "9栋199")
        XCTAssertEqual(a.chineseFloorLabel, "一楼")
    }

    func testParsesVariants() throws {
        XCTAssertEqual(DormAddress.parse("示例校区 2栋 5层 504房")?.unit, nil)
        XCTAssertEqual(DormAddress.parse("示例校区2幢3号5楼504室")?.room, "504")
        XCTAssertEqual(DormAddress.parse("示例校区A3栋3号12层1201房")?.building, "A3")
        for bad in ["", "2504", "9栋199", "暂无宿舍", "示例校区2栋3号5层", "示例校区2栋3号0层504房"] {
            XCTAssertNil(DormAddress.parse(bad), bad)
        }
    }

    func testFloorMapsToChineseNumerals() throws {
        let expected = ["一楼", "二楼", "三楼", "四楼", "五楼", "六楼", "七楼"]
        for (i, label) in expected.enumerated() {
            let a = try XCTUnwrap(DormAddress.parse("示例校区9栋9号\(i + 1)层199房"))
            XCTAssertEqual(a.chineseFloorLabel, label)
            XCTAssertTrue(a.matchesFloor(label))
            XCTAssertTrue(a.matchesFloor("\(i + 1)楼"))
        }
        XCTAssertEqual(DormAddress.chineseNumeral(10), "十")
        XCTAssertEqual(DormAddress.chineseNumeral(12), "十二")
        XCTAssertEqual(DormAddress.chineseNumeral(20), "二十")
        XCTAssertEqual(DormAddress.chineseNumeral(23), "二十三")
    }

    func testMatchers() throws {
        let a = try XCTUnwrap(DormAddress.parse("星湖校区9栋9号1层199房"))
        XCTAssertTrue(a.matchesCampus("星湖校区"))
        XCTAssertTrue(a.matchesBuilding("9栋"))
        XCTAssertFalse(a.matchesBuilding("19栋"))
        XCTAssertTrue(a.matchesRoom("199"))
        XCTAssertFalse(a.matchesRoom("1990"))
        XCTAssertTrue(a.matchesMeterName("9栋199"))
        XCTAssertTrue(a.matchesMeterName("9栋 · 199"))
        XCTAssertFalse(a.matchesMeterName("19栋199"))
        XCTAssertFalse(a.matchesMeterName("9栋1990"))
        XCTAssertFalse(a.matchesFloor("十一楼"))
    }
}
