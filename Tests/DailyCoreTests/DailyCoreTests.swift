import XCTest
import DailyCore

final class MoneyTests: XCTestCase {
    func testParsesYuanStrings() {
        XCTAssertEqual(Money(yuanString: "7.9")?.fen, 790)
        XCTAssertEqual(Money(yuanString: ".06")?.fen, 6)
        XCTAssertEqual(Money(yuanString: "213.38")?.fen, 21338)
        XCTAssertEqual(Money(yuanString: "-1.50")?.fen, -150)
        XCTAssertEqual(Money(yuanString: "0.005")?.fen, 1) // half away from zero
        XCTAssertEqual(Money(yuanString: " 12 ")?.fen, 1200)
        for bad in ["", "abc", "1,000.00", "1.2.3", "¥3", "NaN"] { XCTAssertNil(Money(yuanString: bad), bad) }
    }

    func testParsesJSONNumbersWithoutBinaryDrift() {
        XCTAssertEqual(Money(yuanNumber: 7.9)?.fen, 790)
        XCTAssertEqual(Money(yuanNumber: 0.1 + 0.2)?.fen, 30)
        XCTAssertEqual(Money(yuanNumber: 98.9)?.fen, 9890)
        XCTAssertNil(Money(yuanNumber: .infinity))
    }

    func testFormattingAndArithmetic() {
        XCTAssertEqual(Money(fen: 790).yuanText, "7.90")
        XCTAssertEqual(Money(fen: -6).yuanText, "-0.06")
        XCTAssertEqual((Money(fen: 100) - Money(fen: 790)).fen, -690)
        XCTAssertTrue(Money(fen: 1) < Money(fen: 2))
        XCTAssertEqual(DecimalText.parse("14896.4300"), Decimal(string: "14896.43", locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertNil(DecimalText.parse("1,5"))
    }
}

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

final class ServiceErrorTests: XCTestCase {
    func testStateChangingRequestsBecomeUncertain() {
        for e: ServiceError in [.offline, .timedOut, .tls, .malformed(.lxt6, "data")] {
            XCTAssertEqual(e.forStateChangingRequest(.lxt6), .uncertain(.lxt6))
        }
        XCTAssertEqual(ServiceError.badRequest(.lxt6).forStateChangingRequest(.lxt6), .badRequest(.lxt6))
        XCTAssertEqual(ServiceError.sessionExpired(.ujing).forStateChangingRequest(.ujing), .sessionExpired(.ujing))
        let r = ServiceError.rejected(.lxt6, code: "1", message: "no")
        XCTAssertEqual(r.forStateChangingRequest(.lxt6), r)
    }

    func testRejectionTrimsMessage() {
        let long = String(repeating: "长", count: 200)
        guard case .rejected(_, _, let m) = ServiceError.rejection(.ecykt, code: "9", message: long) else { return XCTFail() }
        XCTAssertEqual(m.count, ServiceError.maxMessageLength)
    }
}

final class SnapshotReducerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)

    func testSessionExpiryKeepsValuesAndTheirFetchedAt() {
        var s = SchoolSnapshotReducer.reduce(.empty, .balance(.success(Money(fen: 790)), at: t0))
        s = SchoolSnapshotReducer.reduce(s, .sessionExpired(.sessionExpired(.ecykt), at: t1))
        XCTAssertTrue(s.needsLogin)
        XCTAssertEqual(s.card.value, Money(fen: 790))
        XCTAssertEqual(s.card.fetchedAt, t0)
        XCTAssertEqual(s.card.error, .sessionExpired(.ecykt))
        s = SchoolSnapshotReducer.reduce(s, .livenessOK(at: t1))
        XCTAssertFalse(s.needsLogin)
    }

    func testFailureKeepsOldValue() {
        var s = SchoolSnapshotReducer.reduce(.empty, .balance(.success(Money(fen: 100)), at: t0))
        s = SchoolSnapshotReducer.reduce(s, .balance(.failure(.offline), at: t1))
        XCTAssertEqual(s.card.value, Money(fen: 100))
        XCTAssertEqual(s.card.fetchedAt, t0)
        XCTAssertEqual(s.card.errorAt, t1)
        s = SchoolSnapshotReducer.reduce(s, .balance(.success(Money(fen: 50)), at: t1))
        XCTAssertNil(s.card.error)
    }

    func testMeterNotFoundIsNotAnError() {
        let s = SchoolSnapshotReducer.reduce(.empty, .meter(.success(nil), at: t0))
        XCTAssertTrue(s.power.notFound)
        XCTAssertNil(s.power.error)
        XCTAssertEqual(SchoolSnapshotReducer.reduce(s, .signedOut), .empty)
    }
}

final class MeterMatcherTests: XCTestCase {
    func testMatchOneNoneMany() throws {
        let a = try XCTUnwrap(DormAddress.parse("星湖校区9栋9号1层199房"))
        let m1 = Meter(comAddress: "1", name: "9栋199"), m2 = Meter(comAddress: "2", name: "9栋198"), m3 = Meter(comAddress: "3", name: "9栋199")
        XCTAssertEqual(MeterMatcher.match([m1, m2], address: a), .one(m1))
        XCTAssertEqual(MeterMatcher.match([m2], address: a), .none)
        XCTAssertEqual(MeterMatcher.match([m1, m2, m3], address: a), .many([m1, m3]))
        let binding = MeterBinding(nodeID: "n", comAddress: "3", label: "", nodeIsRoom: true)
        XCTAssertEqual(MeterMatcher.pick([m1, m3], binding: binding), m3)
        XCTAssertNil(MeterMatcher.pick([m1], binding: binding))
    }
}

