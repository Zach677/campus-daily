import Foundation

public enum ElectricityResolution: Sendable, Equatable {
    /// Exactly one meter matched; the binding is saved.
    case matched(MeterBinding, Meter)
    /// Several meters carry this room name: the user picks one by its full location.
    case chooseAmong([MeterCandidate])
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
        /// The saved password was changed while this read ran (保存密码, 重新输入密码), or the
        /// Keychain refused a write or a read: nothing is known about the login. Not an error to
        /// show: the stored numbers stay as they are and the next refresh goes ahead.
        case interrupted
        /// This read lost the refresh lease (it ran out while the app was suspended, the other
        /// process took it, or a sign-out removed it) and stopped. Not an error: the snapshot
        /// shows what is stored, which the other process may be updating.
        case leaseLost
    }
    public var outcome: Outcome
    /// When the liveness check answered (or failed).
    public var checkedAt: Date
    /// Balance read; nil when it was not attempted.
    public var balance: Result<Money, ServiceError>?
    /// Room meter read; nil when no meter is bound or it was not attempted.
    /// `.success(nil)` = no meter at the saved node.
    public var meter: Result<Meter?, ServiceError>?
    /// The card's recent records; nil when not attempted.
    public var activity: Result<CardActivity, ServiceError>?
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
    /// False in the widget. Every saved password came with a login device id, so a widget that
    /// sees a password but no id is running before the app moved the id (and the portal token)
    /// out of its private group; a login then would start a second "browser" at the school and
    /// the move would keep that one. The widget leaves the login to the app instead.
    let createsLoginDeviceID: Bool
    /// Expiries already logged by this process, so a dead credential read again is logged once.
    private var loggedExpiries: Set<String> = []
    /// Bumped by `signOut()`. Work that awaited the network checks it before writing the
    /// Keychain, so a sign-out in the middle is never undone by a late write.
    private var signOutGeneration = 0
    /// How long the card records may take after the numbers were handed over.
    let recordsTimeout: TimeInterval
    /// Upper bound on directory calls when locating the room node.
    static let maxDirectoryCalls = 40
    /// Room meter reads spent placing same-name candidates.
    static let maxCandidateRooms = 8

    public init(portal: PortalClient, ecykt: EcyktClient, vault: SchoolVault, passwordLogin: SchoolPasswordLogin? = nil,
                now: @escaping @Sendable () -> Date = Date.init, diagnostic: @escaping @Sendable (String) -> Void = { _ in },
                credentialLog: CredentialLifetimeLog? = nil, createsLoginDeviceID: Bool = true,
                recordsTimeout: TimeInterval = CardActivity.timeout) {
        self.portal = portal; self.ecykt = ecykt; self.vault = vault; self.passwordLogin = passwordLogin; self.now = now
        self.diagnostic = diagnostic; self.credentialLog = credentialLog; self.createsLoginDeviceID = createsLoginDeviceID
        self.recordsTimeout = recordsTimeout
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

    /// False only when the card session was read and is not there.
    public func hasCardSession() -> Bool {
        do { return try vault.ecyktSession() != nil } catch { return true }
    }

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
        await refresh(inBackground: inBackground, mayMint: mayMint, numbers: { _ in })
    }

    /// As above; `numbers` gets the reading with the balance and the meter (no records) as
    /// soon as they are in, so they can be stored before the slower card records arrive. The
    /// returned reading has all three; the records are given up `recordsTimeout` after they
    /// were asked for, which is at the same time as the balance and the meter.
    public func refresh(inBackground: Bool, mayMint: @Sendable () async -> Bool = { true },
                        numbers: @Sendable (SchoolReading) async -> Void) async -> SchoolReading {
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
            guard await mayMint() else { return SchoolReading(outcome: .leaseLost, checkedAt: now()) }
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
        case .lostLease: return SchoolReading(outcome: .leaseLost, checkedAt: now(), reexchanged: reexchanged)
        case .written, .kept: break
        }
        let session = alive

        let binding = ((try? vault.profile()) ?? nil)?.meter
        let range = CardActivity.range(at: now())
        let timeout = recordsTimeout
        let ecykt = self.ecykt
        // Started with the other two, but nothing waits for it before the numbers are handed over.
        let records = Task {
            await Self.within(timeout) {
                await Self.captureError {
                    let page = try await ecykt.cardRecords(session, custid: card.custid, begin: range.begin, end: range.end,
                                                           page: 1, pageSize: CardActivity.pageSize, timeout: timeout)
                    return CardActivity(records: page.rows, begin: range.begin, end: range.end,
                                        complete: page.isComplete(pageSize: CardActivity.pageSize))
                }
            }
        }
        async let balanceResult = capture { try await self.ecykt.balance(session, custid: card.custid) }
        async let meterResult = readMeter(session, binding: binding)
        let (b, m) = await (balanceResult, meterResult)
        guard started == signOutGeneration else {
            records.cancel()
            return SchoolReading(outcome: .notSignedIn, checkedAt: now())
        }
        var reading = SchoolReading(outcome: .ok, checkedAt: checkedAt, balance: b, meter: m,
                                    roomLabel: m == nil ? nil : binding?.label, readAt: now(), reexchanged: reexchanged)
        await numbers(reading)
        let a = await withTaskCancellationHandler { await records.value } onCancel: { records.cancel() }
        guard started == signOutGeneration else { return SchoolReading(outcome: .notSignedIn, checkedAt: now()) }
        reading.activity = a
        return reading
    }

    private enum Renewal { case renewed((BoundCard, EcyktSession)), stopped(SchoolReading) }

    /// The card session is dead: the portal token, else the saved password, once each.
    private func renew(_ stored: EcyktSession, firstError e: ServiceError, since started: Int,
                       mayMint: @Sendable () async -> Bool) async -> Renewal {
        var lastError = e
        var triedPortal = false
        let seenPortalToken = (try? vault.portalToken()) ?? nil
        if let portalToken = seenPortalToken, portalToken.expiresAt.map({ $0 > now() }) ?? true {
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
        switch await signInWithSavedPassword(previous: stored, seenPortalToken: seenPortalToken?.value,
                                             since: started, mayMint: mayMint) {
        case .signedIn(let found): return .renewed(found)
        case .offline: return .stopped(SchoolReading(outcome: .failed(.offline), checkedAt: now(), reexchanged: triedPortal))
        case .retryLater: return .stopped(SchoolReading(outcome: .interrupted, checkedAt: now(), reexchanged: triedPortal))
        case .unavailable: return .stopped(SchoolReading(outcome: .needsLogin(lastError), checkedAt: now(), reexchanged: triedPortal))
        case .lostLease: return .stopped(SchoolReading(outcome: .leaseLost, checkedAt: now(), reexchanged: triedPortal))
        case .signedOut: return .stopped(SchoolReading(outcome: .notSignedIn, checkedAt: now()))
        }
    }

    private enum WriteBack { case written, kept, signedOut, lostLease }

    /// Writes the live session back (latest ciphertexts, `lastAliveAt`) only while the stored
    /// session is still `base` (same token and syscustid). Signed out in another process: nothing is written. A newer
    /// session stored by the other process stays; this read used a live one all the same.
    /// Written only while the lease is still held.
    private func writeBack(_ session: EcyktSession, over base: EcyktSession,
                           mayMint: @Sendable () async -> Bool) async -> WriteBack {
        let current: EcyktSession?
        do { current = try vault.ecyktSession() } catch { return .kept }
        guard let current else { return .signedOut }
        // Sign-in, saving a password, recharge and the hot-water handoff store sessions without the
        // lease; any change to the stored one (token or the rotating syscustid) means it is newer.
        guard current.token == base.token, current.syscustid == base.syscustid else { return .kept }
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

    /// The stored card session and portal token are still the ones a refresh started from
    /// (a read that fails counts as changed: nothing is sent on a guess).
    private func credentialsUnchanged(previous: EcyktSession, seenPortalToken: String?) -> Bool {
        let session: EcyktSession?, portal: PortalToken?
        do { session = try vault.ecyktSession(); portal = try vault.portalToken() } catch { return false }
        guard let session, session.token == previous.token, session.syscustid == previous.syscustid else { return false }
        return portal?.value == seenPortalToken
    }

    private enum PasswordStep { case signedIn((BoundCard, EcyktSession)), offline, unavailable, retryLater, lostLease, signedOut }

    /// The last step of the refresh: one login with the saved password. Anything but success
    /// or no network pauses the password, so a wrong or blocked login is never repeated. A login
    /// that was sent but got no answer holds automatic logins off for a few hours instead.
    ///
    /// The widget can be suspended or killed at any await, so each fact is stored as soon as it
    /// is known: the hold is written before the password goes out and lifted once an answer (or
    /// a failure before sending) comes back; the portal token is saved as soon as the login
    /// returns it, before the exchange that follows.
    ///
    /// `previous` and `seenPortalToken` are the credentials this refresh found dead. If the
    /// other process stored new ones meanwhile (its own password login was accepted), nothing
    /// is sent: the next refresh uses them.
    private func signInWithSavedPassword(previous: EcyktSession, seenPortalToken: String?, since started: Int,
                                         mayMint: @Sendable () async -> Bool) async -> PasswordStep {
        guard let saved = (try? vault.account()) ?? nil, let password = saved.automaticPassword(at: now()) else { return .unavailable }
        // Not moved to the shared group yet: like no network, nothing is paused or held.
        if !createsLoginDeviceID, ((try? vault.loginDeviceID()) ?? nil)?.isEmpty ?? true {
            diagnostic("school.passwordLogin deferred reason=noLoginDeviceID")
            return .offline
        }
        // The portal exchange may have taken most of the lease: confirm it before the password goes out.
        guard await mayMint() else { return .lostLease }
        guard credentialsUnchanged(previous: previous, seenPortalToken: seenPortalToken) else {
            diagnostic("school.passwordLogin skipped reason=credentialsChanged")
            return .retryLater
        }
        let sentAt = now()
        // Not written: signed out only when the account is really gone. Changed meanwhile (保存密码,
        // 重新输入密码) or a write that failed leave the user signed in, with nothing to report;
        // nothing is sent this time and the next refresh tries again.
        guard updateSavedAccount(saved, since: started, { $0.unansweredAt = sentAt }) else {
            return accountGone ? .signedOut : .retryLater
        }
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
        // The school accepted the password: the portal token is kept at once, lease or not, so
        // neither this process nor the other one sends the password again (a read given up or a
        // lease lost after this point leaves a token to exchange). Only a sign-out in between
        // (this process, or the account gone from the Keychain) drops it. The hold is lifted
        // only once the token is stored.
        guard started == signOutGeneration else { return .unavailable }
        guard let still = (try? vault.account()) ?? nil else { return accountGone ? .signedOut : .retryLater }
        guard still.account == saved.account else { return .retryLater }
        guard (try? vault.savePortalToken(stamped(token))) != nil else { return .retryLater }
        // A sign-out in the other process can land between the read above and the write: read
        // the account once more, and take the token back out if it has gone. A new sign-in there
        // writes its token before its account, so a token that is no longer this one is theirs
        // and stays.
        if accountGone {
            guard ((try? vault.portalToken()) ?? nil)?.value == token.value else { return .retryLater }
            try? vault.savePortalToken(nil)
            return .signedOut
        }
        liftHold(saved, sentAt: sentAt, since: started)
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

    /// The saved account was read and is not there (a read that fails says nothing).
    private var accountGone: Bool {
        do { return try vault.account() == nil } catch { return false }
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
        case .many(let all):
            // The same comAddress twice: the campus-wide rows can't tell the rooms apart, and a
            // room found by its meter could be either one. The user picks the room by hand.
            guard Set(all.map(\.comAddress)).count == all.count else { return .manualPicker }
            return .chooseAmong(try await candidates(all, session: session, campus: campus, address: address))
        case .one(let m): meter = m
        }

        var binding = MeterBinding(nodeID: campus.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: false,
                                   location: MeterCandidate(meter: meter, path: [campus]).location)
        var found = meter
        if let located = try await locateRoomNode(session, campus: campus, address: address, comAddress: meter.comAddress),
           let room = located.room {
            binding = MeterBinding(nodeID: room.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: true,
                                   location: located.location)
            found = located.meter
        }
        profile.meter = binding
        try ensureSignedIn(since: started)
        try vault.saveProfile(profile)
        return .matched(binding, found)
    }

    /// Manual choice from the picker (`buildings(parent:)` walk in the UI, then a meter row).
    /// `path` = the directory names walked down to `nodeID`, kept as the full location.
    public func chooseMeter(nodeID: String, meter: Meter, nodeIsRoom: Bool, path: [String] = []) throws {
        var profile = try vault.profile() ?? SchoolProfile()
        profile.meter = MeterBinding(nodeID: nodeID, comAddress: meter.comAddress, label: meter.name, nodeIsRoom: nodeIsRoom,
                                     location: path.isEmpty ? nil : PowerLocation.label(path))
        try vault.saveProfile(profile)
    }

    /// Choice among several same-name meters (`.chooseAmong`): saved against its room node
    /// (1 row) when the walk found it, else against the campus node (wide read, picked by `comAddress`).
    public func chooseMatchedMeter(_ candidate: MeterCandidate) async throws {
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = signOutGeneration
        var profile = try vault.profile() ?? SchoolProfile()
        guard let address = profile.residence?.address else { throw ServiceError.malformed(.portal, "data.gydz") }
        let meter = candidate.meter
        if let room = candidate.room {
            profile.meter = MeterBinding(nodeID: room.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: true,
                                         location: candidate.location)
            try ensureSignedIn(since: started)
            try vault.saveProfile(profile)
            return
        }
        let campuses = try await ecykt.buildings(session, parent: nil).filter { address.matchesCampus($0.name) }
        guard campuses.count == 1, let campus = campuses.first else { throw ServiceError.malformed(.ecykt, "campus") }
        profile.meter = MeterBinding(nodeID: campus.id, comAddress: meter.comAddress, label: address.roomLabel, nodeIsRoom: false,
                                     location: MeterCandidate(meter: meter, path: [campus]).location)
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
    /// room-level row whose meter has `comAddress`, with its path. When more than one room
    /// reports that meter, none is trusted (nil): the campus-wide read by `comAddress` is
    /// still exact, a guessed room might bill the wrong dorm.
    func locateRoomNode(_ s: EcyktSession, campus: PowerNode, address: DormAddress, comAddress: String) async throws -> MeterCandidate? {
        guard let paths = try await roomPaths(s, campus: campus, address: address) else { return nil }
        var found: MeterCandidate?
        for path in paths.prefix(4) {
            guard let room = path.last else { continue }
            let meters = try await ecykt.meters(s, nodeID: room.id)
            guard let m = meters.first(where: { $0.comAddress == comAddress }) else { continue }
            if found != nil { return nil }
            found = MeterCandidate(meter: m, path: path)
        }
        return found
    }

    /// Several same-name meters: each one with the directory path down to its room, found by
    /// reading the matching rooms' meters (1 row each) and pairing them by `comAddress`.
    /// Meters whose room is not found keep just the campus as their path.
    func candidates(_ matched: [Meter], session s: EcyktSession, campus: PowerNode, address: DormAddress) async throws -> [MeterCandidate] {
        var located: [String: MeterCandidate] = [:]
        let wanted = Set(matched.map(\.comAddress))
        do {
            for path in (try await roomPaths(s, campus: campus, address: address) ?? []).prefix(Self.maxCandidateRooms) {
                guard located.count < wanted.count, let room = path.last else { break }
                for row in try await ecykt.meters(s, nodeID: room.id) where wanted.contains(row.comAddress) && located[row.comAddress] == nil {
                    located[row.comAddress] = MeterCandidate(meter: row, path: path)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The walk only adds the location; a failed read leaves the rest campus-wide.
        }
        return matched.map { located[$0.comAddress] ?? MeterCandidate(meter: $0, path: [campus]) }
    }

    /// Every directory path campus → (apartment) → building → floor → room whose names match
    /// the dorm address (nil = the call budget ran out first). Keeping the whole path is what
    /// lets same-named buildings in different apartments be told apart.
    func roomPaths(_ s: EcyktSession, campus: PowerNode, address: DormAddress) async throws -> [[PowerNode]]? {
        var calls = 0
        // First find building nodes, allowing one intermediate (apartment) level.
        var buildings: [[PowerNode]] = []
        guard let level1 = try await directoryChildren(s, campus.id, calls: &calls) else { return nil }
        let direct = level1.filter { address.matchesBuilding($0.name) }
        if !direct.isEmpty {
            buildings = direct.map { [campus, $0] }
        } else {
            for apartment in level1 {
                guard let kids = try await directoryChildren(s, apartment.id, calls: &calls) else { return nil }
                buildings += kids.filter { address.matchesBuilding($0.name) }.map { [campus, apartment, $0] }
            }
        }
        var rooms: [[PowerNode]] = []
        for b in buildings {
            guard let building = b.last, let floors = try await directoryChildren(s, building.id, calls: &calls) else { return nil }
            for f in floors where address.matchesFloor(f.name) {
                guard let rs = try await directoryChildren(s, f.id, calls: &calls) else { return nil }
                rooms += rs.filter { address.matchesRoom($0.name) }.map { b + [f, $0] }
            }
        }
        return rooms
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

    /// `body`'s result, or `.timedOut` once `seconds` passed (the body is then cancelled and
    /// not waited for).
    static func within<T: Sendable>(_ seconds: TimeInterval,
                                    _ body: @escaping @Sendable () async -> Result<T, ServiceError>) async -> Result<T, ServiceError> {
        let once = FirstResult<Result<T, ServiceError>>()
        let work = Task { await once.offer(await body()) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            await once.offer(.failure(.timedOut))
        }
        let result = await withTaskCancellationHandler {
            await once.value()
        } onCancel: {
            Task { await once.offer(.failure(.timedOut)) }
        }
        work.cancel(); timer.cancel()
        return result
    }

    nonisolated func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, ServiceError> {
        await Self.captureError(body)
    }

    static func captureError<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, ServiceError> {
        do { return .success(try await body()) }
        catch let e as ServiceError { return .failure(e) }
        catch { return .failure(.offline) }
    }
}

/// The first value offered wins; `value()` waits for it.
actor FirstResult<T: Sendable> {
    private var result: T?
    private var waiters: [CheckedContinuation<T, Never>] = []

    func offer(_ value: T) {
        guard result == nil else { return }
        result = value
        for waiter in waiters { waiter.resume(returning: value) }
        waiters = []
    }

    func value() async -> T {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
