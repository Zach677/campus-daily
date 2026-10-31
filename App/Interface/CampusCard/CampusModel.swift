import Foundation
import Core

/// One same-name meter offered when the electricity match is ambiguous, told apart by its
/// full location (校区 · 公寓 · 楼栋 · 房间): the names alone are identical.
struct PowerChoice: Identifiable, Equatable {
    var id: String { candidate.id }
    let candidate: MeterCandidate
    /// Who was signed in when the match that offered it started: a pick after someone else
    /// signed in is refused.
    let stamp: Int
    var meter: Meter { candidate.meter }
    var location: String { candidate.location }
    /// Row for the shared same-name list: short 「3 栋 108」 over the full location.
    var choice: LocationChoice { LocationChoice(id:id, title:Theme.dorm(meter.name) ?? meter.name, location:location) }
}

/// UI state over `SchoolSession` (refresh, electricity resolution, sign-in/out). No school logic here.
@MainActor final class CampusModel: ObservableObject {
    static let shared = CampusModel()
    @Published private(set) var configured = false
    @Published private(set) var loading = false
    @Published private(set) var snapshot: HomeSnapshot = .empty
    @Published private(set) var profile: SchoolProfile?
    @Published private(set) var issue: String?
    /// Several refreshes in a row ended without storing their numbers (the Keychain refusing
    /// writes): the home update line says so.
    @Published private(set) var notSaving = false
    @Published private(set) var matchingPower = false
    @Published private(set) var powerChoices: [PowerChoice] = []
    @Published private(set) var powerMatchIssue: String?
    /// The account signed in with the app's own form (kept by a web sign-in only when the card
    /// shows the same person). Its password is present only when the user chose to save it.
    @Published private(set) var account: SchoolAccount?
    /// A login was a different person; the alert is shown once by the top-most screen.
    @Published var switchNotice: AccountSwitchNotice?
    /// 「去设置热水」 from a screen outside Settings: Settings opens 热水 when it appears.
    @Published var hotWaterSetupRequested = false
    /// The widget's 「打开 App 更新」 during a paused automatic login: Settings opens 学校账号.
    @Published var accountPageRequested = false
    /// Sign-out left something behind (a Keychain item or the widget snapshot could not be
    /// deleted): Settings › 学校账号 says so, and shows what is still stored.
    @Published var signOutFailed = false
    private var lastRefresh: Date?
    private var refreshesRunning = 0
    /// Refreshes the Keychain interrupted one after another (writes refused).
    private var interruptions = InterruptionStreak()
    /// Bumped by `signOut()`: a refresh that returns afterwards must not put the old values back.
    private var signOutGeneration = 0
    private let session = AppEnvironment.school
    private let refresher = AppEnvironment.refresher
    /// Sign-outs in order; sign-ins wait for them (`finished()`).
    private let signOuts = SchoolSignOut(session:AppEnvironment.school, refresher:AppEnvironment.refresher)

    init() { reload() }

    /// Re-read the Keychain (launch, after sign-in/out).
    func reload() {
        configured = ((try? AppEnvironment.schoolVault.ecyktSession()) ?? nil) != nil
        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
        account = (try? AppEnvironment.schoolVault.account()) ?? nil
        snapshot = refresher.latest()
    }

    /// Only the saved account: a refresh in this or the widget's process may have paused or
    /// held the password since the last `reload()`.
    func reloadAccount() {
        let stored = (try? AppEnvironment.schoolVault.account()) ?? nil
        if stored != account { account = stored }
    }

    /// Settings › 学校账号 › 保存密码.
    var passwordSaved: Bool { SchoolAccount.savesPasswordByDefault(account) }

    var address: DormAddress? { profile?.residence?.address }
    /// 「99 栋 991」 style label, or 「未配置」.
    var room: String {
        if let address { return address.building + " 栋 " + address.room }
        return Theme.dorm(snapshot.roomLabel ?? profile?.meter?.label ?? "") ?? "未配置"
    }
    var powerConfigured: Bool { profile?.meter != nil }
    var balance: Decimal? { snapshot.card.value?.yuan }
    var meter: Meter? { snapshot.power.value }

    // MARK: Refresh

