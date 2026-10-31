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
    /// Someone was signed in, and neither the card nor the account shows whether this is them:
    /// their dorm and meter were not kept (unless the new dorm is the same room), and the app
    /// drops what it keeps per person as for a switch.
    public var previousPersonUnconfirmed: Bool
    /// The previous dorm or meter is gone (removed, or replaced by another dorm). False when
    /// the same room was read again and both were kept, or there was none.
    public var dormAndMeterCleared: Bool
    public init(cardholder: String, residence: PortalResidence?, switchedAccount: Bool = false,
                previousPersonUnconfirmed: Bool = false, dormAndMeterCleared: Bool = false) {
        self.cardholder = cardholder; self.residence = residence; self.switchedAccount = switchedAccount
        self.previousPersonUnconfirmed = previousPersonUnconfirmed; self.dormAndMeterCleared = dormAndMeterCleared
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
    /// Bumped by `signOut()`. A refresh that awaited the network checks it before writing the
    /// Keychain, so a sign-out in the middle is never undone by a late write.
    private var signOutGeneration = 0
    /// Bumped by `signOut()` and by every sign-in that is not known to be the same person.
    /// Sign-in, the dorm and meter, the hot-water hand-off and recharge check it before writing,
    /// so the previous person's late answer never lands in the next person's account.
    private var personGeneration = 0
    /// Bumped whenever the saved password is set or removed here (sign-in, 保存密码 on and off,
    /// sign-out): a late second off-write (`forgetPasswordAgain`) leaves alone what was saved
    /// after it, even the same password typed again.
    private var passwordGeneration = 0
    /// How long the card records may take after the numbers were handed over.
    let recordsTimeout: TimeInterval
    /// Upper bound on directory calls when locating the room node.
    static let maxDirectoryCalls = 40
    /// Same-name rooms read one by one for a meter match; more and the binding stays campus-wide.
    static let maxRoomPaths = 4
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
    /// Everything is written in one locked step under `owning` (see `commitLogin`): the lease
    /// lost meanwhile, nothing is written and `SchoolLoginFailure.busy` is thrown.
    public func signIn(account: String, password: String, savePassword: Bool, owning: LeaseOwnership) async throws -> SignInSummary {
        var started = personGeneration
        let start = try Self.storedCredentials(vault)
        let before = signedInPerson()
        let token = try await passwordLoginOnce(account: account, password: password, owning: owning)
        try ensureSignedIn(since: started)
        return try await signIn(portalToken: token, account: account,
                                saving: SchoolAccount(account: account, password: savePassword ? password : nil),
                                before: before, start: start, started: &started, owning: owning)
    }

    /// Settings › 学校账号 › 保存密码 / 重新输入密码: checks the password with one login before
    /// keeping it. It never switches person: an account other than the signed-in one is refused
    /// (`differentAccount`) without a login when the account is known, and after a web sign-in
    /// (account unknown) the login's card must be the signed-in card. A saved password clears
    /// any pause.
    public func savePassword(_ password: String, account given: String? = nil, owning: LeaseOwnership) async throws {
        let start = try Self.storedCredentials(vault)
        let stored = start.account
        if let known = stored?.account, let given, given != known { throw SchoolLoginFailure.differentAccount }
        guard let account = given ?? stored?.account, !account.isEmpty else {
            throw SchoolLoginFailure.wrongCredentials
        }
        let started = personGeneration
        let before = signedInPerson()
        let token = try await passwordLoginOnce(account: account, password: password, owning: owning)
        try ensureSignedIn(since: started)
        var exchanged: EcyktSession?
        if stored?.account == nil, let current = start.session {
            // Web sign-in: only the card says whose login this was.
            let session = try await exchangeSession(portalToken: token, userAgent: current.userAgent, previous: current)
            let (card, updated) = try await liveCard(session)
            try ensureSignedIn(since: started)
            guard SignedInPerson.match(before, cardUnionID: card.unionID, account: nil) == .same else {
                throw SchoolLoginFailure.differentAccount
            }
            exchanged = updated
        }
        let vault = vault, portalToken = stamped(token), saving = SchoolAccount(account: account, password: password)
        try Self.commitLogin(owning, vault, from: start) {
            if let exchanged { try vault.saveEcyktSession(exchanged) }
            try vault.savePortalToken(portalToken)
            try vault.saveAccount(saving)
        }
        passwordGeneration += 1
    }

    /// What `forgetPassword()` removed, for `forgetPasswordAgain(forgotten:)`.
    public struct ForgottenPassword: Sendable, Equatable {
        /// The account as it was before.
        public let account: SchoolAccount
        let generation: Int
    }

    /// Turning 保存密码 off: the password goes at once; the account name stays for display.
    /// nil, and nothing changed, when no password is saved: an earlier off's pending second
    /// write still holds then.
    @discardableResult public func forgetPassword() throws -> ForgottenPassword? {
        guard let stored = try vault.account(), stored.password != nil else { return nil }
        passwordGeneration += 1
        try vault.saveAccount(SchoolAccount(account: stored.account))
        return ForgottenPassword(account: stored, generation: passwordGeneration)
    }

    /// The same once more, under the lease: a refresh that read the account before the first
    /// write may have written it back with the password. Only that password goes (the rest of
    /// that write stays). Left alone: anything saved here since (switched back on, even with the
    /// same password; signed in or out), another account, another password.
    /// The compare and the write are one locked step under `owning`; lost, nothing is written
    /// and `SchoolLoginFailure.busy` is thrown.
    public func forgetPasswordAgain(forgotten: ForgottenPassword, owning: LeaseOwnership) throws {
        guard forgotten.generation == passwordGeneration else { return }
        let before = forgotten.account, vault = vault
        let ran = try owning.write { () -> Bool in
            guard var stored = try vault.account(), stored.account == before.account,
                  stored.password != nil, stored.password == before.password else { return true }
            stored.password = nil
            try vault.saveAccount(stored)
            return true
        }
        guard ran == true else { throw SchoolLoginFailure.busy }
    }

    /// The signed-in account (nil after a web sign-in that did not show the same person: the
    /// page never tells us the account).
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

    /// Whether a sign-in removed the dorm or meter that `old` had (another dorm counts).
    static func cleared(_ old: SchoolProfile?, now: SchoolProfile?) -> Bool {
        guard let old else { return false }
        if old.meter != nil, now?.meter == nil { return true }
        return old.residence != nil && old.residence?.address != now?.residence?.address
    }

    /// A different person signed in: drop the previous one's dorm, meter, saved account and
    /// tokens before the new ones are written. The login device id stays (same phone).
    private static func clearPreviousPerson(_ vault: SchoolVault) throws {
        try vault.saveAccount(nil)
        try vault.savePortalToken(nil)
        try vault.saveEcyktSession(nil)
        try vault.saveProfile(nil)
    }

    /// One login from the form or Settings. The lease lost before a new device id could be
    /// stored: nothing is sent (`busy`).
    private func passwordLoginOnce(account: String, password: String, owning: LeaseOwnership) async throws -> PortalToken {
        guard let passwordLogin else { throw SchoolLoginFailure.cannotLoginDirectly }
        guard let visitorID = loginDeviceID(owning: owning) else { throw SchoolLoginFailure.busy }
        return try await passwordLogin.login(account: account, password: password, visitorID: visitorID)
    }

    /// A random 32-hex id, kept for this install so the school sees the same browser each time.
    /// A new one is stored in one locked step under `owning`, only while none is stored (one
    /// the other process stored meanwhile is used instead). nil = the lease is lost.
    private func loginDeviceID(owning: LeaseOwnership) -> String? {
        if let id = (try? vault.loginDeviceID()) ?? nil, !id.isEmpty { return id }
        let fresh = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let vault = vault
        return (try? owning.write { () -> String in
            if let id = (try? vault.loginDeviceID()) ?? nil, !id.isEmpty { return id }
            try? vault.saveLoginDeviceID(fresh)
            return fresh
        }) ?? nil
    }

    /// What a login compares again just before its writes: the stored card session, portal
    /// token and account, byte for byte. An item that no longer decodes (damaged, or an older
    /// shape) compares equal to itself, so the login writes over it and repairs it, as before;
    /// one the other process rewrote meanwhile compares unequal, decodable or not.
    struct StoredCredentials: Equatable {
        var bytes: [Data?]
        /// Decoded for the login's own use; nil when absent or no longer decodable.
        var session: EcyktSession?
        var account: SchoolAccount?
        static func == (a: StoredCredentials, b: StoredCredentials) -> Bool { a.bytes == b.bytes }
    }

    /// Throws only when the store can't be read (before the first unlock, say).
    static func storedCredentials(_ vault: SchoolVault) throws -> StoredCredentials {
        StoredCredentials(bytes: try vault.credentialBytes(), session: (try? vault.ecyktSession()) ?? nil,
                          account: (try? vault.account()) ?? nil)
    }

    /// A login's writes (sign-in from the form or the web page, 保存密码) in one locked step:
    /// the lease is still ours (`owning`) and the stored credentials are still the ones the login
    /// started from, then `writes` runs. Otherwise the other process took over meanwhile (this
    /// process was suspended past the lease, say) and may have stored newer credentials: nothing
    /// is written and `SchoolLoginFailure.busy` is thrown, so the user tries again.
    static func commitLogin<T>(_ owning: LeaseOwnership, _ vault: SchoolVault, from start: StoredCredentials,
                               _ writes: () throws -> T) throws -> T {
        let result = try owning.write { () throws -> T? in
            guard (try? storedCredentials(vault)) == start else { return nil }
            return try writes()
        }
        guard let done = result, let value = done else { throw SchoolLoginFailure.busy }
        return value
    }

    // MARK: Sign-in

    /// Native path after the CAS WebView produced the portal token: dorm address, ticket,
    /// ecykt exchange, bound card. Saves everything on success.
    public func signIn(portalToken: PortalToken, userAgent: String = EcyktSession.defaultUserAgent,
                       owning: LeaseOwnership) async throws -> SignInSummary {
        var started = personGeneration
        let start = try Self.storedCredentials(vault)
        return try await signIn(portalToken: portalToken, account: nil, saving: nil, before: signedInPerson(), start: start,
                                started: &started, owning: owning, userAgent: userAgent)
    }

    /// A different person clears the previous one's data first. When the dorm address can't be
    /// read, the old dorm and meter are kept only if the card shows it is the same person.
    /// Anyone but the same person makes work still running for the previous one stale, from the
    /// moment the locked step starts writing (also when one of its writes then fails, the
    /// previous person's items maybe gone already); `started` then moves on to the new person. `saving`: the account the form signed in with. Every
    /// write is one locked step (`commitLogin`) over the credentials read at `start`.
    private func signIn(portalToken: PortalToken, account: String?, saving: SchoolAccount?, before: SignedInPerson?,
                        start: StoredCredentials, started: inout Int, owning: LeaseOwnership,
                        userAgent: String = EcyktSession.defaultUserAgent) async throws -> SignInSummary {
        let residence = try? await portal.myInfo(portalToken)
        let session = try await exchangeSession(portalToken: portalToken, userAgent: userAgent, previous: nil)
        let (card, updated) = try await liveCard(session)
        try ensureSignedIn(since: started)
        let match = SignedInPerson.match(before, cardUnionID: card.unionID, account: account)
        let vault = vault, token = stamped(portalToken)
        var writing = false
        let old: SchoolProfile?, profile: SchoolProfile
        do {
            (old, profile) = try Self.commitLogin(owning, vault, from: start) { () -> (SchoolProfile?, SchoolProfile) in
                writing = true
                let old = (try? vault.profile()) ?? nil
                if match == .different { try Self.clearPreviousPerson(vault) }
                try vault.savePortalToken(token)
                try vault.saveEcyktSession(updated)
                var profile = (try? vault.profile()) ?? SchoolProfile()
                if let residence {
                    if profile.residence?.address != residence.address { profile.meter = nil }
                    profile.residence = residence
                } else if match != .same {
                    profile = SchoolProfile()
                }
                try vault.saveProfile(profile)
                if let saving { try vault.saveAccount(saving) }
                return (old, profile)
            }
        } catch {
            // A write failed after the step began (the previous person's items may be gone
            // already): their work still in flight is stale all the same.
            if writing, match != .same { started = newPerson() }
            throw error
        }
        if match != .same { started = newPerson() }
        if saving != nil { passwordGeneration += 1 }
        return SignInSummary(cardholder: card.displayName, residence: residence, switchedAccount: match == .different,
                             previousPersonUnconfirmed: before != nil && match == .unknown,
                             dormAndMeterCleared: Self.cleared(old, now: profile))
    }

    /// Fallback while the ticket exchange is uncaptured: adopt the
    /// `localStorage.elecampus_state` the official page wrote, then validate it.
    /// The card session, account and token are written in one locked step under `owning`
    /// (`commitLogin`): the lease lost meanwhile, nothing is written and `busy` is thrown.
    public func adoptWebState(_ elecampusState: Data, portalToken: PortalToken?,
                              userAgent: String = EcyktSession.defaultUserAgent, owning: LeaseOwnership) async throws -> SignInSummary {
        guard let root = try? JSONValue.parse(elecampusState),
              let token = (root["logintoken"] ?? root["loginInfo"]?["token"])?.text, !token.isEmpty,
              let sys = root["loginInfo"]?["syscustid"]?.text, !sys.isEmpty else {
            throw ServiceError.malformed(.ecykt, "elecampus_state")
        }
        let areacode = root["schoolid"]?.text ?? EcyktSession.defaultAreacode
        let session = EcyktSession(token: token, syscustid: sys, custid: root["custInfo"]?["custid"]?.text,
                                   cardUnionID: root["custInfo"]?["custunionid"]?.text, areacode: areacode, userAgent: userAgent,
                                   obtainedAt: now())
        var started = personGeneration
        let start = try Self.storedCredentials(vault)
        let before = signedInPerson()
        let (card, updated) = try await liveCard(session)
        try ensureSignedIn(since: started)
        let match = SignedInPerson.match(before, cardUnionID: card.unionID, account: nil)
        let switched = match == .different
        // As for the form sign-in: without the new dorm, a dorm and meter that may be someone
        // else's are not kept. No portal token: no dorm is read, so that happens right here.
        let dropDorm = match == .unknown && before != nil
        let vault = vault, webToken = portalToken.map(stamped)
        var writing = false
        let old: SchoolProfile?
        do {
            old = try Self.commitLogin(owning, vault, from: start) { () -> SchoolProfile? in
                writing = true
                let old = (try? vault.profile()) ?? nil
                if switched { try Self.clearPreviousPerson(vault) }
                // The web page never tells us the account: a saved password stays only when the
                // card shows it is the same person (the widget keeps signing in with it).
                if match != .same { try vault.saveAccount(nil) }
                if let webToken { try vault.savePortalToken(webToken) }
                try vault.saveEcyktSession(updated)
                if webToken == nil, dropDorm { try vault.saveProfile(SchoolProfile()) }
                return old
            }
        } catch {
            // As for the form sign-in: begun writes make the previous person's work stale.
            if writing, match != .same { started = newPerson() }
            throw error
        }
        if match != .same { started = newPerson() }
        var residence: PortalResidence?
        if let portalToken, let r = try? await portal.myInfo(portalToken) {
            try ensureSignedIn(since: started)
            residence = r
            _ = try owning.write {
                var profile = (try? vault.profile()) ?? SchoolProfile()
                if profile.residence?.address != r.address { profile.meter = nil }
                profile.residence = r
                try vault.saveProfile(profile)
            }
        } else if portalToken != nil, dropDorm {
            try ensureSignedIn(since: started)
            _ = try owning.write { try vault.saveProfile(SchoolProfile()) }
        }
        return SignInSummary(cardholder: card.displayName, residence: residence, switchedAccount: switched,
                             previousPersonUnconfirmed: before != nil && match == .unknown,
                             dormAndMeterCleared: Self.cleared(old, now: (try? vault.profile()) ?? nil))
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
        personGeneration += 1
        passwordGeneration += 1
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
    /// `numbers` gets the reading with the balance and the meter (no records) as soon as they
    /// are in, so they can be stored before the slower card records arrive. The returned
    /// reading has all three; the records are given up `recordsTimeout` after they were asked
    /// for, which is at the same time as the balance and the meter. The card session is written
    /// back in one locked step with the lease check (`owning`, always given: `.unchecked` only
    /// where no lease exists).
    public func refresh(inBackground: Bool, mayMint: @Sendable () async -> Bool = { true }, owning: LeaseOwnership,
                        numbers: @Sendable (SchoolReading) async -> Void = { _ in }) async -> SchoolReading {
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
                switch await renew(stored, firstError: e, since: started, mayMint: mayMint, owning: owning) {
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
        switch writeBack(alive, over: base, owning: owning) {
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
                       mayMint: @Sendable () async -> Bool, owning: LeaseOwnership) async -> Renewal {
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
                                             since: started, mayMint: mayMint, owning: owning) {
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
    private func writeBack(_ session: EcyktSession, over base: EcyktSession, owning: LeaseOwnership) -> WriteBack {
        let vault = vault
        func compare() -> WriteBack? {
            let current: EcyktSession?
            do { current = try vault.ecyktSession() } catch { return .kept }
            guard let current else { return .signedOut }
            // Any change to the stored one (token or the rotating syscustid) means it is newer:
            // another process or a sign-in stored it.
            guard current.token == base.token, current.syscustid == base.syscustid else { return .kept }
            return nil
        }
        if let early = compare() { return early }
        // Compared again and saved in one step with the lease check: the other process can't
        // take the lease (and store its own session) between the check and the save.
        let outcome = (try? owning.write { () -> WriteBack in
            if let changed = compare() { return changed }
            try? vault.saveEcyktSession(session)
            return .written
        }) ?? nil
        return outcome ?? .lostLease
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
    /// Every write here (the hold, the pause, the portal token) is one locked step under
    /// `owning` with the compare it depends on: with the lease lost, nothing is written. A
    /// password accepted after that keeps its hold (its answer was not kept), so it is not sent
    /// again right away; the other process, which holds the lease now, carries on.
    private func signInWithSavedPassword(previous: EcyktSession, seenPortalToken: String?, since started: Int,
                                         mayMint: @Sendable () async -> Bool, owning: LeaseOwnership) async -> PasswordStep {
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
        guard let passwordLogin else { return .unavailable }
        guard let visitorID = loginDeviceID(owning: owning) else { return .lostLease }
        let sentAt = now()
        // Not written: signed out only when the account is really gone. Changed meanwhile (保存密码,
        // 重新输入密码) or a write that failed leave the user signed in, with nothing to report;
        // nothing is sent this time and the next refresh tries again.
        switch updateSavedAccount(saved, since: started, owning: owning, { $0.unansweredAt = sentAt }) {
        case .written: break
        case .lostLease: return .lostLease
        case .changed: return accountGone ? .signedOut : .retryLater
        }
        let token: PortalToken
        do {
            token = try await passwordLogin.login(account: saved.account, password: password, visitorID: visitorID)
        } catch SchoolLoginFailure.noAnswer {
            // The school may have counted this one: the hold written above stays.
            return .offline
        } catch SchoolLoginFailure.offline {
            liftHold(saved, sentAt: sentAt, since: started, owning: owning)
            return .offline
        } catch is CancellationError {
            // Cancelled before the password was sent (after it, the login reports noAnswer).
            liftHold(saved, sentAt: sentAt, since: started, owning: owning)
            return .unavailable
        } catch {
            // Only the password that was tried: one saved meanwhile (保存密码 / 重新输入密码) stays usable.
            _ = updateSavedAccount(saved, since: started, owning: owning) { $0.paused = true; $0.unansweredAt = nil }
            return .unavailable
        }
        // The school accepted the password: the portal token is kept at once, so neither this
        // process nor the other one sends the password again (a read given up after this point
        // leaves a token to exchange). It is written in one locked step while this process is
        // still the lease's owner and the stored account and portal token are still the ones
        // this login started from: a token the other process stored after taking the lease is
        // never overwritten. A lease that only ran out meanwhile (suspended, nobody took it) is
        // taken again in that step, and a cancelled task (the widget's deadline) still writes:
        // dropping the token there would hold the password back for hours with nothing newer
        // stored. A sign-out in between (this process, or the account gone from the Keychain)
        // drops it. The hold is lifted in the same step, only with the token stored.
        guard started == signOutGeneration else { return .unavailable }
        enum TokenSave { case written, gone, changed }
        let vault = vault, fresh = stamped(token)
        let saveStep = (try? owning.writeRetaking { () -> TokenSave in
            let still: SchoolAccount?
            do { still = try vault.account() } catch { return .changed }
            guard let still else { return .gone }
            let portal: PortalToken?
            do { portal = try vault.portalToken() } catch { return .changed }
            guard still.account == saved.account, portal?.value == seenPortalToken else { return .changed }
            guard (try? vault.savePortalToken(fresh)) != nil else { return .changed }
            // Read again: an older build's sign-out deletes without the lease, also right here.
            if var current = (try? vault.account()) ?? nil, current.account == saved.account,
               current.password == saved.password, current.unansweredAt == sentAt {
                current.unansweredAt = nil
                try? vault.saveAccount(current)
            }
            return .written
        }) ?? nil
        switch saveStep {
        // Lost to a sign-out (it removes the lease first, then the items): reported as one.
        case nil: return accountGone ? .signedOut : .lostLease
        case .gone?: return .signedOut
        case .changed?: return .retryLater
        case .written?: break
        }
        // The account gone right after all the same (a sign-out that deleted the items without
        // removing the lease first: an older build, or a failed removal): the token is taken
        // back out, in one more locked step. A new sign-in there writes its token before its
        // account, so a token that is no longer this one is theirs and stays.
        if accountGone {
            let removed = (try? owning.write { () -> Bool in
                guard ((try? vault.portalToken()) ?? nil)?.value == token.value else { return false }
                return (try? vault.savePortalToken(nil)) != nil
            }) ?? nil
            return removed == true ? .signedOut : .retryLater
        }
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
            _ = updateSavedAccount(saved, since: started, owning: owning) { $0.paused = true }
            return .unavailable
        }
    }

    private enum AccountUpdate { case written, changed, lostLease }

    /// Changes the saved account only while it is still the one this login started from (same
    /// account and password, not signed out), in one locked step with the lease check.
    private func updateSavedAccount(_ saved: SchoolAccount, since started: Int, owning: LeaseOwnership,
                                    _ change: (inout SchoolAccount) -> Void) -> AccountUpdate {
        guard started == signOutGeneration else { return .changed }
        let vault = vault
        let step = (try? owning.write { () -> AccountUpdate in
            guard var current = (try? vault.account()) ?? nil,
                  current.account == saved.account, current.password == saved.password else { return .changed }
            change(&current)
            return (try? vault.saveAccount(current)) != nil ? .written : .changed
        }) ?? nil
        return step ?? .lostLease
    }

    /// The saved account was read and is not there (a read that fails says nothing).
    private var accountGone: Bool {
        do { return try vault.account() == nil } catch { return false }
    }

    /// An answer came back (or the password never left): the hold written for this login goes.
    private func liftHold(_ saved: SchoolAccount, sentAt: Date, since started: Int, owning: LeaseOwnership) {
        _ = updateSavedAccount(saved, since: started, owning: owning) { if $0.unansweredAt == sentAt { $0.unansweredAt = nil } }
    }

    // MARK: Electricity

    /// Onboarding: one campus-wide `getMeterStatus`, match `piplineName == "<栋>栋<room>"`,
    /// then locate the room-level node so daily refreshes read 1 row. If the room node cannot
    /// be found, the campus node + `comAddress` is saved instead (wide read).
    public func resolveElectricity() async throws -> ElectricityResolution {
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = personGeneration
        var profile = try vault.profile() ?? SchoolProfile()
        if profile.residence?.address == nil, let token = try vault.portalToken() {
            profile.residence = try await portal.myInfo(token)
            try ensureSignedIn(since: started)
            try vault.saveProfile(profile)
        }
        // Every answer, a list or a hint included, is the person's who started: someone else
        // signed in meanwhile gets none of it.
        guard let address = profile.residence?.address else { try ensureSignedIn(since: started); return .noAddress }

        let campuses = try await ecykt.buildings(session, parent: nil).filter { address.matchesCampus($0.name) }
        guard campuses.count == 1, let campus = campuses.first else { try ensureSignedIn(since: started); return .manualPicker }
        let rows = try await ecykt.meters(session, nodeID: campus.id, wide: true)
        let meter: Meter
        switch MeterMatcher.match(rows, address: address) {
        case .none:
            try ensureSignedIn(since: started)
            return .manualPicker
        case .many(let all):
            // The same comAddress twice: the campus-wide rows can't tell the rooms apart, and a
            // room found by its meter could be either one. The user picks the room by hand.
            guard Set(all.map(\.comAddress)).count == all.count else { try ensureSignedIn(since: started); return .manualPicker }
            let list = try await candidates(all, session: session, campus: campus, address: address)
            try ensureSignedIn(since: started)
            return .chooseAmong(list)
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

    /// `resolveElectricity()` for whoever is signed in when it answers, with the person stamp
    /// the answer belongs to (a same-name choice carries it into `chooseMatchedMeter`). Dropped
    /// because someone else signed in meanwhile, it runs again for them, a few times at most;
    /// signed out meanwhile (even where the sign-out failed), the drop is thrown.
    public func matchElectricity() async throws -> (stamp: Int, ElectricityResolution) {
        var attempts = 0
        while true {
            let stamp = personGeneration, signedOut = signOutGeneration
            do {
                return (stamp, try await resolveElectricity())
            } catch {
                attempts += 1
                // A sign-out in between ends it, even one that could not delete the card session.
                guard stamp != personGeneration, signedOut == signOutGeneration, attempts < 3,
                      (try? vault.ecyktSession()) ?? nil != nil else { throw error }
            }
        }
    }

    /// Manual choice from the picker (`buildings(parent:)` walk in the UI, then a meter row).
    /// `path` = the directory names walked down to `nodeID`, kept as the full location.
    /// `stamp` = `personStamp()` when the picker opened: a pick made after someone else signed
    /// in is refused.
    public func chooseMeter(nodeID: String, meter: Meter, nodeIsRoom: Bool, path: [String] = [], since stamp: Int) throws {
        try ensureSignedIn(since: stamp)
        var profile = try vault.profile() ?? SchoolProfile()
        profile.meter = MeterBinding(nodeID: nodeID, comAddress: meter.comAddress, label: meter.name, nodeIsRoom: nodeIsRoom,
                                     location: path.isEmpty ? nil : PowerLocation.label(path))
        try vault.saveProfile(profile)
    }

    /// Choice among several same-name meters (`.chooseAmong`): saved against its room node
    /// (1 row) when the walk found it, else against the campus node (wide read, picked by `comAddress`).
    /// `stamp` = `personStamp()` taken before the match that offered the list.
    public func chooseMatchedMeter(_ candidate: MeterCandidate, since stamp: Int) async throws {
        let started = stamp
        try ensureSignedIn(since: started)
        guard let session = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
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

    /// Liveness check, then `getSignData` for the bound card (hot-water onboarding only). The app
    /// runs it under the refresh lease; the live session is kept only over the one it started from,
    /// and only while `owning` finds the lease still held, in the same locked step.
    public func showerHandoff(owning: LeaseOwnership) async throws -> ShowerHandoff {
        guard let stored = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = personGeneration
        let (card, live) = try await liveCard(stored)
        try ensureSignedIn(since: started)
        saveIfUnchanged(live, over: stored, owning: owning)
        return try await ecykt.signData(live, custid: card.custid)
    }

    /// Walks campus → (apartment) → building → floor → room with name filters. Returns the
    /// room-level row whose meter has `comAddress`, with its path. When more than one room
    /// reports that meter, none is trusted (nil): the campus-wide read by `comAddress` is
    /// still exact, a guessed room might bill the wrong dorm. More than `maxRoomPaths` same-name
    /// rooms are not all read, so none is trusted either.
    func locateRoomNode(_ s: EcyktSession, campus: PowerNode, address: DormAddress, comAddress: String) async throws -> MeterCandidate? {
        guard let paths = try await roomPaths(s, campus: campus, address: address), paths.count <= Self.maxRoomPaths else { return nil }
        var found: MeterCandidate?
        for path in paths {
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

    /// Liveness check, then one `loginBySysId`; the fresh token goes into `logintoken`. The app
    /// runs it under the refresh lease; the live session is kept only over the one it started from,
    /// and only while `owning` finds the lease still held, in the same locked step.
    public func rechargeSession(_ kind: RechargeKind, owning: LeaseOwnership) async throws -> RechargeWebSession {
        guard let stored = try vault.ecyktSession() else { throw ServiceError.sessionExpired(.ecykt) }
        let started = personGeneration
        let (card, live) = try await liveCard(stored)
        let fresh = try await ecykt.freshLogin(live)
        var updated = live
        updated.syscustid = fresh.syscustid   // latest ciphertext, valid as input next time
        try ensureSignedIn(since: started)
        saveIfUnchanged(updated, over: stored, owning: owning)
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

    /// Keeps `live` (latest ciphertexts) only while the stored session is still `base` (same
    /// token and syscustid). The other process may have stored a newer one meanwhile, which
    /// stays; this call used its own live session all the same. The compare and the save run
    /// in one step with the lease check (`owning`, from `holdingLease`): lost, nothing is written.
    private func saveIfUnchanged(_ live: EcyktSession, over base: EcyktSession, owning: LeaseOwnership) {
        let vault = vault
        _ = try? owning.write {
            guard let current = (try? vault.ecyktSession()) ?? nil,
                  current.token == base.token, current.syscustid == base.syscustid else { return }
            try? vault.saveEcyktSession(live)
        }
    }

    /// Work that awaited the network checks this before writing: a sign-out or another person
    /// signing in meanwhile wins, and the late result is dropped as if the session had expired.
    func ensureSignedIn(since started: Int) throws {
        guard started == personGeneration else { throw ServiceError.sessionExpired(.ecykt) }
    }

    /// Who is signed in now, for work outside this actor that must not outlive the person (a
    /// hot-water binding made from `showerHandoff()`): compare it with `isSamePerson(since:)`.
    public func personStamp() -> Int { personGeneration }

    /// Nobody signed out and nobody else signed in since `stamp` was taken.
    public func isSamePerson(since stamp: Int) -> Bool { stamp == personGeneration }

    /// A sign-in not known to be the same person: what was started before it is stale.
    private func newPerson() -> Int {
        personGeneration += 1
        return personGeneration
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
