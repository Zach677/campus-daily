import Foundation
import CryptoKit
#if DEBUG
import os
#endif

public enum CampusError: Error, LocalizedError, Sendable, Hashable {
    case configuration
    /// The school says the saved login is no longer valid (HTTP 401/403, or an expiry code/message).
    case expired
    case network, offline, timedOut, secureConnection, response, ambiguous
    /// The school answered and refused for a reason other than an expired login.
    /// `message` is the school's own sentence (trimmed, at most 80 characters, may be empty).
    case rejected(code: Int, message: String)
    /// The login answer says this account has no campus card bound.
    case unbound
    /// The bound card the school returned belongs to someone other than the login.
    case accountMismatch

    /// Stable identifier, used for persistence. Never change these strings.
    public var code: String {
        switch self {
        case .configuration: return "configuration"
        case .expired: return "expired"
        case .network: return "network"
        case .offline: return "offline"
        case .timedOut: return "timedOut"
        case .secureConnection: return "secureConnection"
        case .response: return "response"
        case .ambiguous: return "ambiguous"
        case .rejected: return "rejected"
        case .unbound: return "unbound"
        case .accountMismatch: return "accountMismatch"
        }
    }
    /// User-facing copy. Free to edit: nothing is decoded from it.
    public var message: String {
        switch self {
        case .configuration: return "请完成学校账号与宿舍设置"
        case .expired: return "学校登录过期了，重新登录一下。"
        case .network: return "暂时连不上学校，等一下再试。"
        case .offline: return "校园查询未联网，请检查本 App 的无线数据权限"
        case .timedOut: return "学校连接超时，稍后下拉重试"
        case .secureConnection: return "学校安全连接未建立，请检查网络和系统时间"
        case .response: return "学校未返回有效数据"
        case .ambiguous: return "宿舍或校园卡绑定不唯一，请在官方页面核对"
        case .rejected(_, let message):
            return message.isEmpty ? "学校这次没办成，等一下再试。" : "学校提示：" + message
        case .unbound: return "你的学校账号还没绑校园卡，先去学校那边绑好再来。"
        case .accountMismatch: return "读到的校园卡和登录的账号对不上，重新登录一下再试。"
        }
    }
    public var errorDescription: String? { message }

    /// Copy used as the Codable value before 0.8.0 (snapshots saved by older builds).
    static let legacyCopy: [String:CampusError] = [
        "请完成学校账号与宿舍设置": .configuration, "学校登录过期了，重新登录一下。": .expired,
        // Earlier .network copy; old snapshots still decode.
        "暂时无法连接学校": .network, "校园查询未联网，请检查本 App 的无线数据权限": .offline,
        "学校连接超时，稍后下拉重试": .timedOut, "学校安全连接未建立，请检查网络和系统时间": .secureConnection,
        "学校未返回有效数据": .response, "宿舍或校园卡绑定不唯一，请在官方页面核对": .ambiguous,
    ]
    static let simple: [CampusError] = [.configuration,.expired,.network,.offline,.timedOut,.secureConnection,
                                        .response,.ambiguous,.unbound,.accountMismatch]

    /// Server codes/messages that really mean "log in again". Anything else is `.rejected`.
    public static func fromServer(code: Int, message: String) -> CampusError {
        if code == 401 || code == 403 { return .expired }
        let pattern = "过期|失效|重新登录|请登录|请先登录|未登录|登录超时|token|令牌"
        if message.range(of:pattern, options:[.regularExpression,.caseInsensitive]) != nil { return .expired }
        return .rejected(code:code, message:message)
    }
    /// The school's message, cleaned for display: no control characters, at most 80 characters.
    static func displayMessage(_ root: [String:Any]) -> String {
        let raw = (root["message"] as? String) ?? (root["msg"] as? String) ?? ""
        let clean = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in:.whitespacesAndNewlines)
        return String(clean.prefix(80))
    }
}