final class RechargeReducerTests: XCTestCase {
    func testHappyPathConfirmsByChangedValue() {
        var (s, fx) = RechargeReducer.reduce(.idle, .tapRecharge(.card, baseline: Money(fen: 790)))
        XCTAssertEqual(fx, [.prepareSession(.card)])
        (s, fx) = RechargeReducer.reduce(s, .sessionReady)
        XCTAssertEqual(fx, [.openWebPage(.card)])
        let pay = URL(string: "alipays://platformapi/startapp?x=1")!
        (s, fx) = RechargeReducer.reduce(s, .payLinkTapped(pay))
        XCTAssertEqual(fx, [.openExternal(pay)])
        (s, fx) = RechargeReducer.reduce(s, .payLinkTapped(URL(string: "https://evil.example/")!))
        XCTAssertEqual(fx, [])
        (s, fx) = RechargeReducer.reduce(s, .returnedFromPage)
        XCTAssertEqual(fx, [.readValue(.card, delaySeconds: 5)])
        (s, fx) = RechargeReducer.reduce(s, .valueRead(Money(fen: 790)))
        XCTAssertEqual(s, .confirming(.card, baseline: Money(fen: 790), attempt: 2))
        (s, fx) = RechargeReducer.reduce(s, .valueRead(Money(fen: 5790)))
        XCTAssertEqual(s, .finished(.card, delta: Money(fen: 5000)))
    }

    func testNoClaimWithoutChange() {
        var s = RechargeState.confirming(.electricity, baseline: Money(fen: 100), attempt: 1)
        for _ in 0..<3 { s = RechargeReducer.reduce(s, .valueRead(Money(fen: 100))).0 }
        XCTAssertEqual(s, .finished(.electricity, delta: nil))
    }

    func testExpiredSessionAsksLoginThenRetriesOnce() {
        var (s, fx) = RechargeReducer.reduce(.checkingSession(.card, baseline: nil, reloginUsed: false), .sessionFailed(.sessionExpired(.ecykt)))
        XCTAssertEqual(fx, [.showLogin])
        (s, fx) = RechargeReducer.reduce(s, .reloggedIn)
        XCTAssertEqual(fx, [.prepareSession(.card)])
        (s, fx) = RechargeReducer.reduce(s, .sessionFailed(.sessionExpired(.ecykt)))
        XCTAssertEqual(s, .failed(.card, .sessionExpired(.ecykt)))
        XCTAssertEqual(fx, [])
        XCTAssertEqual(RechargeReducer.reduce(.checkingSession(.card, baseline: nil, reloginUsed: false), .sessionFailed(.offline)).0,
                       .failed(.card, .offline))
    }
}

final class WaterProfileSourceTests: XCTestCase {
    struct Provider: WaterProfileProviding {
        func resolve(_ source: WaterProfileSource) async throws -> WaterPlatformAccess {
            switch source {
            case .bundled: throw WaterProfileError.missing(.bundled)
            case .imported(let name):
                return .local(try WaterProfileResolver.decodeProfile(Data(#"{"secret":"s","sid":"i","ble_name":"b","type_id":1,"version":2,"student_id":"x"}"#.utf8), source: .imported(fileName: name)), source: source)
            }
        }
    }

    func testDecodeAcceptsBothKeyStylesAndRejectsIncomplete() throws {
        let p = try WaterProfileResolver.decodeProfile(Data(#"{"secret":"s","sid":"i","bleName":"b","typeId":"1","version":"2"}"#.utf8), source: .bundled)
        XCTAssertEqual(p.typeId, "1")
        XCTAssertFalse(p.description.contains("s,"))
        XCTAssertFalse("\(p)".contains("\"s\""))
        XCTAssertThrowsError(try WaterProfileResolver.decodeProfile(Data(#"{"secret":"","sid":"i"}"#.utf8), source: .bundled)) {
            XCTAssertEqual($0 as? WaterProfileError, .incomplete(.bundled))
        }
    }

    func testResolverPicksFirstUsableSource() async {
        let r2 = await WaterProfileResolver.firstUsable([.bundled, .imported(fileName: "a.waterconfig")], provider: Provider())
        guard case .success(.local(let p, _)) = r2 else { return XCTFail() }
        XCTAssertEqual(p.version, "2")
        let r3 = await WaterProfileResolver.firstUsable([.bundled], provider: Provider())
        XCTAssertEqual(r3, .failure(.missing(.bundled)))
    }
}

final class JSONValueTests: XCTestCase {
    func testParsesFragmentsAndKeepsIntegersExact() throws {
        XCTAssertEqual(try JSONValue.parse("7.9"), .double(7.9))
        XCTAssertEqual(try JSONValue.parse("170000000000000001"), .int(170000000000000001))
        XCTAssertEqual(try JSONValue.parse("\"[]\"").text, "[]")
        XCTAssertEqual(try JSONValue.parse("{\"a\":[true,null]}")["a"], .array([.bool(true), .null]))
    }
}
