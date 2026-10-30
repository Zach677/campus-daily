import Foundation

public enum ElectricityResolution: Sendable, Equatable {
    /// Exactly one meter matched; the binding is saved.
    case matched(MeterBinding, Meter)
    /// Several meters carry this room name: manual pick among them.
    case chooseAmong([Meter])
    /// No meter with this room name (or no unique campus): manual picker over `buildings(parent:)`.
    case manualPicker
    /// No parsed portal dorm address.
    case noAddress
}

/// What one school read found. Campus only reports; the snapshot refresher turns this into
/// the shared home snapshot.
public struct SchoolReading: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case ok
        /// The user must sign in again (ecykt dead and no silent re-exchange possible/working).
        case needsLogin(ServiceError)
        /// The liveness check failed for another reason (offline, …).
        case failed(ServiceError)
        case notSignedIn
    }
    public var outcome: Outcome
    /// When the liveness check answered (or failed).
    public var checkedAt: Date
    /// Balance read; nil when it was not attempted.
    public var balance: Result<Money, ServiceError>?
    /// Room meter read; nil when no meter is bound or it was not attempted.
    /// `.success(nil)` = no meter at the saved node.
    public var meter: Result<Meter?, ServiceError>?
    public var roomLabel: String?
    /// When balance and meter answered.
    public var readAt: Date?
    public var reexchanged: Bool

    public init(outcome: Outcome, checkedAt: Date, balance: Result<Money, ServiceError>? = nil,
                meter: Result<Meter?, ServiceError>? = nil, roomLabel: String? = nil, readAt: Date? = nil,
                reexchanged: Bool = false) {
        self.outcome = outcome; self.checkedAt = checkedAt; self.balance = balance; self.meter = meter
        self.roomLabel = roomLabel; self.readAt = readAt; self.reexchanged = reexchanged
    }
}

public struct SignInSummary: Sendable, Equatable {
    public var cardholder: String
    public var residence: PortalResidence?
}

