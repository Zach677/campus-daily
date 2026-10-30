import Foundation

// MARK: - Credentials (descriptions never show secret values)

/// Portal `X-Id-Token` (from `localStorage.token` after the web login, or the CAS ticket's
/// `idToken` after a password login, which also says when it expires).
public struct PortalToken: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    /// From the token's own `exp` claim; nil when unknown (web login).
    public var expiresAt: Date?
    /// When this app got it (set when it is first saved); only for the credential-lifetime log.
    public var obtainedAt: Date?
    public init(_ value: String, expiresAt: Date? = nil, obtainedAt: Date? = nil) {
        self.value = value; self.expiresAt = expiresAt; self.obtainedAt = obtainedAt
    }
    public var description: String { "PortalToken(<redacted>)" }
    public var debugDescription: String { description }
}

/// The school account the user signed in with. `password` is present only when the user chose
/// to save it; `paused` is set when an automatic sign-in with it failed, so it is not tried
/// again until the user signs in or saves a password again.
public struct SchoolAccount: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var account: String
    public var password: String?
    /// The saved password was refused (or the login hit something else): automatic sign-in
    /// stops until the user signs in or enters the password again.
    public var paused: Bool
    /// When an automatic login sent the password and heard nothing back. The school may have
    /// counted it, so automatic logins wait `holdAfterNoAnswer` from then.
    public var unansweredAt: Date?

    /// How long automatic logins wait after one that got no answer (30 failures lock the account).
    public static let holdAfterNoAnswer: TimeInterval = 6 * 3600

    public init(account: String, password: String? = nil, paused: Bool = false, unansweredAt: Date? = nil) {
        self.account = account; self.password = password; self.paused = paused; self.unansweredAt = unansweredAt
    }
    /// The saved password, unless automatic sign-in is paused.
    public var usablePassword: String? { paused ? nil : password.flatMap { $0.isEmpty ? nil : $0 } }
    /// The saved password for an automatic login at `now`: none while paused or while holding
    /// off after a login that got no answer.
    public func automaticPassword(at now: Date) -> String? {
        if let unansweredAt, now < unansweredAt.addingTimeInterval(Self.holdAfterNoAnswer) { return nil }
        return usablePassword
    }
    /// Automatic sign-in is held off right now after a login with no answer.
    public func isHolding(at now: Date) -> Bool {
        guard password != nil, !paused, let unansweredAt else { return false }
        return now < unansweredAt.addingTimeInterval(Self.holdAfterNoAnswer)
    }
    /// What Settings › 学校账号 shows about automatic sign-in.
    public enum AutoLogin: Sendable, Equatable {
        /// No saved password.
        case off
        /// The saved password is used when the card session runs out.
        case on
        /// The saved password was refused (or the login hit something else); the user has to
        /// enter it again.
        case pausedRefused
        /// A login got no answer; automatic logins resume by themselves after the hold.
        case pausedNoAnswer
    }

    public func autoLogin(at now: Date) -> AutoLogin {
        guard let password, !password.isEmpty else { return .off }
        if paused { return .pausedRefused }
        return isHolding(at: now) ? .pausedNoAnswer : .on
    }

    /// For display: first two and last two characters, the rest hidden.
    public var masked: String {
        let chars = Array(account)
        guard chars.count > 4 else { return String(repeating: "•", count: max(chars.count, 1)) }
        return String(chars.prefix(2)) + String(repeating: "•", count: chars.count - 4) + String(chars.suffix(2))
    }
    public var description: String {
        "SchoolAccount(<redacted>, password: \(password == nil ? "none" : "saved"), paused: \(paused), unanswered: \(unansweredAt != nil))"
    }
    public var debugDescription: String { description }
}

/// Everything ecykt calls need. `syscustid`/`custid` are server ciphertexts that change on
/// every response: never compare them, always keep the latest.
public struct EcyktSession: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var token: String
    public var syscustid: String
    public var custid: String?
    /// Stable card identity (`custunionid`), used to pick the same card again.
    public var cardUnionID: String?
    public var areacode: String
    public var userAgent: String
    /// When this token was minted (exchange or web sign-in), and when the liveness check last
    /// accepted it. Not secret; only for the credential-lifetime log.
    public var obtainedAt: Date?
    public var lastAliveAt: Date?

    public init(token: String, syscustid: String, custid: String? = nil, cardUnionID: String? = nil,
                areacode: String = EcyktSession.defaultAreacode, userAgent: String = EcyktSession.defaultUserAgent,
                obtainedAt: Date? = nil) {
        self.token = token
        self.syscustid = syscustid
        self.custid = custid
        self.cardUnionID = cardUnionID
        self.areacode = areacode
        self.userAgent = userAgent
        self.obtainedAt = obtainedAt
    }

    public static let defaultAreacode = "450010"
    public static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    public var description: String { "EcyktSession(<redacted>, areacode: \(areacode), hasCard: \(custid != nil))" }
    public var debugDescription: String { description }
}