extension CampusError: Codable {
    private enum Keys: String, CodingKey { case code, serverCode, message }
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            // Stable code (current), old copy (pre-code snapshots), or something unknown:
            // never fail the whole snapshot because of one error label.
            self = Self.simple.first { $0.code == text } ?? Self.legacyCopy[text] ?? .response
            return
        }
        let c = try decoder.container(keyedBy:Keys.self)
        let code = try c.decode(String.self, forKey:.code)
        if code == "rejected" {
            self = .rejected(code:try c.decodeIfPresent(Int.self, forKey:.serverCode) ?? 0,
                             message:try c.decodeIfPresent(String.self, forKey:.message) ?? "")
        } else { self = Self.simple.first { $0.code == code } ?? .response }
    }
    public func encode(to encoder: Encoder) throws {
        if case .rejected(let serverCode, let message) = self {
            var c = encoder.container(keyedBy:Keys.self)
            try c.encode(code, forKey:.code); try c.encode(serverCode, forKey:.serverCode); try c.encode(message, forKey:.message)
        } else {
            var c = encoder.singleValueContainer(); try c.encode(code)
        }
    }
}

public struct CampusConfig: Codable, Sendable {
    public var syscustid: String
    public var accToken: String
    public var areacode: String
    public var meterID: String
    public var buildingID: String
    public var custid: String
    public var userAgent: String
    public var timestamp: String
    public var dormRoom: String
    public var campusVersion: String
    public var portalDormAddress: String
    enum CodingKeys: String, CodingKey {
        case syscustid, accToken = "acc_token", areacode, meterID, buildingID, custid, userAgent, timestamp
        case dormRoom = "dorm_room", campusVersion = "campus_version", portalDormAddress = "portal_dorm_address"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, fallback: String = "") throws -> String {
            try c.decodeIfPresent(String.self, forKey: key) ?? fallback
        }
        syscustid = try text(.syscustid); accToken = try text(.accToken)
        areacode = try text(.areacode, fallback: "450010")
        meterID = try text(.meterID)
        buildingID = try text(.buildingID); custid = try text(.custid)
        userAgent = try text(.userAgent); timestamp = try text(.timestamp)
        dormRoom = try text(.dormRoom); campusVersion = try text(.campusVersion, fallback: "v1.1.55")
        portalDormAddress = try text(.portalDormAddress)
    }
    public func validate() throws {
        let values = [syscustid,accToken,areacode,meterID,buildingID,custid,userAgent,timestamp,dormRoom,campusVersion,portalDormAddress]
        guard !syscustid.isEmpty, !accToken.isEmpty, !areacode.isEmpty,
              values.allSatisfy({ $0.utf8.count <= 2048 && !$0.contains("\n") && !$0.contains("\r") }),
              dormRoom.count <= 80 else { throw CampusError.configuration }
    }
    public var cacheIdentity: String {
        SHA256.hash(data: Data(([syscustid,areacode,custid,buildingID,dormRoom] + (meterID.isEmpty ? [] : [meterID])).joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public struct CampusSnapshot: Codable, Sendable {
    public var owner: String
    public var balance: Decimal?
    public var balanceFetchedAt: Date?
    public var room: String?
    public var roomFetchedAt: Date?
    public var cardError: CampusError?
    public var roomError: CampusError?
    public var electricity: CampusElectricity?
    public var powerFetchedAt: Date?
    public var powerError: CampusError?
    public init(owner: String) { self.owner = owner }
    public mutating func recordPower(_ result: Result<CampusElectricity,CampusError>, at date: Date = Date()) {
        switch result {
        case .success(let value): electricity = value; powerFetchedAt = date; powerError = nil
        case .failure(let error): powerError = error
        }
    }
    public func powerIsStale(at date: Date = Date()) -> Bool {
        guard let stamp = powerFetchedAt else { return true }
        return powerError != nil || date.timeIntervalSince(stamp) > 1200 || date < stamp
    }
    public func balanceIsStale(at date: Date = Date()) -> Bool {
        guard let stamp = balanceFetchedAt else { return true }
        return cardError != nil || date.timeIntervalSince(stamp) > 1200 || date < stamp
    }
    public mutating func recordBalance(_ result: Result<Decimal, CampusError>, at date: Date = Date()) {
        switch result {
        case .success(let value): balance = value; balanceFetchedAt = date; cardError = nil
        case .failure(let error): cardError = error
        }
    }
    /// Combines two copies of the same owner's snapshot (the app's and the widget's), keeping each
    /// part (card, room, power) from whichever copy fetched it more recently. A part's error goes
    /// with its value. Ties keep `self`. Another owner's snapshot is ignored.
    public func merged(with other: CampusSnapshot?) -> CampusSnapshot {
        guard let other, other.owner == owner else { return self }
        var result = self
        func newer(_ theirs: Date?, _ ours: Date?) -> Bool { (theirs ?? .distantPast) > (ours ?? .distantPast) }
        if newer(other.balanceFetchedAt, balanceFetchedAt) {
            result.balance = other.balance; result.balanceFetchedAt = other.balanceFetchedAt; result.cardError = other.cardError
        }
        if newer(other.roomFetchedAt, roomFetchedAt) {
            result.room = other.room; result.roomFetchedAt = other.roomFetchedAt; result.roomError = other.roomError
        }
        if newer(other.powerFetchedAt, powerFetchedAt) {
            result.electricity = other.electricity; result.powerFetchedAt = other.powerFetchedAt; result.powerError = other.powerError
        }
        return result
    }
    public mutating func recordRoom(_ result: Result<String, CampusError>, at date: Date = Date()) {
        switch result {
        case .success(let value): room = value; roomFetchedAt = date; roomError = nil
        case .failure(let error): roomError = error
        }
    }
}

public enum CampusParser {
    public static func unwrap(_ bytes: Data) throws -> Any {
        guard bytes.count <= 65536, let root = try? JSONSerialization.jsonObject(with: bytes) as? [String:Any],
              let code = root["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID() else { throw CampusError.response }
        guard code.doubleValue == 0 else {
            throw CampusError.fromServer(code:Int(exactly:code.doubleValue) ?? -1, message:CampusError.displayMessage(root))
        }
        guard let data = root["data"], !(data is NSNull) else { throw CampusError.response }
        if let text = data as? String, let raw = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed) { return parsed }
        return data
    }
    public static func amount(_ input: Any) throws -> Decimal {
        let raw: String
        if let number = input as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { throw CampusError.response }
            raw = number.stringValue
        } else if let text = input as? String { raw = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { throw CampusError.response }
        guard raw.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, abs(value) <= Decimal(1_000_000_000) else { throw CampusError.response }
        return value
    }
    public static func balance(_ input: Any) throws -> Decimal {
        try amount((input as? [String:Any])?["balance"] ?? input)
    }
    public static func room(_ input: Any) throws -> String {
        var data = input
        if let meters = data as? [Any] {
            guard meters.count == 1 else { throw CampusError.ambiguous }
            data = meters[0]
        }
        guard let meter = data as? [String:Any] else { throw CampusError.response }
        for key in ["piplineName","roomName"] {
            if let value = meter[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               value.count <= 80 { return value }
        }
        throw CampusError.response
    }
}

@MainActor public final class CampusProvider {
    public nonisolated static let base = "https://ecykt.gdbtu.edu.cn"
    static let loginPath = "/ykt-mini/api/customer/loginBySysId"
    static let cardsPath = "/ykt-mini/api/customer/getSysBindCustInfo"
    private let session: URLSession
    private let retryDelay: Duration
    public init(session: URLSession? = nil, retryDelay: Duration = .seconds(1)) {
        self.retryDelay = retryDelay
        if let session { self.session = session }
        else {
            let options = URLSessionConfiguration.ephemeral
            options.timeoutIntervalForRequest = 12; options.timeoutIntervalForResource = 18
            options.httpShouldSetCookies = false; options.urlCache = nil
            self.session = URLSession(configuration: options, delegate: NoRedirect(), delegateQueue: nil)
        }
    }
    /// - Parameter trace: DEBUG only: a short label; when set, the school's code and (redacted)
    ///   message are logged and appended to `CampusCache/recharge-diagnostics.json`.
    private func call(_ path: String, payload: [String:Any], config: CampusConfig, power: Bool = false, trace: String? = nil) async throws -> Any {
        try config.validate()
        let allowed = [Self.loginPath, Self.cardsPath,
                       "/ykt-mini/scanpay/getUserBalance", "/ykt-mini/api/electricnew/service"]
        guard allowed.contains(path) else { throw CampusError.configuration }
        var body: [String:Any] = ["syscustid":config.syscustid, "acc_token":config.accToken]
        payload.forEach { body[$0.key] = $0.value }
        if !config.timestamp.isEmpty { body["timestamp"] = config.timestamp }
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.base, forHTTPHeaderField: "Origin")
        request.setValue(config.accToken, forHTTPHeaderField: "acc_token")
        request.setValue(config.userAgent.isEmpty ? "Mozilla/5.0" : config.userAgent, forHTTPHeaderField: "User-Agent")
        let referer = power ? "/ykt-view/powernew?interfaceName=powernew_\(WaterProtocol.encodeForm(config.areacode))&isbind=1" : "/ykt-view/recharge?isbind=1"
        request.setValue(Self.base + referer, forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let bytes: Data, response: URLResponse
        do {
            try Task.checkCancellation()
            (bytes,response) = try await session.data(for: request)
            try Task.checkCancellation()
        }
        catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            #if DEBUG
            if let trace { CampusTrace.log("\(trace) network urlError=\((error as? URLError)?.errorCode ?? 0)") }
            else { print("CAMPUS_READ_NETWORK urlError=\((error as? URLError)?.errorCode ?? 0)") }
            #endif
            if let code = (error as? URLError)?.code {
                switch code {
                case .notConnectedToInternet, .dataNotAllowed: throw CampusError.offline
                case .timedOut: throw CampusError.timedOut
                case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .appTransportSecurityRequiresSecureConnection:
                    throw CampusError.secureConnection
                default: break
                }
            }
            throw CampusError.network
        }
        guard let http = response as? HTTPURLResponse else { throw CampusError.response }
        #if DEBUG
        if let trace { CampusTrace.record(trace:trace, path:path, status:http.statusCode, bytes:bytes, body:body, config:config) }
        #endif
        if http.statusCode == 401 || http.statusCode == 403 { throw CampusError.expired }
        guard http.statusCode == 200 else {
            #if DEBUG
            print("CAMPUS_READ_HTTP status=\(http.statusCode)")
            #endif
            throw CampusError.network
        }
        return try CampusParser.unwrap(bytes)
    }
    private func officialLogin(_ config: CampusConfig, trace: String?) async throws -> [String:Any] {
        let raw = try await call(Self.loginPath,
            payload:["areacode":config.areacode,"version":config.campusVersion,"appid":"wx7077a0b57d156efe","redirect":"/recharge?isbind=1"],
            config:config, trace:trace)
        guard let login = raw as? [String:Any] else { throw CampusError.response }
        return login
    }
    /// Official server-validated context for the school's recharge page.
    ///
    /// `loginBySysId` sometimes refuses while the same token still reads balances (the balance
    /// path ignores that refusal). So: retry it once; then read the bound cards with the same
    /// token. Only when that read also fails is its error (often `.expired`) shown. If the cards
    /// read works, the token is accepted, and the page is seeded with the identity saved at the
    /// official login, the same fallback the balance read uses. No financial route is invoked.
    public func webSession(config: CampusConfig) async throws -> CampusWebSession {
        var login: [String:Any]?
        var loginFailure: CampusError?
        for attempt in 1...2 {
            do { login = try await officialLogin(config, trace:attempt == 1 ? "recharge.login" : "recharge.login.retry"); break }
            catch let error as CampusError {
                loginFailure = error
                guard attempt == 1, error != .configuration, error != .offline else { break }
                try await Task.sleep(for:retryDelay)
            }
        }
        try Task.checkCancellation()
        let rawCards = try await call(Self.cardsPath,
            payload:["areacode":config.areacode,"version":config.campusVersion,"appid":"wx7077a0b57d156efe"],config:config,trace:"recharge.cards")
        guard let cards = rawCards as? [[String:Any]] else { throw CampusError.response }
        try Task.checkCancellation()
        if let login { return try CampusWebSession.create(config:config,login:login,cards:cards) }
        #if DEBUG
        CampusTrace.log("recharge.login failed (\(loginFailure?.code ?? "-")); cards read worked, using the saved login identity")
        #endif
        guard loginFailure != .configuration else { throw CampusError.configuration }
        return try CampusWebSession.create(config:config,login:CampusWebSession.savedLogin(config),cards:cards)
    }
    public func balance(config: CampusConfig) async throws -> Decimal {
        // Match the existing Scriptable flow; a captured card identity remains a fallback.
        var balanceID = config.syscustid
        #if DEBUG
        let trace: String? = "balance.login"
        #else
        let trace: String? = nil
        #endif
        var login: [String:Any]?
        do { login = try await officialLogin(config, trace:trace) }
        catch is CancellationError { throw CancellationError() }
        catch { /* Retain the existing captured-card fallback for other login-bridge errors. */ }
        if let id = login?["syscustid"] as? String, !id.isEmpty { balanceID = id }
        try Task.checkCancellation()
        var custid = config.custid
        if custid.isEmpty {
            let data = try await call(Self.cardsPath, payload: [
                "areacode":config.areacode,"version":config.campusVersion,"appid":"wx7077a0b57d156efe"], config: config)
            guard let list = data as? [[String:Any]], list.count == 1,
                  let id = list[0]["custid"] as? String, !id.isEmpty else { throw CampusError.ambiguous }
            custid = id
        }
        let data = try await call("/ykt-mini/scanpay/getUserBalance", payload: ["syscustid":balanceID,"custid":custid], config: config)
        return try CampusParser.balance(data)
    }
    public func powerBuildings(config: CampusConfig, parent: String? = nil) async throws -> [CampusPowerBuilding] {
        var payload: [String:Any] = ["server":"/api/getBuildingInfo","areacode":config.areacode]
        if let parent { payload["buildingID"] = parent }
        let data = try await call("/ykt-mini/api/electricnew/service",payload:payload,config:config,power:true)
        return try CampusElectricityParser.buildings(data)
    }
    public func powerMeters(config: CampusConfig, building: String) async throws -> [CampusElectricity] {
        guard !building.isEmpty else { throw CampusError.configuration }
        let data = try await call("/ykt-mini/api/electricnew/service",payload:["server":"/api/getMeterStatus","areacode":config.areacode,"buildingID":building],config:config,power:true)
        return try CampusElectricityParser.meters(data)
    }
    public func electricity(config: CampusConfig) async throws -> CampusElectricity {
        let meters = try await powerMeters(config:config,building:config.buildingID)
        return try CampusElectricityParser.select(meters,id:config.meterID)
    }
    public func room(config: CampusConfig) async throws -> String {
        if config.buildingID.isEmpty {
            guard !config.dormRoom.isEmpty else { throw CampusError.configuration }
            return config.dormRoom
        }
        let data = try await call("/ykt-mini/api/electricnew/service", payload: [
            "server":"/api/getMeterStatus", "areacode":config.areacode,"buildingID":config.buildingID], config: config, power: true)
        return try CampusParser.room(data)
    }
}

#if DEBUG
/// DEBUG-only trace of the school's answers for login/recharge calls: path, HTTP status, the
/// school's code and message (identifiers redacted), response key names. Never tokens or cookies.
enum CampusTrace {
    static let logger = Logger(subsystem:"WaterCore", category:"campus")
    static func log(_ text: String) { logger.debug("\(text, privacy:.public)") }
    @MainActor static func record(trace: String, path: String, status: Int, bytes: Data, body: [String:Any], config: CampusConfig) {
        let root = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
        var message = (root["message"] as? String) ?? (root["msg"] as? String) ?? ""
        for privateValue in [config.accToken,config.syscustid,config.custid,config.timestamp,config.areacode] where !privateValue.isEmpty {
            message = message.replacingOccurrences(of:privateValue,with:"[redacted]")
        }
        message = String(message.replacingOccurrences(of:"[0-9]{6,}",with:"[redacted]",options:.regularExpression).prefix(300))
        let code = (root["code"] as? NSNumber)?.stringValue ?? (root["code"].map { "\(type(of:$0))" } ?? "missing")
        var record: [String:Any] = ["trace":trace,"path":path,"httpStatus":status,"observedAt":ISO8601DateFormatter().string(from:Date()),
                                    "requestKeys":body.keys.sorted(),"message":message,"code":code]
        var detail = ""
        if let payload = root["data"] as? [String:Any] {
            record["dataKeys"] = payload.keys.sorted()
            record["ownerMatches"] = (payload["syscustid"] as? String) == config.syscustid
            detail = " dataKeys=\(payload.keys.sorted()) isbind=\(payload["isbind"].map { "\($0)" } ?? "missing")"
        }
        if let cards = root["data"] as? [[String:Any]] {
            record["cardCount"] = cards.count
            record["configuredCardMatches"] = cards.filter { ($0["custid"] as? String) == config.custid }.count
            detail = " cards=\(cards.count)"
        }
        log("\(trace) http=\(status) code=\(code) message=\(message)\(detail)")
        let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CampusCache",isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url = directory.appendingPathComponent("recharge-diagnostics.json")
        var history = (try? Data(contentsOf:url)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [[String:Any]] } ?? []
        history.append(record)
        if let data = try? JSONSerialization.data(withJSONObject:Array(history.suffix(8))) { try? data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
    }
}
#endif