    /// Foreground refresh; `force` skips the 60 s throttle. While a refresh is running, a second
    /// call (pull-to-refresh, foreground, background task) waits for it and shows its result.
    /// A forced call never takes the result of a read that started before a sign-in or meter
    /// change (`SnapshotRefresher.noteChange`): it waits for that read and reads again.
    func refresh(force: Bool = false, inBackground: Bool = false) async {
        guard configured else { return }
        if !force, refreshesRunning == 0, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        refreshesRunning += 1; loading = true
        defer { refreshesRunning -= 1; loading = refreshesRunning > 0 }
        let started = signOutGeneration
        let report = await refresher.refresh(inBackground:inBackground, includingChanges:force)
        guard started == signOutGeneration else { return }
        snapshot = report.snapshot
        reloadAccount()
        // A cancelled refresh (the view went away, the pull was abandoned) reads as offline; that
        // says nothing about the school, so it neither shows an issue nor counts as a refresh.
        guard !Task.isCancelled else { return }
        // The widget held the lease all along (reading, or suspended while holding it): its
        // numbers, if any, are in the snapshot above. Nothing failed here, so no issue; the next
        // pull tries again.
        guard !report.leaseBusy else { return }
        // The saved password changed while this read ran (or the Keychain refused a write):
        // nothing to report, the numbers stay, and the next refresh is not held off. The same when
        // this read lost the lease (back from a long suspension, say): nothing failed. Several
        // interruptions in a row are the Keychain refusing writes: that is shown.
        notSaving = interruptions.record(report.outcome)
        guard report.outcome != .interrupted, report.outcome != .leaseLost else {
            issue = nil
            return
        }
        lastRefresh = Date()
        switch report.outcome {
        case .ok: issue = nil
        case .needsLogin: issue = "学校登录过期了，重新登录一下。"
        case .failed(let e): issue = e.userMessage
        case .notSignedIn: configured = false; issue = nil
        case .interrupted, .leaseLost: issue = nil
        }
        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
        Reminders.shared.evaluateCampus(snapshot)
        if report.outcome == .ok { Reminders.shared.campusRead(snapshot) }
    }

    // MARK: Sign-in

    /// The official ecykt page finished signing in: adopt its `elecampus_state`, and keep the
    /// dorm address the portal page showed (read by the same sign-in).
    func adoptWebState(_ login: CampusWebLogin) async throws {
        // A sign-out asked for just before must not delete what this stores.
        await signOuts.finished()
        let started = signOutGeneration
        let session = session, state = login.state
        // Under the lease like the password sign-in: never beside the widget's own login.
        let summary = try await refresher.holdingLease { owning in
            try await session.adoptWebState(state, userAgent:EcyktSession.defaultUserAgent, owning:owning)
        }
        if summary.switchedAccount || summary.previousPersonUnconfirmed {
            await previousPersonCleared(unconfirmed:!summary.switchedAccount, dormAndMeterCleared:summary.dormAndMeterCleared)
        }
        await refresher.noteChange()
        // Signed out (or reset) while that ran: the dorm must not be written back.
        guard started == signOutGeneration else { return }
        let raw = login.dormAddress.trimmingCharacters(in:.whitespacesAndNewlines)
        if !raw.isEmpty {
            var stored = (try? AppEnvironment.schoolVault.profile()) ?? nil ?? SchoolProfile()
            if stored.residence?.raw != raw {
                stored.residence = PortalResidence(raw:raw)
                stored.meter = nil
            }
            try AppEnvironment.schoolVault.saveProfile(stored)
        }
        reload(); issue = nil; lastRefresh = nil
        powerChoices = []; powerMatchIssue = nil
    }

    /// The app's own login form. Throws `SchoolLoginFailure` for the login itself (shown on the
    /// form), or a service / storage error for the steps after it.
    func signIn(account: String, password: String, savePassword: Bool) async throws {
        // A sign-out asked for just before must not delete what this stores.
        await signOuts.finished()
        let session = session
        let summary = try await refresher.holdingLease { owning in
            try await session.signIn(account:account, password:password, savePassword:savePassword, owning:owning)
        }
        if summary.switchedAccount || summary.previousPersonUnconfirmed {
            await previousPersonCleared(unconfirmed:!summary.switchedAccount, dormAndMeterCleared:summary.dormAndMeterCleared)
        }
        await refresher.noteChange()
        reload(); issue = nil; lastRefresh = nil
        powerChoices = []; powerMatchIssue = nil
    }

    /// The login was someone else, or nothing showed it was the same person: Core already
    /// dropped their school data. Here: the widget
    /// snapshot, the hot-water binding made with their identity, and the one-time alert.
    /// Laundry (U净) is its own login and stays.
    private func previousPersonCleared(unconfirmed: Bool, dormAndMeterCleared: Bool) async {
        let refresher = refresher
        let hotWater = await AccountSwitch.clearPreviousPerson(
            snapshot:{ try await refresher.clear() },
            hotWater:{ ShowerModel.shared.clearBindingForAccountSwitch() })
        snapshot = .empty
        switchNotice = AccountSwitchNotice(previousPersonUnconfirmed:unconfirmed, dormAndMeterCleared:dormAndMeterCleared,
                                           hotWaterCleared:hotWater.noticed)
    }

    /// Settings › 学校账号 › 保存密码 on / 重新输入密码: one login checks the password before it
    /// is kept. Never switches person: Core refuses another account (`differentAccount`).
    /// Without a known account (signed in on the web page) the typed one is checked against
    /// the signed-in card.
    func savePassword(_ password: String, account typed: String?) async throws {
        // A sign-out asked for just before must not delete what this stores.
        await signOuts.finished()
        let known = account?.account
        guard let name = known ?? typed, !name.isEmpty else { throw SchoolLoginFailure.wrongCredentials }
        let session = session
        try await refresher.holdingLease { owning in try await session.savePassword(password, account:name, owning:owning) }
        reload()
        if known == nil { await refresh(force:true) }
    }