/// Answer of `csalogintoken` / `loginBySysId`.
public struct EcyktLogin: Sendable, Equatable, CustomStringConvertible {
    public var syscustid: String
    public var token: String
    public var isbind: Int
    public var status: String?
    public init(syscustid: String, token: String, isbind: Int, status: String? = nil) {
        self.syscustid = syscustid; self.token = token; self.isbind = isbind; self.status = status
    }
    public var description: String { "EcyktLogin(<redacted>, isbind: \(isbind))" }
}

/// One card from `getSysBindCustInfo`. `raw` is the server object (needed verbatim for the
/// recharge page's `custInfo`).
public struct BoundCard: Sendable, Equatable, Codable, CustomStringConvertible {
    public var custid: String
    public var unionID: String?
    public var displayName: String
    public var areaName: String?
    public var raw: JSONValue
    public init(custid: String, unionID: String?, displayName: String, areaName: String?, raw: JSONValue) {
        self.custid = custid; self.unionID = unionID; self.displayName = displayName; self.areaName = areaName; self.raw = raw
    }
    public var description: String { "BoundCard(<redacted>)" }
}

// MARK: - Portal

/// `getMyInfo.gydz`, kept raw plus parsed (nil when the school's string has another shape).
public struct PortalResidence: Sendable, Equatable, Codable {
    public var raw: String
    public var address: DormAddress?
    public init(raw: String) { self.raw = raw; self.address = DormAddress.parse(raw) }
}

// MARK: - Electricity

/// A node of the electricity directory (campus → apartment → building → floor → room).
public struct PowerNode: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// One `getMeterStatus` row. All server fields are strings; numbers are parsed strictly.
public struct Meter: Sendable, Equatable, Codable {
    public var comAddress: String
    /// `piplineName`, e.g. "99栋991".
    public var name: String
    public var leftMoney: Money?
    public var remainingKWh: Decimal?
    public var dailyUseKWh: Decimal?
    public var price: Decimal?
    public var online: Bool?
    public var switchState: String?
    public var updatedAt: String?

    public init(comAddress: String, name: String, leftMoney: Money? = nil, remainingKWh: Decimal? = nil,
                dailyUseKWh: Decimal? = nil, price: Decimal? = nil, online: Bool? = nil,
                switchState: String? = nil, updatedAt: String? = nil) {
        self.comAddress = comAddress; self.name = name; self.leftMoney = leftMoney
        self.remainingKWh = remainingKWh; self.dailyUseKWh = dailyUseKWh; self.price = price
        self.online = online; self.switchState = switchState; self.updatedAt = updatedAt
    }
}

/// The saved meter: the directory node to query plus the meter's `comAddress`.
/// `nodeIsRoom` = the node is the room itself (1 row); otherwise it is a wider node
/// (campus) and the row is picked by `comAddress`.
public struct MeterBinding: Sendable, Equatable, Codable {
    public var nodeID: String
    public var comAddress: String
    public var label: String
    public var nodeIsRoom: Bool
    public init(nodeID: String, comAddress: String, label: String, nodeIsRoom: Bool) {
        self.nodeID = nodeID; self.comAddress = comAddress; self.label = label; self.nodeIsRoom = nodeIsRoom
    }
}

// MARK: - Card records

public struct CardRecord: Sendable, Equatable, Codable {
    public var date: String      // yyyyMMdd (transdate)
    public var time: String      // HHmmss (transtime)
    public var title: String     // transname
    public var amount: Money
    public var balanceAfter: Money?
    /// Server `dcflag` (direction flag) as given.
    public var direction: String?
    public init(date: String, time: String, title: String, amount: Money, balanceAfter: Money?, direction: String?) {
        self.date = date; self.time = time; self.title = title; self.amount = amount
        self.balanceAfter = balanceAfter; self.direction = direction
    }
}

public struct CardRecordPage: Sendable, Equatable {
    public var total: Int
    public var rows: [CardRecord]
    public init(total: Int, rows: [CardRecord]) { self.total = total; self.rows = rows }
}

// MARK: - Profile

/// Non-secret school profile (still kept in the Keychain: it is personal).
public struct SchoolProfile: Sendable, Equatable, Codable {
    public var residence: PortalResidence?
    public var meter: MeterBinding?
    public init(residence: PortalResidence? = nil, meter: MeterBinding? = nil) {
        self.residence = residence; self.meter = meter
    }
}
