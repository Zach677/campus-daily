import Foundation
import CryptoKit
import DailyCore
import DailyHTTP

/// The project's hot-water access service (`services/access`, `config.access` mode). The
/// service holds the platform `secret`; the app gets a per-student bearer token from
/// `/v1/connect` (school session in, water identity out) and calls fixed routes only.
///
/// Read routes: `options`, `machines`, `bootstrap`, `bind`. Money routes: `authorize`, `settle`
/// (disabled server-side until on-device acceptance: `transactions_not_enabled`).
/// Money requests are never retried on another host.
public struct WaterAccessServiceClient: WaterDirectory, WaterGateway {
    let http: HTTPClient
    public let endpoint: URL
    /// Required for every route but `connect`.
    let grant: WaterAccessGrant?
    let operationID: @Sendable () -> String

    public static let defaultEndpoints = [URL(string: "https://campus-api.070688.xyz")!,
                                          URL(string: "https://campus-daily-access.jasonbeam-campus.workers.dev")!]
    public static let routes: Set<String> = ["connect", "bootstrap", "options", "machines", "bind", "authorize", "settle", "status"]

    public init(http: HTTPClient, endpoint: URL, grant: WaterAccessGrant? = nil,
                operationID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.http = http; self.endpoint = endpoint; self.grant = grant; self.operationID = operationID
    }

    public func with(grant: WaterAccessGrant) -> WaterAccessServiceClient {
        WaterAccessServiceClient(http: http, endpoint: endpoint, grant: grant, operationID: operationID)
    }

    // MARK: Health

    /// `GET /health` → `{service:"campus-daily-access", protocol:1, configured:true}`.
    public func isHealthy() async -> Bool {
        guard let url = URL(string: endpoint.absoluteString + "/health"),
              let r = try? await http.send(HTTPRequest(service: .lxt6, method: .get, url: url, bodyLimit: 4096, logName: "health")),
              r.status == 200, let root = try? JSONValue.parse(r.body) else { return false }
        return root["service"]?.text == "campus-daily-access" && root["protocol"]?.intValue == 1 && root["configured"] == .bool(true)
    }

    /// First endpoint whose `/health` answers as configured; probed before any POST.
    public static func firstHealthy(http: HTTPClient, candidates: [URL] = defaultEndpoints) async -> URL? {
        for url in candidates {
            if await WaterAccessServiceClient(http: http, endpoint: url).isHealthy() { return url }
        }
        return nil
    }

    // MARK: Session

    /// `/v1/connect` with the live school session. Returns the water identity and the grant.
    public func connect(_ s: EcyktSession, custid: String) async throws -> (WaterUser, WaterAccessGrant) {
        let root = try await call("connect", authorized: false, fields: [
            "syscustid": .string(s.syscustid), "acc_token": .string(s.token), "areacode": .string(s.areacode), "custid": .string(custid),
        ])
        guard let token = root["token"]?.text, token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
        else { throw ServiceError.malformed(.lxt6, "token") }
        guard let owner = root["campusOwner"]?.text, owner == Self.campusOwner(areacode: s.areacode, syscustid: s.syscustid)
        else { throw ServiceError.malformed(.lxt6, "campusOwner") }
        guard let expires = root["expiresAt"]?.intValue, expires > 0 else { throw ServiceError.malformed(.lxt6, "expiresAt") }
        guard let student = root["studentID"]?.text, LxtClient.isIdentifier(student) else { throw ServiceError.malformed(.lxt6, "studentID") }
        guard let school = root["schoolID"]?.text, LxtClient.isIdentifier(school) else { throw ServiceError.malformed(.lxt6, "schoolID") }
        guard let ble = root["bleName"]?.text, !ble.isEmpty, ble.utf8.count <= 64,
              ble.rangeOfCharacter(from: .controlCharacters) == nil else { throw ServiceError.malformed(.lxt6, "bleName") }
        guard let typeID = root["typeID"]?.intValue, (0...Int(Int32.max)).contains(typeID) else { throw ServiceError.malformed(.lxt6, "typeID") }
        guard let version = root["version"]?.intValue, (1...Int(Int32.max)).contains(version) else { throw ServiceError.malformed(.lxt6, "version") }
        return (WaterUser(studentId: student, schoolId: school),
                WaterAccessGrant(token: token, campusOwner: owner, expiresAt: Int64(expires), bleName: ble, typeID: typeID, version: version))
    }