    /// 保存密码 off: the password goes at once; the account stays for display. Then once more
    /// under the lease: a widget refresh that read the account before and writes it back (a pause
    /// or a hold) would otherwise bring the password back. That second write leaves a password
    /// saved since (switched back on) alone. A failed write is thrown: the switch shows it.
    func forgetPassword() async throws {
        let session = session
        defer { reload() }
        guard let forgotten = try await session.forgetPassword() else { return }
        reload()
        try await refresher.holdingLease { owning in try await session.forgetPasswordAgain(forgotten:forgotten, owning:owning) }
    }

    /// Reset, before the stores are cleared: a refresh still running must not write the old
    /// values back afterwards, and the widget snapshot is cleared first so nothing rewrites it.
    func signOutForReset() async {
        signOutGeneration += 1
        _ = await signOuts.start().value
        configured = false; snapshot = .empty; profile = nil; issue = nil; account = nil
        powerChoices = []; powerMatchIssue = nil; lastRefresh = nil
    }

    func signOut() {
        signOutGeneration += 1
        // The lease goes first: a widget read in the middle of a login loses it and writes
        // nothing. Waiting for its file lock happens off the main thread.
        let signedOut = signOuts.start()
        Task {
            guard !(await signedOut.value) else { return }
            // Show what is still stored, so 退出登录 can be tried again.
            reload()
            signOutFailed = true
        }
        configured = false; snapshot = .empty; profile = nil; issue = nil; account = nil
        powerChoices = []; powerMatchIssue = nil
    }

    // MARK: Electricity

    /// Match the dorm's meter from the portal address (once after sign-in, or 「再找一次电表」).
    func matchPowerAutomatically() {
        guard configured, !matchingPower, !powerConfigured else { return }
        matchingPower = true; powerMatchIssue = nil; powerChoices = []
        Task {
            let before = await session.personStamp()
            var again = false
            do {
                // Core runs it again for the next person if someone else signed in meanwhile.
                let (stamp, found) = try await session.matchElectricity()
                // Someone else signed in after it answered: none of it is theirs, their own runs.
                if await session.isSamePerson(since:stamp) {
                    switch found {
                    case .matched:
                        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
                        await refresher.noteChange()
                        await refresh(force:true)
                    case .chooseAmong(let candidates): powerChoices = candidates.map { PowerChoice(candidate:$0, stamp:stamp) }
                    case .manualPicker: powerMatchIssue = "没自动找到电表，去「绑定电表」里选一下。"
                    case .noAddress: powerMatchIssue = "学校没给出宿舍地址，去「绑定电表」里选一下。"
                    }
                } else {
                    again = true
                }
            } catch {
                // Signed out or someone else signed in meanwhile: this match was theirs, say
                // nothing; whoever is signed in now gets their own (signed out: `configured` is
                // false and nothing runs).
                if await session.isSamePerson(since:before) { powerMatchIssue = AppErrorText.text(error) } else { again = true }
            }
            matchingPower = false
            if again { matchPowerAutomatically() }
        }
    }

    /// Binds one same-name choice. True once it is saved; false (the reason in
    /// `powerMatchIssue`, the choices kept) when it could not be.
    @discardableResult func choosePower(_ choice: PowerChoice) async -> Bool {
        guard !matchingPower else { return false }
        matchingPower = true
        defer { matchingPower = false }
        do {
            try await session.chooseMatchedMeter(choice.candidate, since:choice.stamp)
        } catch {
            powerMatchIssue = AppErrorText.text(error)
            return false
        }
        await refresher.noteChange()
        powerChoices = []; powerMatchIssue = nil
        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
        Task { await refresh(force:true) }
        return true
    }

    /// Manual picker.
    func directory(parent: String?) async throws -> [PowerNode] { try await session.directory(parent:parent) }
    func meterRows(nodeID: String) async throws -> [Meter] { try await session.meterRows(nodeID:nodeID) }
    /// `stamp`: `personStamp()` when the picker opened.
    func chooseMeter(nodeID: String, meter: Meter, nodeIsRoom: Bool, path: [String] = [], since stamp: Int) async throws {
        try await session.chooseMeter(nodeID:nodeID, meter:meter, nodeIsRoom:nodeIsRoom, path:path, since:stamp)
        await refresher.noteChange()
        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
        powerChoices = []; powerMatchIssue = nil
        await refresh(force:true)
    }

    // MARK: Recharge / hot water hand-off

    /// Both write the live card session back: under the lease, so never beside the widget's refresh.
    func rechargeSession(_ kind: RechargeKind) async throws -> RechargeWebSession {
        let session = session
        return try await refresher.holdingLease { owning in try await session.rechargeSession(kind, owning:owning) }
    }
    func showerHandoff() async throws -> ShowerHandoff {
        let session = session
        return try await refresher.holdingLease { owning in try await session.showerHandoff(owning:owning) }
    }
    /// Taken before `showerHandoff()`; `isSamePerson(since:)` says whether its identity still
    /// belongs to whoever is signed in.
    func personStamp() async -> Int { await session.personStamp() }
    func isSamePerson(since stamp: Int) async -> Bool { await session.isSamePerson(since:stamp) }
}
