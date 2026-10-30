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
    /// A different person than the one signed in before: the old dorm, meter and saved
    /// account were cleared first (the app clears its own per-person data too).
    public var switchedAccount: Bool
    public init(cardholder: String, residence: PortalResidence?, switchedAccount: Bool = false) {
        self.cardholder = cardholder; self.residence = residence; self.switchedAccount = switchedAccount
    }
}

/// Who is signed in: the card's stable `custunionid` and, after a form login, the account.
struct SignedInPerson: Sendable, Equatable {
    var cardUnionID: String?
    var account: String?

    enum Match: Sendable, Equatable { case same, different, unknown }

    /// The card decides when both sides have one; else the account; else nobody can tell.
    static func match(_ before: SignedInPerson?, cardUnionID: String?, account: String?) -> Match {
        guard let before else { return .unknown }
        if let a = before.cardUnionID, let b = cardUnionID { return a == b ? .same : .different }
        if let a = before.account, let b = account { return a == b ? .same : .different }
        return .unknown
    }
}

/// Runs the school session: liveness, silent re-exchange, refresh, electricity resolution,
/// recharge web sessions. Persists credentials through `SchoolVault`; it never writes the home
/// snapshot (that is the snapshot refresher's job).
public actor SchoolSession {
    let portal: PortalClient
    let ecykt: EcyktClient
    let vault: SchoolVault
    let passwordLogin: SchoolPasswordLogin?
    let now: @Sendable () -> Date
    /// Event names and measured ages only, never values (the credential-lifetime log).
    let diagnostic: @Sendable (String) -> Void
    /// Where the same lifetime lines are kept for the in-app diagnostics export.
    let credentialLog: CredentialLifetimeLog?
    /// Expiries already logged by this process, so a dead credential read again is logged once.
    private var loggedExpiries: Set<String> = []
    /// Bumped by `signOut()`. Work that awaited the network checks it before writing the
    /// Keychain, so a sign-out in the middle is never undone by a late write.
    private var signOutGeneration = 0
    /// Upper bound on directory calls when locating the room node.
    static let maxDirectoryCalls = 40

    public init(portal: PortalClient, ecykt: EcyktClient, vault: SchoolVault, passwordLogin: SchoolPasswordLogin? = nil,
                now: @escaping @Sendable () -> Date = Date.init, diagnostic: @escaping @Sendable (String) -> Void = { _ in },
                credentialLog: CredentialLifetimeLog? = nil) {
        self.portal = portal; self.ecykt = ecykt; self.vault = vault; self.passwordLogin = passwordLogin; self.now = now
        self.diagnostic = diagnostic; self.credentialLog = credentialLog
    }

    // MARK: Account and password

    /// Sign-in from the app's own form: one password login, then the same path as a portal
    /// token from the web page. The password is kept only when `savePassword` is on.
    /// Throws `SchoolLoginFailure` for the login itself, `ServiceError` for the steps after it.
    public func signIn(account: String, password: String, savePassword: Bool) async throws -> SignInSummary {
        let started = signOutGeneration
        let before = signedInPerson()
        let token = try await passwordLoginOnce(account: account, password: password)
        try ensureSignedIn(since: started)
        let summary = try await signIn(portalToken: token, account: account, before: before)
        try ensureSignedIn(since: started)
        try vault.saveAccount(SchoolAccount(account: account, password: savePassword ? password : nil))
        return summary
    }

    /// Settings › 学校账号 › 保存密码 / 重新输入密码: checks the password with one login before
    /// keeping it. It never switches person: an account other than the signed-in one is refused
    /// (`differentAccount`) without a login when the account is known, and after a web sign-in
    /// (account unknown) the login's card must be the signed-in card. A saved password clears
    /// any pause.
    public func savePassword(_ password: String, account given: String? = nil) async throws {
        let stored = (try? vault.account()) ?? nil
        if let known = stored?.account, let given, given != known { throw SchoolLoginFailure.differentAccount }
        guard let account = given ?? stored?.account, !account.isEmpty else {
            throw SchoolLoginFailure.wrongCredentials
        }
        let started = signOutGeneration
        let before = signedInPerson()
        let token = try await passwordLoginOnce(account: account, password: password)
        try ensureSignedIn(since: started)
        if stored?.account == nil, let current = (try? vault.ecyktSession()) ?? nil {
            // Web sign-in: only the card says whose login this was.
            let session = try await exchangeSession(portalToken: token, userAgent: current.userAgent, previous: current)
            let (card, updated) = try await liveCard(session)
            try ensureSignedIn(since: started)
            guard SignedInPerson.match(before, cardUnionID: card.unionID, account: nil) == .same else {
                throw SchoolLoginFailure.differentAccount
            }
            try vault.saveEcyktSession(updated)
        }
        try vault.savePortalToken(stamped(token))
        try vault.saveAccount(SchoolAccount(account: account, password: password))
    }

    /// Turning 保存密码 off: the password goes at once; the account name stays for display.
    public func forgetPassword() throws {
        guard let stored = try vault.account() else { return }
        try vault.saveAccount(SchoolAccount(account: stored.account))
    }

    /// The signed-in account (nil after a web sign-in, which never tells us the account).
    public func account() -> SchoolAccount? { (try? vault.account()) ?? nil }

    /// The person signed in now, or nil when nobody is.
    private func signedInPerson() -> SignedInPerson? {
        let session = (try? vault.ecyktSession()) ?? nil
        let account = (try? vault.account()) ?? nil
        guard session != nil || account != nil else { return nil }
        return SignedInPerson(cardUnionID: session?.cardUnionID, account: account?.account)
    }

    /// A different person signed in: drop the previous one's dorm, meter, saved account and
    /// tokens before the new ones are written. The login device id stays (same phone).
    private func clearPreviousPerson() throws {
        try vault.saveAccount(nil)
        try vault.savePortalToken(nil)
        try vault.saveEcyktSession(nil)
        try vault.saveProfile(nil)
    }

    private func passwordLoginOnce(account: String, password: String) async throws -> PortalToken {
        guard let passwordLogin else { throw SchoolLoginFailure.cannotLoginDirectly }
        return try await passwordLogin.login(account: account, password: password, visitorID: loginDeviceID())
    }

    /// A random 32-hex id, kept for this install so the school sees the same browser each time.
    private func loginDeviceID() -> String {
        if let id = (try? vault.loginDeviceID()) ?? nil, !id.isEmpty { return id }
        let id = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? vault.saveLoginDeviceID(id)
        return id
    }

    // MARK: Sign-in

    /// Native path after the CAS WebView produced the portal token: dorm address, ticket,
    /// ecykt exchange, bound card. Saves everything on success.
    public func signIn(portalToken: PortalToken, userAgent: String = EcyktSession.defaultUserAgent) async throws -> SignInSummary {
        try await signIn(portalToken: portalToken, account: nil, before: signedInPerson(), userAgent: userAgent)
    }

    /// A different person clears the previous one's data first. When the dorm address can't be
    /// read, the old dorm and meter are kept only if the card shows it is the same person.
    private func signIn(portalToken: PortalToken, account: String?, before: SignedInPerson?,
                        userAgent: String = EcyktSession.defaultUserAgent) async throws -> SignInSummary {
        let started = signOutGeneration
        let residence = try? await portal.myInfo(portalToken)
        let session = try await exchangeSession(portalToken: portalToken, userAgent: userAgent, previous: nil)
        let (card, updated) = try await liveCard(session)
        try ensureSignedIn(since: started)
        let match = SignedInPerson.match(before, cardUnionID: card.unionID, account: account)
        if match == .different { try clearPreviousPerson() }
        try vault.savePortalToken(stamped(portalToken))
        try vault.saveEcyktSession(updated)
        var profile = (try? vault.profile()) ?? SchoolProfile()
        if let residence {
            if profile.residence?.address != residence.address { profile.meter = nil }
            profile.residence = residence
        } else if match != .same {
            profile = SchoolProfile()
        }
        try vault.saveProfile(profile)
        return SignInSummary(cardholder: card.displayName, residence: residence, switchedAccount: match == .different)
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
                                   cardUnionID: root["custInfo"]?["custunionid"]?.text, areacode: areacode, userAgent: userAgent,
                                   obtainedAt: now())
        let started = signOutGeneration
        let before = signedInPerson()
        let (card, updated) = try await liveCard(session)
        try ensureSignedIn(since: started)
        let switched = SignedInPerson.match(before, cardUnionID: card.unionID, account: nil) == .different
        if switched { try clearPreviousPerson() }
        // The web page never tells us the account, so a saved password may belong to someone else.
        try vault.saveAccount(nil)
        if let portalToken { try vault.savePortalToken(stamped(portalToken)) }
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
        return SignInSummary(cardholder: card.displayName, residence: residence, switchedAccount: switched)
    }

    /// Some school items could not be deleted (item names only, never values).
    public struct SignOutFailure: Error, Sendable, Equatable {
        public var items: [String]
    }

    /// Deletes the saved password first (it sits in the shared group the widget reads), then
    /// everything else; the credentials' obtained/alive times go with their items. (The refresh
    /// lease is the refresher's: `SnapshotRefresher.clear()`.) A failed deletion doesn't stop the rest; the failures are reported
    /// together at the end.
    public func signOut() throws {
        signOutGeneration += 1
        loggedExpiries = []
        var failed: [String] = []
        let steps: [(String, () throws -> Void)] = [
            ("account", { try self.vault.saveAccount(nil) }),
            ("portalToken", { try self.vault.savePortalToken(nil) }),
            ("ecyktSession", { try self.vault.saveEcyktSession(nil) }),
            ("profile", { try self.vault.saveProfile(nil) }),
            ("loginDevice", { try self.vault.saveLoginDeviceID(nil) }),
        ]
        for (name, step) in steps {
            do { try step() } catch { failed.append(name) }
        }
        if !failed.isEmpty { throw SignOutFailure(items: failed) }
    }

    // MARK: Refresh

    /// Liveness (`getSysBindCustInfo`); when the card session is dead, at most one way back in,
    /// the same in the app (foreground or background) and in the widget: the portal token
    /// (unless it is known to have expired), else the saved password (one login, never retried;
    /// any refusal pauses it until the user signs in again). Then balance + meter in parallel.
    /// Never calls `loginBySysId`.
    ///
    /// Two processes share the stored session. `mayMint` is asked before each step that mints a
    /// session (portal exchange), sends the saved password, or writes a credential back (the
    /// refresher renews its cross-process lease there; false = another process took over or a
    /// sign-out removed the lease, so this read stops without touching anything more). With the lease held, a session another process
    /// stored meanwhile is used instead of minting. The session is written back only while the
    /// stored one is still the one this read started from: a sign-out or a newer session from
    /// the other process is never overwritten.
    public func refresh(inBackground: Bool, mayMint: @Sendable () async -> Bool = { true }) async -> SchoolReading {
        guard let stored = (try? vault.ecyktSession()) ?? nil else {
            return SchoolReading(outcome: .notSignedIn, checkedAt: now())
        }
        let started = signOutGeneration

        var reexchanged = false
        var base = stored
        var live: (BoundCard, EcyktSession)
        do {
            live = try await liveCard(stored)
        } catch let e as ServiceError where e.isSessionExpired {
            logExpired(.card, obtainedAt: stored.obtainedAt, lastAliveAt: stored.lastAliveAt)
            guard await mayMint() else { return SchoolReading(outcome: .failed(.timedOut), checkedAt: now()) }
            let current: EcyktSession?
            do { current = try vault.ecyktSession() } catch { return SchoolReading(outcome: .failed(.offline), checkedAt: now()) }
            guard let current else { return SchoolReading(outcome: .notSignedIn, checkedAt: now()) }
            if current.token != stored.token, let found = try? await liveCard(current) {
                // The other process renewed it while this one was reading: no second mint.
                base = current
                live = found
            } else {
                switch await renew(stored, firstError: e, since: started, mayMint: mayMint) {
                case .renewed(let found): reexchanged = true; live = found
                case .stopped(let reading): return reading
                }
            }
        } catch let e as ServiceError {
            return SchoolReading(outcome: .failed(e), checkedAt: now())
        } catch {
            return SchoolReading(outcome: .failed(.offline), checkedAt: now())
        }

        let card = live.0
        guard started == signOutGeneration else { return SchoolReading(outcome: .notSignedIn, checkedAt: now()) }
        let checkedAt = now()
        var alive = live.1
        alive.lastAliveAt = checkedAt
        switch await writeBack(alive, over: base, mayMint: mayMint) {
        case .signedOut: return SchoolReading(outcome: .notSignedIn, checkedAt: now())
        case .lostLease: return SchoolReading(outcome: .failed(.timedOut), checkedAt: now(), reexchanged: reexchanged)
        case .written, .kept: break
        }
        let session = alive

        let binding = ((try? vault.profile()) ?? nil)?.meter
        async let balanceResult = capture { try await self.ecykt.balance(session, custid: card.custid) }
        async let meterResult = readMeter(session, binding: binding)
        let (b, m) = await (balanceResult, meterResult)
        guard started == signOutGeneration else { return SchoolReading(outcome: .notSignedIn, checkedAt: now()) }
        return SchoolReading(outcome: .ok, checkedAt: checkedAt, balance: b, meter: m,
                             roomLabel: m == nil ? nil : binding?.label, readAt: now(), reexchanged: reexchanged)
    }

    private enum Renewal { case renewed((BoundCard, EcyktSession)), stopped(SchoolReading) }

    /// The card session is dead: the portal token, else the saved password, once each.
    private func renew(_ stored: EcyktSession, firstError e: ServiceError, since started: Int,
                       mayMint: @Sendable () async -> Bool) async -> Renewal {
        var lastError = e
        var triedPortal = false
        if let portalToken = (try? vault.portalToken()) ?? nil, portalToken.expiresAt.map({ $0 > now() }) ?? true {
            triedPortal = true
            do {
                let fresh = try await exchangeSession(portalToken: portalToken, userAgent: stored.userAgent, previous: stored)
                return .renewed(try await liveCard(fresh))
            } catch let e2 as ServiceError where e2.isSessionExpired {
                if e2 == .sessionExpired(.portal) {
                    logExpired(.portal, obtainedAt: portalToken.obtainedAt, lastAliveAt: nil)
                }
                lastError = e2
            } catch {
                // Re-exchange failed for another reason: the ecykt login is still known dead.
                return .stopped(SchoolReading(outcome: .needsLogin(e), checkedAt: now(), reexchanged: true))
            }
        }
        switch await signInWithSavedPassword(previous: stored, since: started, mayMint: mayMint) {
        case .signedIn(let found): return .renewed(found)
        case .offline: return .stopped(SchoolReading(outcome: .failed(.offline), checkedAt: now(), reexchanged: triedPortal))
        case .unavailable: return .stopped(SchoolReading(outcome: .needsLogin(lastError), checkedAt: now(), reexchanged: triedPortal))
        case .lostLease: return .stopped(SchoolReading(outcome: .failed(.timedOut), checkedAt: now(), reexchanged: triedPortal))
        case .signedOut: return .stopped(SchoolReading(outcome: .notSignedIn, checkedAt: now()))
        }
    }

    private enum WriteBack { case written, kept, signedOut, lostLease }

    /// Writes the live session back (latest ciphertexts, `lastAliveAt`) only while the stored
    /// session is still `base`. Signed out in another process: nothing is written. A newer
    /// session stored by the other process stays; this read used a live one all the same.
    /// Written only while the lease is still held.
    private func writeBack(_ session: EcyktSession, over base: EcyktSession,
                           mayMint: @Sendable () async -> Bool) async -> WriteBack {
        let current: EcyktSession?
        do { current = try vault.ecyktSession() } catch { return .kept }
        guard let current else { return .signedOut }
        guard current.token == base.token else { return .kept }
        guard await mayMint() else { return .lostLease }
        try? vault.saveEcyktSession(session)
        return .written
    }

    // MARK: Credential lifetime

    enum CredentialKind: String { case card, portal }

    /// One line per dead credential: which kind, minutes since it was obtained, and (card) minutes
    /// from obtaining it to the last time it was seen alive. Never values.
    static func expiredEvent(_ kind: CredentialKind, obtainedAt: Date?, lastAliveAt: Date?, now: Date) -> String {
        func minutes(_ from: Date?, _ to: Date) -> String {
            from.map { String(max(0, Int(to.timeIntervalSince($0) / 60))) } ?? "unknown"
        }
        var line = "school.credentialExpired kind=\(kind.rawValue) ageMinutes=\(minutes(obtainedAt, now))"
        if kind == .card { line += " aliveMinutes=" + (lastAliveAt.map { minutes(obtainedAt, $0) } ?? "unknown") }
        return line
    }

    private func logExpired(_ kind: CredentialKind, obtainedAt: Date?, lastAliveAt: Date?) {
        // A credential without a stamp (saved by an older build) is logged once per process.
        let id = kind.rawValue + (obtainedAt.map { "@\($0.timeIntervalSince1970)" } ?? "@unknown")
        guard loggedExpiries.insert(id).inserted else { return }
        let line = Self.expiredEvent(kind, obtainedAt: obtainedAt, lastAliveAt: lastAliveAt, now: now())
        diagnostic(line)
        credentialLog?.append(line, at: now())
    }

    /// A portal token gets its `obtainedAt` when this app first saves it.
    private func stamped(_ token: PortalToken) -> PortalToken {
        var t = token
        if t.obtainedAt == nil { t.obtainedAt = now() }
        return t
    }

    private enum PasswordStep { case signedIn((BoundCard, EcyktSession)), offline, unavailable, lostLease, signedOut }

    /// The last step of the refresh: one login with the saved password. Anything but success
    /// or no network pauses the password, so a wrong or blocked login is never repeated. A login
    /// that was sent but got no answer holds automatic logins off for a few hours instead.
    ///
    /// The widget can be suspended or killed at any await, so each fact is stored as soon as it
    /// is known: the hold is written before the password goes out and lifted once an answer (or
    /// a failure before sending) comes back; the portal token is saved as soon as the login
    /// returns it, before the exchange that follows.
    private func signInWithSavedPassword(previous: EcyktSession, since started: Int,
                                         mayMint: @Sendable () async -> Bool) async -> PasswordStep {
        guard let saved = (try? vault.account()) ?? nil, let password = saved.automaticPassword(at: now()) else { return .unavailable }
        // The portal exchange may have taken most of the lease: confirm it before the password goes out.
        guard await mayMint() else { return .lostLease }
        let sentAt = now()
        guard updateSavedAccount(saved, since: started, { $0.unansweredAt = sentAt }) else { return .signedOut }
        let token: PortalToken
        do {
            token = try await passwordLoginOnce(account: saved.account, password: password)
        } catch SchoolLoginFailure.noAnswer {
            // The school may have counted this one: the hold written above stays.
            return .offline
        } catch SchoolLoginFailure.offline {
            liftHold(saved, sentAt: sentAt, since: started)
            return .offline
        } catch is CancellationError {
            // Cancelled before the password was sent (after it, the login reports noAnswer).
            liftHold(saved, sentAt: sentAt, since: started)
            return .unavailable
        } catch {
            // Only the password that was tried: one saved meanwhile (保存密码 / 重新输入密码) stays usable.
            _ = updateSavedAccount(saved, since: started) { $0.paused = true; $0.unansweredAt = nil }
            return .unavailable
        }
        liftHold(saved, sentAt: sentAt, since: started)
        // Kept at once: a read given up after this point (the widget's deadline) still leaves the
        // next one a portal token to exchange instead of another password login.
        guard await mayMint() else { return .lostLease }
        guard started == signOutGeneration else { return .unavailable }
        // Read again just before writing: signed out in the other process meanwhile = nothing kept.
        guard let still = (try? vault.account()) ?? nil, still.account == saved.account else { return .signedOut }
        try? vault.savePortalToken(stamped(token))
        do {
            guard await mayMint() else { return .lostLease }
            let fresh = try await exchangeSession(portalToken: token, userAgent: previous.userAgent, previous: previous)
            let found = try await liveCard(fresh)
            guard started == signOutGeneration else { return .unavailable }
            return .signedIn(found)
        } catch let e as ServiceError where e == .offline || e == .timedOut {
            // The password was accepted; only the steps after it lost the network.
            return .offline
        } catch is CancellationError {
            return .unavailable
        } catch {
            // The password worked but the card login after it did not: paused as before, so the
            // next refresh does not log in again (the saved portal token is still tried first).
            _ = updateSavedAccount(saved, since: started) { $0.paused = true }
            return .unavailable
        }
    }

    /// Changes the saved account only while it is still the one this login started from (same
    /// account and password, not signed out). False = it has gone or changed.
    private func updateSavedAccount(_ saved: SchoolAccount, since started: Int, _ change: (inout SchoolAccount) -> Void) -> Bool {
        guard started == signOutGeneration, var current = (try? vault.account()) ?? nil,
              current.account == saved.account, current.password == saved.password else { return false }
        change(&current)
        return (try? vault.saveAccount(current)) != nil
    }

    /// An answer came back (or the password never left): the hold written for this login goes.
    private func liftHold(_ saved: SchoolAccount, sentAt: Date, since started: Int) {
        _ = updateSavedAccount(saved, since: started) { if $0.unansweredAt == sentAt { $0.unansweredAt = nil } }
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
                            cardUnionID: previous?.cardUnionID, areacode: areacode, userAgent: userAgent, obtainedAt: now())
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
