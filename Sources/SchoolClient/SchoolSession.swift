import Foundation
import DailyCore
import DailyHTTP

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

public struct RefreshReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case ok
        /// The user must sign in again (ecykt dead and no silent re-exchange possible/working).
        case needsLogin(ServiceError)
        /// The liveness check failed for another reason (offline, …).
        case failed(ServiceError)
        case notSignedIn
    }
    public var outcome: Outcome
    public var snapshot: HomeSnapshot
    public var reexchanged: Bool
    public var snapshotSaved: Bool
}

public struct SignInSummary: Sendable, Equatable {
    public var cardholder: String
    public var residence: PortalResidence?
}

/// Runs the school session: liveness, silent re-exchange, refresh, electricity resolution,
/// recharge web sessions. Persists through `SchoolVault` / `SnapshotStoring`.
public actor SchoolSession {
    let portal: PortalClient
    let ecykt: EcyktClient
    let vault: SchoolVault
    let snapshots: SnapshotStoring
    let now: @Sendable () -> Date
    /// Upper bound on directory calls when locating the room node.
    static let maxDirectoryCalls = 40

    public init(portal: PortalClient, ecykt: EcyktClient, vault: SchoolVault, snapshots: SnapshotStoring,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.portal = portal; self.ecykt = ecykt; self.vault = vault; self.snapshots = snapshots; self.now = now
    }

    // MARK: Sign-in

    /// Native path after the CAS WebView produced the portal token: dorm address, ticket,
    /// ecykt exchange, bound card. Saves everything on success.
    public func signIn(portalToken: PortalToken, userAgent: String = EcyktSession.defaultUserAgent) async throws -> SignInSummary {
        let residence = try? await portal.myInfo(portalToken)
        let session = try await exchangeSession(portalToken: portalToken, userAgent: userAgent, previous: nil)
        let (card, updated) = try await liveCard(session)
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

    /// Fallback while the ticket exchange is uncaptured (G6): adopt the
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
        let (card, updated) = try await liveCard(session)
        if let portalToken { try vault.savePortalToken(portalToken) }
        try vault.saveEcyktSession(updated)
        var residence: PortalResidence?
        if let portalToken, let r = try? await portal.myInfo(portalToken) {
            residence = r
            var profile = (try? vault.profile()) ?? SchoolProfile()
            if profile.residence?.address != r.address { profile.meter = nil }
            profile.residence = r
            try vault.saveProfile(profile)
        }
        return SignInSummary(cardholder: card.displayName, residence: residence)
    }

    public func signOut() throws {
        try vault.savePortalToken(nil)
        try vault.saveEcyktSession(nil)
        try vault.saveProfile(nil)
        try snapshots.saveSnapshot(.empty)
    }

    // MARK: Refresh

    /// Liveness (`getSysBindCustInfo`), at most one silent re-exchange (foreground only),
    /// then balance + meter in parallel. Never calls `loginBySysId`.
    public func refresh(inBackground: Bool) async -> RefreshReport {
        var snapshot = ((try? snapshots.loadSnapshot()) ?? nil) ?? .empty
        func finish(_ outcome: RefreshReport.Outcome, reexchanged: Bool) -> RefreshReport {
            let saved = (try? snapshots.saveSnapshot(snapshot)) != nil
            return RefreshReport(outcome: outcome, snapshot: snapshot, reexchanged: reexchanged, snapshotSaved: saved)
        }
        guard let stored = (try? vault.ecyktSession()) ?? nil else {
            snapshot = SchoolSnapshotReducer.reduce(snapshot, .sessionExpired(.sessionExpired(.ecykt), at: now()))
            return finish(.notSignedIn, reexchanged: false)
        }

        var reexchanged = false
        var live: (BoundCard, EcyktSession)
        do {
            live = try await liveCard(stored)
        } catch let e as ServiceError where e.isSessionExpired {
            guard !inBackground, let portalToken = (try? vault.portalToken()) ?? nil else {
                snapshot = SchoolSnapshotReducer.reduce(snapshot, .sessionExpired(e, at: now()))
                return finish(.needsLogin(e), reexchanged: false)
            }
            do {
                reexchanged = true
                let fresh = try await exchangeSession(portalToken: portalToken, userAgent: stored.userAgent, previous: stored)
                live = try await liveCard(fresh)
            } catch let e2 as ServiceError {
                if e2.isSessionExpired {
                    snapshot = SchoolSnapshotReducer.reduce(snapshot, .sessionExpired(e2, at: now()))
                    return finish(.needsLogin(e2), reexchanged: true)
                }
                // Re-exchange failed for another reason: the ecykt login is still known dead.
                snapshot = SchoolSnapshotReducer.reduce(snapshot, .sessionExpired(e, at: now()))
                return finish(.needsLogin(e), reexchanged: true)
            } catch {
                snapshot = SchoolSnapshotReducer.reduce(snapshot, .sessionExpired(e, at: now()))
                return finish(.needsLogin(e), reexchanged: true)
            }
        } catch let e as ServiceError {
            snapshot = SchoolSnapshotReducer.reduce(snapshot, .livenessFailed(e, at: now()))
            return finish(.failed(e), reexchanged: false)
        } catch {
            let e = ServiceError.offline
            snapshot = SchoolSnapshotReducer.reduce(snapshot, .livenessFailed(e, at: now()))
            return finish(.failed(e), reexchanged: false)
        }

        let (card, session) = live
        try? vault.saveEcyktSession(session)
        snapshot = SchoolSnapshotReducer.reduce(snapshot, .livenessOK(at: now()))

        let binding = ((try? vault.profile()) ?? nil)?.meter
        async let balanceResult = capture { try await self.ecykt.balance(session, custid: card.custid) }
        async let meterResult = readMeter(session, binding: binding)
        let (b, m) = await (balanceResult, meterResult)
        snapshot = SchoolSnapshotReducer.reduce(snapshot, .balance(b, at: now()))
        if let m {
            snapshot = SchoolSnapshotReducer.reduce(snapshot, .meter(m, at: now()))
            snapshot = SchoolSnapshotReducer.reduce(snapshot, .roomLabel(binding?.label))
        }
        return finish(.ok, reexchanged: reexchanged)
    }

    // MARK: Electricity

    /// Onboarding: one campus-wide `getMeterStatus`, match `piplineName == "<栋>栋<room>"`,
    /// then locate the room-level node so daily refreshes read 1 row. If the room node cannot
    /// be found, the campus node + `comAddress` is saved instead (wide read).
    public func resolveElectricity() async throws -> ElectricityResolution {
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        var profile = try vault.profile() ?? SchoolProfile()
        if profile.residence?.address == nil, let token = try vault.portalToken() {
            profile.residence = try await portal.myInfo(token)
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
        var profile = try vault.profile() ?? SchoolProfile()
        guard let address = profile.residence?.address else { throw ServiceError.malformed(.portal, "data.gydz") }
        let campuses = try await ecykt.buildings(session, parent: nil).filter { address.matchesCampus($0.name) }
        guard campuses.count == 1, let campus = campuses.first else { throw ServiceError.malformed(.ecykt, "campus") }
        profile.meter = MeterBinding(nodeID: campus.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: false)
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
    public func waterHandoff() async throws -> WaterHandoff {
        guard let stored = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let (card, live) = try await liveCard(stored)
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
        let (card, live) = try await liveCard(stored)
        let fresh = try await ecykt.freshLogin(live)
        var updated = live
        updated.syscustid = fresh.syscustid   // latest ciphertext, valid as input next time
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