    /// `sha256(areacode + "\0" + syscustid)` lower hex: ties the grant to the school login that made it.
    public static func campusOwner(areacode: String, syscustid: String) -> String {
        SHA256.hash(data: Data((areacode + "\u{0}" + syscustid).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Directory

    /// Ids returned here are opaque, account-bound cursors (signed by the service).
    public func areas(parent: String) async throws -> [AreaNode] {
        let root = try await call("options", fields: ["parent": .string(parent)])
        return try Self.options(root["options"], path: "options")
    }

    public func rooms(floor: String) async throws -> [AreaNode] { try await areas(parent: floor) }

    public func machines(room: String, schoolId: String) async throws -> [WaterMachine] {
        let root = try await call("machines", fields: ["room": .string(room)])
        return try Self.machineRows(root["machines"])
    }

    public struct Bootstrap: Sendable, Equatable {
        public var levels: [[AreaNode]]
        public var path: [AreaNode]
        public var machines: [WaterMachine]
        public var matched: Bool
        public var transactionsEnabled: Bool
    }

    /// `/v1/bootstrap`: the service walks the tree with the portal dorm address in one call.
    public func bootstrap(residence: String) async throws -> Bootstrap {
        let root = try await call("bootstrap", fields: ["residence": .string(residence)])
        guard let rawLevels = root["levels"]?.array, (1...4).contains(rawLevels.count) else { throw ServiceError.malformed(.lxt6, "levels") }
        let levels = try rawLevels.map { try Self.options($0, path: "levels") }
        let path = try Self.options(root["path"], path: "path")
        guard path.count <= levels.count, path.enumerated().allSatisfy({ levels[$0.offset].contains($0.element) })
        else { throw ServiceError.malformed(.lxt6, "path") }
        guard case .bool(let matched)? = root["matched"], matched == (path.count == 4) else { throw ServiceError.malformed(.lxt6, "matched") }
        guard case .bool(let enabled)? = root["transactionsEnabled"] else { throw ServiceError.malformed(.lxt6, "transactionsEnabled") }
        let machines = try Self.machineRows(root["machines"])
        if matched {
            guard let address = DormAddress.parse(residence), WaterOnboarding.pathMatches(path, address: address)
            else { throw ServiceError.malformed(.lxt6, "path") }
        } else if !machines.isEmpty {
            throw ServiceError.malformed(.lxt6, "machines")
        }
        return Bootstrap(levels: levels, path: path, machines: machines, matched: matched, transactionsEnabled: enabled)
    }

    /// `/v1/bind`: the service checks the controller belongs to the room.
    public func bind(room: String, machineID: String) async throws {
        let root = try await call("bind", fields: ["room": .string(room), "machineID": .string(machineID)])
        guard root["bound"] == .bool(true), root["machineID"]?.text == machineID else { throw ServiceError.malformed(.lxt6, "bound") }
    }

    // MARK: Money

    public func authorize(_ b: WaterBinding, frame: Data) async throws -> WaterAuthorization {
        guard WaterFrames.identity(frame) == b.machineId.uppercased() else { throw ServiceError.badRequest(.lxt6) }
        let root = try await call("authorize", stateChanging: true, fields: [
            "frame": .string(HexCoding.upper(frame)), "operationID": .string(operationID()),
        ])
        guard let machine = root["machineID"]?.text, let id = root["studentID"]?.text, HexCoding.isHex(id, bytes: 4),
              let hex = root["payload"]?.text, let payload = HexCoding.data(hex), payload.count == WaterFrames.authorizationLength
        else { throw ServiceError.uncertain(.lxt6) }
        return WaterAuthorization(machineID: machine.uppercased(), payload: payload, authorizationID: id.uppercased())
    }

    public func settle(_ b: WaterBinding, frame: Data) async throws -> WaterReceipt {
        guard WaterFrames.identity(frame) == b.machineId.uppercased() else { throw ServiceError.badRequest(.lxt6) }
        let root = try await call("settle", stateChanging: true, fields: ["frame": .string(HexCoding.upper(frame))])
        guard root["settled"] == .bool(true) else { throw ServiceError.uncertain(.lxt6) }
        return WaterReceipt.parse(pay: root["payFen"])
    }

    // MARK: Plumbing

    /// Service error codes → user sentences (from the existing clients).
    public static func message(for code: String) -> String {
        switch code {
        case "school_login_required", "school_login_expired", "access_expired", "login_required": return "学校登录过期了，重新登录一下。"
        case "transactions_not_enabled": return "本校暂未开放"
        case "water_unresolved": return "上次结算还没确认，先核对它。"
        case "wrong_device", "bind_required", "invalid_location": return "宿舍或水控要重新核对，到设置 › 宿舍里看看。"
        case "rate_limited": return "刷新得太频繁了，过一会儿再试。"
        default: return "暂时连不上热水平台，等一下再刷新。"
        }
    }

    /// Maps a non-200 answer. Money routes: only an explicit 4xx code is a definite answer;
    /// 5xx (incl. `authorization_uncertain`/`settlement_uncertain`) is `uncertain`.
    static func failure(status: Int, body: Data, stateChanging: Bool) -> ServiceError {
        let raw = (try? JSONValue.parse(body))?["error"]?.text ?? ""
        let code = raw.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil ? raw : "invalid_response"
        if stateChanging, !(400..<500).contains(status) || code == "invalid_response" { return .uncertain(.lxt6) }
        switch code {
        case "school_login_required", "school_login_expired": return .sessionExpired(.ecykt)
        case "access_expired", "login_required": return .sessionExpired(.lxt6)
        default: return .rejection(.lxt6, code: code, message: message(for: code))
        }
    }

    private func call(_ route: String, authorized: Bool = true, stateChanging: Bool = false,
                      fields: [String: JSONValue]) async throws -> JSONValue {
        guard Self.routes.contains(route), let url = URL(string: endpoint.absoluteString + "/v1/" + route) else {
            throw ServiceError.badRequest(.lxt6)
        }
        var headers: [String: String] = ["Accept": "application/json"]
        if authorized {
            guard let grant else { throw ServiceError.sessionExpired(.lxt6) }
            headers["Authorization"] = "Bearer " + grant.token
        }
        let req = HTTPRequest.postJSON(service: .lxt6, url: url, headers: headers, json: fields,
                                       bodyLimit: HTTPRequest.largeBodyLimit, isStateChanging: stateChanging, logName: route)
        let response = try await http.send(req)
        guard response.status == 200 else { throw Self.failure(status: response.status, body: response.body, stateChanging: stateChanging) }
        guard let root = try? JSONValue.parse(response.body), root.object != nil else {
            throw stateChanging ? ServiceError.uncertain(.lxt6) : ServiceError.malformed(.lxt6, "$")
        }
        return root
    }

    static func options(_ value: JSONValue?, path: String) throws -> [AreaNode] {
        guard let rows = value?.array, rows.count <= LxtEndpoints.maxListRows else { throw ServiceError.malformed(.lxt6, path) }
        let nodes = try rows.enumerated().map { i, row -> AreaNode in
            guard let id = row["id"]?.text, !id.isEmpty, id.count <= 1024,
                  let name = row["name"]?.text, !name.isEmpty, name.count <= 128 else { throw ServiceError.malformed(.lxt6, "\(path)[\(i)]") }
            return AreaNode(id: id, name: name)
        }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw ServiceError.malformed(.lxt6, path) }
        return nodes
    }

    static func machineRows(_ value: JSONValue?) throws -> [WaterMachine] {
        guard let rows = value?.array, rows.count <= LxtEndpoints.maxMachines else { throw ServiceError.malformed(.lxt6, "machines") }
        let machines = try rows.enumerated().map { i, row -> WaterMachine in
            guard let id = row["id"]?.text, HexCoding.isHex(id, bytes: 4),
                  let name = row["name"]?.text, let mac = row["mac"]?.text else { throw ServiceError.malformed(.lxt6, "machines[\(i)]") }
            return WaterMachine(machineId: id, name: name, mac: mac)
        }
        guard Set(machines.map(\.machineId)).count == machines.count else { throw ServiceError.malformed(.lxt6, "machines") }
        return machines
    }
}
