import XCTest
import Foundation
import DailyCore
import DailyHTTP
import DailyStore
import DailyTestSupport
@testable import HotWaterClient

// MARK: - Profiles and vault

final class WaterProfileTests: XCTestCase {
    let valid = #"{"secret":"fixture-secret ~/+","sid":"fixture-sid=1","bleName":"fixture-ble","typeID":1,"version":3}"#

    func testWaterConfigFileIsExactlyFiveKeys() throws {
        let p = try WaterConfigFile.parse(Data(valid.utf8), source: .bundled)
        XCTAssertEqual(p, WaterPlatformProfile(secret: "fixture-secret ~/+", sid: "fixture-sid=1", bleName: "fixture-ble", typeId: "1", version: "3"))
        let src = WaterProfileSource.imported(fileName: "a.waterconfig")
        let unreadable = [
            #"{"secret":"s","sid":"x","bleName":"b","typeID":1,"version":3,"studentID":"S1"}"#,
            #"{"secret":"s","sid":"x","bleName":"b","typeID":"1","version":3}"#,
            #"{"secret":"s","sid":"x","bleName":"b","typeID":1}"#,
            "[]", "not json",
        ]
        for text in unreadable {
            XCTAssertThrowsError(try WaterConfigFile.parse(Data(text.utf8), source: src), text) {
                XCTAssertEqual($0 as? WaterProfileError, .unreadable(src))
            }
        }
        for text in [#"{"secret":" ","sid":"x","bleName":"b","typeID":1,"version":3}"#,
                     #"{"secret":"s","sid":"x","bleName":"b","typeID":1,"version":0}"#,
                     #"{"secret":"s","sid":"x\n","bleName":"b","typeID":1,"version":3}"#] {
            XCTAssertThrowsError(try WaterConfigFile.parse(Data(text.utf8), source: src), text) {
                XCTAssertEqual($0 as? WaterProfileError, .incomplete(src))
            }
        }
        XCTAssertThrowsError(try WaterConfigFile.parse(Data(count: WaterConfigFile.maxBytes + 1), source: src))
        XCTAssertEqual(try WaterProfileResolver.decodeProfile(Data(valid.utf8), source: .bundled).typeId, "1", "typeID key accepted")
    }

    func testLoaderResolvesBothSources() async throws {
        let validData = Data(valid.utf8)
        let loader = WaterProfileLoader(bundled: { validData }, imported: { $0 == "mine.waterconfig" ? validData : nil })
        guard case .local(let p, .bundled) = try await loader.resolve(.bundled) else { return XCTFail() }
        XCTAssertEqual(p.bleName, "fixture-ble")
        guard case .local(_, .imported) = try await loader.resolve(.imported(fileName: "mine.waterconfig")) else { return XCTFail() }
        let missing = WaterProfileSource.imported(fileName: "other")
        await assertProfileError(.missing(missing)) { _ = try await loader.resolve(missing) }
        struct Boom: Error {}
        let broken = WaterProfileLoader(bundled: { throw Boom() }, imported: { _ in nil })
        await assertProfileError(.unreadable(.bundled)) { _ = try await broken.resolve(.bundled) }

        let empty = WaterProfileLoader(bundled: { nil }, imported: { _ in validData })
        let first = await WaterProfileResolver.firstUsable([.bundled, .imported(fileName: "x")], provider: empty)
        guard case .success(.local(_, .imported)) = first else { return XCTFail("\(first)") }
    }

    func assertProfileError(_ expected: WaterProfileError, file: StaticString = #filePath, line: UInt = #line,
                            _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? WaterProfileError, expected, file: file, line: line) }
    }

    func testVaultRoundTripAndFailClosedWrites() throws {
        let store = InMemorySecureStore()
        let vault = StoredWaterVault(store: store)
        XCTAssertNil(try vault.binding())
        XCTAssertNil(try vault.showerState())
        let binding = WaterBinding(studentId: "S1", schoolId: "20021", machineId: "1a2b3c4d", roomId: "r", roomLabel: "9栋 199",
                                   machineName: "9-901", peripheralID: "P")
        XCTAssertEqual(binding.machineId, "1A2B3C4D")
        try vault.saveBinding(binding)
        XCTAssertEqual(try vault.binding(), binding)
        let state = ShowerState(phase: .settling, machineID: "1A2B3C4D", consumption: "55", failure: nil)
        try vault.saveShowerState(state)
        XCTAssertEqual(try vault.showerState(), state)
        try vault.saveShowerState(nil)
        XCTAssertNil(try vault.showerState())

        store.failWrites(to: .waterSession)
        XCTAssertThrowsError(try vault.saveShowerState(state))
        XCTAssertFalse(binding.description.contains("S1"))
    }
}
