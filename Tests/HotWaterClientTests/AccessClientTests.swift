import XCTest
import Foundation
import DailyCore
import DailyHTTP
import DailyStore
import DailyTestSupport
@testable import HotWaterClient

/// Access-service client against synthetic replies shaped like `services/access/server/access.mjs`.
final class AccessClientTests: XCTestCase {
    let host = "https://campus-api.070688.xyz"
    let token = String(repeating: "t", count: 43)
    var grant: WaterAccessGrant {
        WaterAccessGrant(token: token, campusOwner: "o", expiresAt: 1_900_000_000_000, bleName: "fixture-ble", typeID: 1, version: 3)
    }

    func client(_ server: StubServer, grant: WaterAccessGrant? = nil) -> WaterAccessServiceClient {
        WaterAccessServiceClient(http: server.makeClient(allowedHosts: AllowedHosts.hotWaterAccess), endpoint: URL(string: host)!,
                                 grant: grant, operationID: { "op-1" })
    }

    func json(_ text: String) -> Data { Data(text.utf8) }

    func testHealthAndEndpointChoice() async throws {
        let server = StubServer()
        server.respond("GET", host + "/health", body: json(#"{"service":"campus-daily-access","protocol":1,"configured":true}"#))
        server.respond("GET", "https://campus-daily-access.jasonbeam-campus.workers.dev/health",
                       body: json(#"{"service":"campus-daily-access","protocol":1,"configured":false}"#))
        let http = server.makeClient(allowedHosts: AllowedHosts.hotWaterAccess)
        let first = await WaterAccessServiceClient.firstHealthy(http: http)
        XCTAssertEqual(first, URL(string: host))
        let backupOnly = await WaterAccessServiceClient.firstHealthy(http: http, candidates: [WaterAccessServiceClient.defaultEndpoints[1]])
        XCTAssertNil(backupOnly, "not configured is not healthy")
    }

    func testConnectChecksOwnerAndShapes() async throws {
        let session = EcyktSession(token: "acc", syscustid: "sys")
        let owner = WaterAccessServiceClient.campusOwner(areacode: session.areacode, syscustid: "sys")
        XCTAssertEqual(owner.count, 64)
        let reply = #"{"token":"\#(token)","campusOwner":"\#(owner)","expiresAt":1900000000000,"studentID":"S1234567","schoolID":"20021","bleName":"fixture-ble","typeID":1,"version":3}"#
        let server = StubServer()
        server.respond("POST", host + "/v1/connect", body: json(reply), times: 1)
        let (user, g) = try await client(server).connect(session, custid: "cust")
        XCTAssertEqual(user, WaterUser(studentId: "S1234567", schoolId: "20021"))
        XCTAssertEqual(g, WaterAccessGrant(token: token, campusOwner: owner, expiresAt: 1_900_000_000_000, bleName: "fixture-ble", typeID: 1, version: 3))
        XCTAssertTrue(g.isCurrent(at: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertFalse(g.isCurrent(at: Date(timeIntervalSince1970: 1_899_999_990)))
        XCTAssertFalse(g.description.contains(token))
        let req = try XCTUnwrap(server.requests.first)
        XCTAssertNil(req.header("Authorization"))
        XCTAssertEqual(req.bodyField("acc_token"), "acc")
        XCTAssertEqual(req.bodyField("custid"), "cust")

        server.respond("POST", host + "/v1/connect", body: json(reply.replacingOccurrences(of: owner, with: String(repeating: "0", count: 64))), times: 1)
        await Golden.expectError(.malformed(.lxt6, "campusOwner")) { _ = try await self.client(server).connect(session, custid: "cust") }
    }

    func testReadsNeedTheGrantAndSendBearer() async throws {
        let server = StubServer()
        await Golden.expectError(.sessionExpired(.lxt6)) { _ = try await self.client(server).areas(parent: "x") }
        XCTAssertTrue(server.requests.isEmpty)

        server.respond("POST", host + "/v1/options", body: json(#"{"options":[{"id":"c1","name":"星湖校区"}]}"#))
        server.respond("POST", host + "/v1/machines", body: json(#"{"machines":[{"id":"1a2b3c4d","name":"9-901","mac":"m"}]}"#))
        let c = client(server, grant: grant)
        let options = try await c.areas(parent: "root")
        XCTAssertEqual(options, [AreaNode(id: "c1", name: "星湖校区")])
        let machines = try await c.machines(room: "r", schoolId: "ignored")
        XCTAssertEqual(machines.map(\.machineId), ["1A2B3C4D"])
        XCTAssertEqual(server.requests.first?.header("Authorization"), "Bearer " + token)
        XCTAssertEqual(server.requests.first?.bodyField("parent"), "root")
    }

    func testReadErrorMapping() async throws {
        let cases: [(Int, String, ServiceError)] = [
            (401, #"{"error":"school_login_required"}"#, .sessionExpired(.ecykt)),
            (401, #"{"error":"access_expired"}"#, .sessionExpired(.lxt6)),
            (429, #"{"error":"rate_limited"}"#, .rejected(.lxt6, code: "rate_limited", message: "刷新得太频繁了，过一会儿再试。")),
            (502, "oops", .rejected(.lxt6, code: "invalid_response", message: "暂时连不上热水平台，等一下再刷新。")),
            (200, "[]", .malformed(.lxt6, "$")),
        ]
        for (status, body, expected) in cases {
            let server = StubServer()
            server.respond("POST", host + "/v1/options", status: status, body: json(body))
            await Golden.expectError(expected) { _ = try await self.client(server, grant: self.grant).areas(parent: "x") }
        }
    }

    func testAuthorizeAndSettle() async throws {
        let server = StubServer()
        server.respond("POST", host + "/v1/authorize", body: json(#"{"machineID":"11223344","studentID":"001122ff","payload":"000102030405060708090A0B0C0D0E"}"#))
        server.respond("POST", host + "/v1/settle", body: json(#"{"settled":true,"payFen":163}"#))
        let c = client(server, grant: grant)
        let a = try await c.authorize(Golden.binding, frame: Golden.frame)
        XCTAssertEqual(a, WaterAuthorization(machineID: "11223344", payload: Data((0..<15).map { UInt8($0) }), authorizationID: "001122FF"))
        let r = try await c.settle(Golden.binding, frame: Golden.frame)
        XCTAssertEqual(r.amount?.yuanText, "1.63")
        XCTAssertEqual(server.requests[0].bodyField("frame"), HexCoding.upper(Golden.frame))
        XCTAssertEqual(server.requests[0].bodyField("operationID"), "op-1")
        XCTAssertNil(server.requests[1].bodyField("operationID"))
    }

    func testMoneyRouteErrorsAreOnlyDefiniteForExplicit4xx() async throws {
        let cases: [(String, Int, String, ServiceError)] = [
            ("authorize", 503, #"{"error":"authorization_uncertain"}"#, .uncertain(.lxt6)),
            ("settle", 503, #"{"error":"settlement_uncertain"}"#, .uncertain(.lxt6)),
            ("authorize", 400, "not json", .uncertain(.lxt6)),
            ("authorize", 200, "not json", .uncertain(.lxt6)),
            ("authorize", 200, #"{"machineID":"11223344"}"#, .uncertain(.lxt6)),
            ("settle", 200, #"{"settled":false}"#, .uncertain(.lxt6)),
            ("authorize", 409, #"{"error":"water_unresolved"}"#, .rejected(.lxt6, code: "water_unresolved", message: "上次结算还没确认，先核对它。")),
            ("authorize", 403, #"{"error":"transactions_not_enabled"}"#, .rejected(.lxt6, code: "transactions_not_enabled", message: "本校暂未开放")),
            ("settle", 401, #"{"error":"login_required"}"#, .sessionExpired(.lxt6)),
        ]
        for (route, status, body, expected) in cases {
            let server = StubServer()
            server.respond("POST", host + "/v1/" + route, status: status, body: json(body))
            let c = client(server, grant: grant)
            await Golden.expectError(expected) {
                if route == "authorize" { _ = try await c.authorize(Golden.binding, frame: Golden.frame) }
                else { _ = try await c.settle(Golden.binding, frame: Golden.frame) }
            }
            XCTAssertEqual(server.requests.count, 1, "\(route) \(status) not retried")
        }
    }

    func testBootstrapValidatesPathAgainstTheAddress() async throws {
        let levels = #"[[{"id":"c","name":"星湖校区"}],[{"id":"b","name":"9栋"}],[{"id":"f","name":"一楼"}],[{"id":"r","name":"199"}]]"#
        let path = #"[{"id":"c","name":"星湖校区"},{"id":"b","name":"9栋"},{"id":"f","name":"一楼"},{"id":"r","name":"199"}]"#
        let ok = #"{"levels":\#(levels),"path":\#(path),"matched":true,"transactionsEnabled":false,"machines":[{"id":"11223344","name":"m","mac":"x"}]}"#
        let server = StubServer()
        server.respond("POST", host + "/v1/bootstrap", body: json(ok), times: 1)
        let c = client(server, grant: grant)
        let b = try await c.bootstrap(residence: "星湖校区9栋9号1层199房")
        XCTAssertTrue(b.matched)
        XCTAssertFalse(b.transactionsEnabled)
        XCTAssertEqual(b.machines.map(\.machineId), ["11223344"])

        server.respond("POST", host + "/v1/bootstrap", body: json(ok), times: 1)
        await Golden.expectError(.malformed(.lxt6, "path")) { _ = try await c.bootstrap(residence: "星湖校区9栋9号1层198房") }

        server.respond("POST", host + "/v1/bind", body: json(#"{"bound":true,"machineID":"11223344"}"#), times: 1)
        try await c.bind(room: "r", machineID: "11223344")
        server.respond("POST", host + "/v1/bind", body: json(#"{"bound":true,"machineID":"99999999"}"#), times: 1)
        await Golden.expectError(.malformed(.lxt6, "bound")) { try await c.bind(room: "r", machineID: "11223344") }
    }
}

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

    func testLoaderResolvesAllThreeSources() async throws {
        let validData = Data(valid.utf8)
        let loader = WaterProfileLoader(bundled: { validData }, imported: { $0 == "mine.waterconfig" ? validData : nil })
        guard case .local(let p, .bundled) = try await loader.resolve(.bundled) else { return XCTFail() }
        XCTAssertEqual(p.bleName, "fixture-ble")
        guard case .local(_, .imported) = try await loader.resolve(.imported(fileName: "mine.waterconfig")) else { return XCTFail() }
        let endpoint = URL(string: "https://campus-api.070688.xyz")!
        let remote = try await loader.resolve(.accessService(endpoint: endpoint))
        XCTAssertEqual(remote, .remote(endpoint: endpoint))
        XCTAssertFalse(WaterProfileSource.accessService(endpoint: endpoint).signsLocally)

        let insecure = WaterProfileSource.accessService(endpoint: URL(string: "http://example.invalid")!)
        await assertProfileError(.unreadable(insecure)) { _ = try await loader.resolve(insecure) }
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
        let grant = WaterAccessGrant(token: "t", campusOwner: "o", expiresAt: 1, bleName: "b", typeID: 1, version: 3)
        let binding = WaterBinding(studentId: "S1", schoolId: "20021", machineId: "1a2b3c4d", roomId: "r", roomLabel: "9栋 199",
                                   machineName: "9-901", peripheralID: "P", access: grant)
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
