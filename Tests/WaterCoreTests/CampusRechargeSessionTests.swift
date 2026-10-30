import XCTest
@testable import WaterCore

/// Scripted school answers keyed by path; each request pops the next answer for its path.
private final class SchoolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [String:[(Int,String)]] = [:]
    nonisolated(unsafe) static var calls: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.calls.append(path)
        var queue = Self.script[path] ?? []
        let answer = queue.isEmpty ? (500,"{}") : queue.removeFirst()
        Self.script[path] = queue
        Self.lock.unlock()
        if answer.0 == -1 { client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url:request.url!,statusCode:answer.0,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(answer.1.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class CampusRechargeSessionTests: XCTestCase {
    private let login = "/ykt-mini/api/customer/loginBySysId"
    private let cards = "/ykt-mini/api/customer/getSysBindCustInfo"
    private let balance = "/ykt-mini/scanpay/getUserBalance"
    private func config() throws -> CampusConfig {
        try JSONDecoder().decode(CampusConfig.self,from:Data(#"{"syscustid":"saved-owner","acc_token":"test-token","areacode":"test-school","custid":"card-test","timestamp":"123"}"#.utf8))
    }
    private func provider() -> CampusProvider {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [SchoolStub.self]
        return CampusProvider(session:URLSession(configuration:options),retryDelay:.zero)
    }
    private func script(_ value: [String:[(Int,String)]]) {
        SchoolStub.lock.lock(); SchoolStub.script = value; SchoolStub.calls = []; SchoolStub.lock.unlock()
    }
    private var calls: [String] { SchoolStub.lock.lock(); defer { SchoolStub.lock.unlock() }; return SchoolStub.calls }
    private let okLogin = #"{"code":0,"data":{"syscustid":"rotated-owner","isbind":"1"}}"#
    private let okCards = #"{"code":0,"data":[{"custid":"card-test"}]}"#
    private let busy = #"{"code":500,"message":"系统繁忙，请稍后再试"}"#

    func testWorkingLoginIsUsedDirectly() async throws {
        script([login:[(200,okLogin)],cards:[(200,okCards)]])
        let session = try await provider().webSession(config:config())
        XCTAssertEqual(session.syscustid,"rotated-owner")
        XCTAssertEqual(calls,[login,cards])
    }
    func testRefusedLoginIsRetriedOnce() async throws {
        script([login:[(200,busy),(200,okLogin)],cards:[(200,okCards)]])
        let session = try await provider().webSession(config:config())
        XCTAssertEqual(session.syscustid,"rotated-owner")
        XCTAssertEqual(calls,[login,login,cards])
    }
    func testLoginRefusedTwiceButTokenStillReadsCardsUsesSavedIdentity() async throws {
        // The user report: balance works (loginBySysId refused, token fine) but recharge said 过期.
        script([login:[(200,busy),(200,#"{"code":1,"message":"登录已过期"}"#)],cards:[(200,okCards)]])
        let session = try await provider().webSession(config:config())
        XCTAssertEqual(session.syscustid,"saved-owner")
        XCTAssertEqual(session.custid,"card-test")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with:session.state) as? [String:Any])
        XCTAssertEqual(state["logintoken"] as? String,"test-token")
        XCTAssertEqual(calls,[login,login,cards])
    }
    func testExpiredOnlyWhenTheTokenIsRefusedEverywhere() async throws {
        script([login:[(200,busy),(200,busy)],cards:[(401,"")]])
        do { _ = try await provider().webSession(config:config()); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? CampusError,.expired) }
    }
    func testOtherCardsRefusalCarriesTheSchoolMessage() async throws {
        script([login:[(200,busy),(200,busy)],cards:[(200,busy)]])
        do { _ = try await provider().webSession(config:config()); XCTFail("must fail") }
        catch {
            XCTAssertEqual(error as? CampusError,.rejected(code:500,message:"系统繁忙，请稍后再试"))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,"学校提示：系统繁忙，请稍后再试")
        }
    }
    func testOfflineIsNotRetriedAndNotCalledExpired() async throws {
        script([login:[(-1,"")],cards:[(-1,"")]])
        do { _ = try await provider().webSession(config:config()); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? CampusError,.offline) }
        XCTAssertEqual(calls,[login,cards])
    }
    func testUnboundLoginIsNotReportedAsExpired() async throws {
        script([login:[(200,#"{"code":0,"data":{"syscustid":"rotated-owner","isbind":"0"}}"#)],cards:[(200,okCards)]])
        do { _ = try await provider().webSession(config:config()); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? CampusError,.unbound) }
    }
    func testSavedIdentityStillRejectsAnotherOwnersCard() async throws {
        script([login:[(200,busy),(200,busy)],cards:[(200,#"{"code":0,"data":[{"custid":"card-test","syscustid":"someone-else"}]}"#)]])
        do { _ = try await provider().webSession(config:config()); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? CampusError,.accountMismatch) }
    }
    func testBalanceStillWorksWhenLoginIsRefused() async throws {
        script([login:[(200,busy)],balance:[(200,#"{"code":0,"data":{"balance":"12.30"}}"#)]])
        let value = try await provider().balance(config:config())
        XCTAssertEqual(value,Decimal(string:"12.30"))
    }
}

final class CampusErrorCodingTests: XCTestCase {
    func testOnlyRealExpiryMapsToExpired() {
        func unwrap(_ json: String) -> CampusError? {
            do { _ = try CampusParser.unwrap(Data(json.utf8)); return nil } catch { return error as? CampusError }
        }
        XCTAssertEqual(unwrap(#"{"code":401}"#),.expired)
        XCTAssertEqual(unwrap(#"{"code":1,"message":"登录已过期，请重新登录"}"#),.expired)
        XCTAssertEqual(unwrap(#"{"code":1,"msg":"token无效"}"#),.expired)
        XCTAssertEqual(unwrap(#"{"code":500,"message":"系统繁忙"}"#),.rejected(code:500,message:"系统繁忙"))
        XCTAssertEqual(unwrap(#"{"code":-1}"#),.rejected(code:-1,message:""))
        XCTAssertEqual(unwrap(#"{"code":2,"message":"  多行\n消息  "}"#),.rejected(code:2,message:"多行消息"))
    }
    /// Snapshot JSON written by builds that used the copy itself as the Codable value.
    func testOldSnapshotWithCopyAsErrorStillDecodes() throws {
        let old = #"{"owner":"o","balance":25.8,"balanceFetchedAt":700000000,"cardError":"学校登录过期了，重新登录一下。","roomError":"暂时无法连接学校","powerError":"some copy that was edited later"}"#
        let value = try JSONDecoder().decode(CampusSnapshot.self,from:Data(old.utf8))
        XCTAssertEqual(value.cardError,.expired)
        XCTAssertEqual(value.roomError,.network)
        XCTAssertEqual(value.powerError,.response)
        XCTAssertEqual(value.balance,Decimal(string:"25.8"))
    }
    func testNewSnapshotUsesStableCodesAndRoundTrips() throws {
        var value = CampusSnapshot(owner:"o")
        value.cardError = .rejected(code:500,message:"系统繁忙"); value.roomError = .timedOut; value.powerError = .unbound
        let data = try JSONEncoder().encode(value)
        let text = String(decoding:data,as:UTF8.self)
        XCTAssertTrue(text.contains(#""roomError":"timedOut""#))
        XCTAssertFalse(text.contains("学校连接超时"))
        let back = try JSONDecoder().decode(CampusSnapshot.self,from:data)
        XCTAssertEqual(back.cardError,.rejected(code:500,message:"系统繁忙"))
        XCTAssertEqual(back.roomError,.timedOut)
        XCTAssertEqual(back.powerError,.unbound)
    }
    func testEveryCaseHasACodeThatDecodesBack() throws {
        for error in CampusError.simple {
            let data = try JSONEncoder().encode([error])
            XCTAssertEqual(try JSONDecoder().decode([CampusError].self,from:data),[error])
        }
        XCTAssertEqual(Set(CampusError.simple.map(\.code)).count,CampusError.simple.count)
    }
}

final class CampusSnapshotMergeTests: XCTestCase {
    func testEachPartKeepsTheNewerCopy() {
        let old = Date(timeIntervalSince1970:1000), new = Date(timeIntervalSince1970:2000)
        var app = CampusSnapshot(owner:"o"), widget = CampusSnapshot(owner:"o")
        app.recordBalance(.success(10),at:new)
        widget.recordBalance(.success(5),at:old)
        app.recordRoom(.success("101"),at:old)
        widget.recordRoom(.success("102"),at:new)
        widget.cardError = .network
        let merged = app.merged(with:widget)
        XCTAssertEqual(merged.balance,10); XCTAssertEqual(merged.balanceFetchedAt,new); XCTAssertNil(merged.cardError)
        XCTAssertEqual(merged.room,"102"); XCTAssertEqual(merged.roomFetchedAt,new)
        // Symmetric result for the widget's side.
        XCTAssertEqual(widget.merged(with:app).balance,10)
        XCTAssertEqual(widget.merged(with:app).room,"102")
    }
    func testErrorTravelsWithItsPartAndOtherOwnerIsIgnored() {
        var app = CampusSnapshot(owner:"o"), widget = CampusSnapshot(owner:"o")
        app.recordBalance(.success(10),at:Date(timeIntervalSince1970:1000))
        app.recordBalance(.failure(.expired))
        widget.recordBalance(.success(12),at:Date(timeIntervalSince1970:3000))
        XCTAssertEqual(app.merged(with:widget).balance,12)
        XCTAssertNil(app.merged(with:widget).cardError)
        var stranger = CampusSnapshot(owner:"x"); stranger.recordBalance(.success(99),at:Date(timeIntervalSince1970:9000))
        XCTAssertEqual(app.merged(with:stranger).balance,10)
        XCTAssertEqual(app.merged(with:nil).cardError,.expired)
    }
}