/// Runs the school session: liveness, silent re-exchange, refresh, electricity resolution,
/// recharge web sessions. Persists credentials through `SchoolVault`; it never writes the home
/// snapshot (that is the snapshot refresher's job).
public actor SchoolSession {
    let portal: PortalClient
    let ecykt: EcyktClient
    let vault: SchoolVault
    let now: @Sendable () -> Date
    /// Bumped by `signOut()`. Work that awaited the network checks it before writing the
    /// Keychain, so a sign-out in the middle is never undone by a late write.
    private var signOutGeneration = 0
    /// Upper bound on directory calls when locating the room node.
    static let maxDirectoryCalls = 40

    public init(portal: PortalClient, ecykt: EcyktClient, vault: SchoolVault,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.portal = portal; self.ecykt = ecykt; self.vault = vault; self.now = now
    }

    // MARK: Sign-in

    /// Native path after the CAS WebView produced the portal token: dorm address, ticket,
    /// ecykt exchange, bound card. Saves everything on success.
    public func signIn(portalToken: PortalToken, userAgent: String = EcyktSession.defaultUserAgent) async throws -> SignInSummary {
        let started = signOutGeneration
        let residence = try? await portal.myInfo(portalToken)
        let session = try await exchangeSession(portalToken: portalToken, userAgent: userAgent, previous: nil)
        let (card, updated) = try await liveCard(session)
        try ensureSignedIn(since: started)
        try vault.savePortalToken(portalToken)
        try vault.saveEcyktSession(updated)
        var profile = (try? vault.profile()) ?? SchoolProfile()
        if let residence {
            if profile.residence?.address != residence.address { profile.meter = nil }
            profile.residence = residence
        }
        try vault.saveProfile(profile)
        return SignInSummary(cardholder: card.displayName, residence: residence)
    }

    /// Fallback while the ticket exchange is uncaptured: adopt the
    /// `localStorage.elecampus_state` the official page wrote, then validate it.
    public func adoptWebState(_ elecampusState: Data, portalToken: PortalToken?,
                              userAgent: String = EcyktSession.defaultUserAgent) async throws -> SignInSummary {
        guard let root = try? JSONValue.parse(elecampusState),
              let token = (root["logintoken"] ?? root["loginInfo"]?["token"])?.text, !token.isEmpty,
              let sys = root["loginInfo"]?["syscustid"]?.text, !sys.isEmpty else {
            throw ServiceError.malformed(.ecykt, "elecampus_state")
        }
        let areacode = root["schoolid"]?.text ?? EcyktSession.defaultAreacode
        let session = EcyktSession(token: token, syscustid: sys, custid: root["custInfo"]?["custid"]?.text,
                                   cardUnionID: root["custInfo"]?["custunionid"]?.text, areacode: areacode, userAgent: userAgent)
        let started = signOutGeneration
        let (card, updated) = try await liveCard(session)
        try ensureSignedIn(since: started)
        if let portalToken { try vault.savePortalToken(portalToken) }
        try vault.saveEcyktSession(updated)
        var residence: PortalResidence?
        if let portalToken, let r = try? await portal.myInfo(portalToken) {
            try ensureSignedIn(since: started)
            residence = r
            var profile = (try? vault.profile()) ?? SchoolProfile()
            if profile.residence?.address != r.address { profile.meter = nil }
            profile.residence = r
            try vault.saveProfile(profile)
        }
        return SignInSummary(cardholder: card.displayName, residence: residence)
    }

    public func signOut() throws {
        signOutGeneration += 1
        try vault.savePortalToken(nil)
        try vault.saveEcyktSession(nil)
        try vault.saveProfile(nil)
    }

    // MARK: Refresh

    /// Liveness (`getSysBindCustInfo`), at most one silent re-exchange (foreground only),
    /// then balance + meter in parallel. Never calls `loginBySysId`.
    public func refresh(inBackground: Bool) async -> SchoolReading {
        guard let stored = (try? vault.ecyktSession()) ?? nil else {
            return SchoolReading(outcome: .notSignedIn, checkedAt: now())
        }
        let started = signOutGeneration

        var reexchanged = false
        var live: (BoundCard, EcyktSession)
        do {
            live = try await liveCard(stored)
        } catch let e as ServiceError where e.isSessionExpired {
            guard !inBackground, let portalToken = (try? vault.portalToken()) ?? nil else {
                return SchoolReading(outcome: .needsLogin(e), checkedAt: now())
            }
            do {
                reexchanged = true
                let fresh = try await exchangeSession(portalToken: portalToken, userAgent: stored.userAgent, previous: stored)
                live = try await liveCard(fresh)
            } catch let e2 as ServiceError where e2.isSessionExpired {
                return SchoolReading(outcome: .needsLogin(e2), checkedAt: now(), reexchanged: true)
            } catch {
                // Re-exchange failed for another reason: the ecykt login is still known dead.
                return SchoolReading(outcome: .needsLogin(e), checkedAt: now(), reexchanged: true)
            }
        } catch let e as ServiceError {
            return SchoolReading(outcome: .failed(e), checkedAt: now())
        } catch {
            return SchoolReading(outcome: .failed(.offline), checkedAt: now())
        }

        let (card, session) = live
        guard started == signOutGeneration else { return SchoolReading(outcome: .notSignedIn, checkedAt: now()) }
        try? vault.saveEcyktSession(session)
        let checkedAt = now()

        let binding = ((try? vault.profile()) ?? nil)?.meter
        async let balanceResult = capture { try await self.ecykt.balance(session, custid: card.custid) }
        async let meterResult = readMeter(session, binding: binding)
        let (b, m) = await (balanceResult, meterResult)
        guard started == signOutGeneration else { return SchoolReading(outcome: .notSignedIn, checkedAt: now()) }
        return SchoolReading(outcome: .ok, checkedAt: checkedAt, balance: b, meter: m,
                             roomLabel: m == nil ? nil : binding?.label, readAt: now(), reexchanged: reexchanged)
    }

    // MARK: Electricity

    /// Onboarding: one campus-wide `getMeterStatus`, match `piplineName == "<栋>栋<room>"`,
    /// then locate the room-level node so daily refreshes read 1 row. If the room node cannot
    /// be found, the campus node + `comAddress` is saved instead (wide read).
    public func resolveElectricity() async throws -> ElectricityResolution {
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = signOutGeneration
        var profile = try vault.profile() ?? SchoolProfile()
        if profile.residence?.address == nil, let token = try vault.portalToken() {
            profile.residence = try await portal.myInfo(token)
            try ensureSignedIn(since: started)
            try vault.saveProfile(profile)
        }
        guard let address = profile.residence?.address else { return .noAddress }

        let campuses = try await ecykt.buildings(session, parent: nil).filter { address.matchesCampus($0.name) }
        guard campuses.count == 1, let campus = campuses.first else { return .manualPicker }
        let rows = try await ecykt.meters(session, nodeID: campus.id, wide: true)
        let meter: Meter
        switch MeterMatcher.match(rows, address: address) {
        case .none: return .manualPicker
        case .many(let all): return .chooseAmong(all)
        case .one(let m): meter = m
        }

        var binding = MeterBinding(nodeID: campus.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: false)
        var found = meter
        if let located = try await locateRoomNode(session, campus: campus, address: address, comAddress: meter.comAddress) {
            binding = MeterBinding(nodeID: located.0.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: true)
            found = located.1
        }
        profile.meter = binding
        try ensureSignedIn(since: started)
        try vault.saveProfile(profile)
        return .matched(binding, found)
    }

    /// Manual choice from the picker (`buildings(parent:)` walk in the UI, then a meter row).
    public func chooseMeter(nodeID: String, meter: Meter, nodeIsRoom: Bool) throws {
        var profile = try vault.profile() ?? SchoolProfile()
        profile.meter = MeterBinding(nodeID: nodeID, comAddress: meter.comAddress, label: meter.name, nodeIsRoom: nodeIsRoom)
        try vault.saveProfile(profile)
    }

    /// Choice among several same-name meters (`.chooseAmong`): saved against the campus node
    /// (wide read, picked by `comAddress`).
    public func chooseMatchedMeter(_ meter: Meter) async throws {
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = signOutGeneration
        var profile = try vault.profile() ?? SchoolProfile()
        guard let address = profile.residence?.address else { throw ServiceError.malformed(.portal, "data.gydz") }
        let campuses = try await ecykt.buildings(session, parent: nil).filter { address.matchesCampus($0.name) }
        guard campuses.count == 1, let campus = campuses.first else { throw ServiceError.malformed(.ecykt, "campus") }
        profile.meter = MeterBinding(nodeID: campus.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: false)
        try ensureSignedIn(since: started)
        try vault.saveProfile(profile)
    }

    /// Manual picker: one level of the electricity directory (`nil` = campuses).
    public func directory(parent: String?) async throws -> [PowerNode] {
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        return try await ecykt.buildings(session, parent: parent)
    }

    /// Manual picker: the meters at a directory node.
    public func meterRows(nodeID: String) async throws -> [Meter] {
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        return try await ecykt.meters(session, nodeID: nodeID)
    }

    // MARK: Hot-water hand-off

    /// Liveness check, then `getSignData` for the bound card (hot-water onboarding only).
    public func showerHandoff() async throws -> ShowerHandoff {
        guard let stored = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = signOutGeneration
        let (card, live) = try await liveCard(stored)
        try ensureSignedIn(since: started)
        try? vault.saveEcyktSession(live)
        return try await ecykt.signData(live, custid: card.custid)
    }

    /// Walks campus → (apartment) → building → floor → room with name filters. Returns the
    /// room node whose meter has `comAddress`.
    func locateRoomNode(_ s: EcyktSession, campus: PowerNode, address: DormAddress, comAddress: String) async throws -> (PowerNode, Meter)? {
        var calls = 0
        // Stage 0: find building nodes, allowing one intermediate (apartment) level.
        var buildingNodes: [PowerNode] = []
        guard let level1 = try await directoryChildren(s, campus.id, calls: &calls) else { return nil }
        let direct = level1.filter { address.matchesBuilding($0.name) }
        if !direct.isEmpty {
            buildingNodes = direct
        } else {
            for apartment in level1 {
                guard let kids = try await directoryChildren(s, apartment.id, calls: &calls) else { return nil }
                buildingNodes += kids.filter { address.matchesBuilding($0.name) }
            }
        }
        var rooms: [PowerNode] = []
        for b in buildingNodes {
            guard let floors = try await directoryChildren(s, b.id, calls: &calls) else { return nil }
            for f in floors where address.matchesFloor(f.name) {
                guard let rs = try await directoryChildren(s, f.id, calls: &calls) else { return nil }
                rooms += rs.filter { address.matchesRoom($0.name) }
            }
        }
        for room in rooms.prefix(4) {
            let meters = try await ecykt.meters(s, nodeID: room.id)
            if let m = meters.first(where: { $0.comAddress == comAddress }) { return (room, m) }
        }
        return nil
    }

    /// One directory call, bounded by `maxDirectoryCalls` (nil = budget spent).
    private func directoryChildren(_ s: EcyktSession, _ id: String, calls: inout Int) async throws -> [PowerNode]? {
        guard calls < Self.maxDirectoryCalls else { return nil }
        calls += 1
        return try await ecykt.buildings(s, parent: id)
    }

    // MARK: Recharge

    /// Liveness check, then one `loginBySysId`; the fresh token goes into `logintoken`.
    public func rechargeSession(_ kind: RechargeKind) async throws -> RechargeWebSession {
        guard let stored = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = signOutGeneration
        let (card, live) = try await liveCard(stored)
        let fresh = try await ecykt.freshLogin(live)
        var updated = live
        updated.syscustid = fresh.syscustid   // latest ciphertext, valid as input next time
        try ensureSignedIn(since: started)
        try? vault.saveEcyktSession(updated)
        return try RechargeWebSessionBuilder.build(kind: kind, session: updated, fresh: fresh, card: card)
    }

    /// Re-reads the value the recharge confirmation compares (balance or room meter left money).
    public func readRechargeValue(_ kind: RechargeKind) async throws -> Money? {
        guard let s = try vault.ecyktSession(), let custid = s.custid else { throw ServiceError.sessionExpired(.ecykt) }
        switch kind {
        case .card: return try await ecykt.balance(s, custid: custid)
        case .electricity:
            guard let binding = try vault.profile()?.meter else { return nil }
            let rows = try await ecykt.meters(s, nodeID: binding.nodeID, wide: !binding.nodeIsRoom)
            return MeterMatcher.pick(rows, binding: binding)?.leftMoney
        }
    }

    // MARK: Helpers

    /// Work that awaited the network checks this before writing: a sign-out in the meantime
    /// wins, and the late result is dropped as if the session had expired.
    func ensureSignedIn(since started: Int) throws {
        guard started == signOutGeneration else { throw ServiceError.sessionExpired(.ecykt) }
    }

    /// `boundCards` + pick the saved card (by stable `custunionid`) or the first one.
    /// Updates the session with the latest `custid` ciphertext.
    func liveCard(_ s: EcyktSession) async throws -> (BoundCard, EcyktSession) {
        let cards = try await ecykt.boundCards(s)
        guard let card = cards.first(where: { $0.unionID != nil && $0.unionID == s.cardUnionID }) ?? cards.first else {
            throw ServiceError.rejected(.ecykt, code: "noCard", message: "这个账号还没有绑定校园卡")
        }
        var updated = s
        updated.custid = card.custid
        updated.cardUnionID = card.unionID
        return (card, updated)
    }

    func exchangeSession(portalToken: PortalToken, userAgent: String, previous: EcyktSession?) async throws -> EcyktSession {
        let url = try await portal.eCardTicketURL(portalToken)
        guard let ticket = CASTicket.extract(from: url) else { throw ServiceError.malformed(.portal, "data.pcUrl") }
        let areacode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "areacode" }?.value ?? previous?.areacode ?? EcyktSession.defaultAreacode
        let login = try await ecykt.exchange(ticket: ticket, areacode: areacode, userAgent: userAgent)
        return EcyktSession(token: login.token, syscustid: login.syscustid, custid: previous?.custid,
                            cardUnionID: previous?.cardUnionID, areacode: areacode, userAgent: userAgent)
    }

    nonisolated func readMeter(_ session: EcyktSession, binding: MeterBinding?) async -> Result<Meter?, ServiceError>? {
        guard let binding else { return nil }
        return await capture {
            let rows = try await self.ecykt.meters(session, nodeID: binding.nodeID, wide: !binding.nodeIsRoom)
            return MeterMatcher.pick(rows, binding: binding)
        }
    }

    nonisolated func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, ServiceError> {
        do { return .success(try await body()) }
        catch let e as ServiceError { return .failure(e) }
        catch { return .failure(.offline) }
    }
}
