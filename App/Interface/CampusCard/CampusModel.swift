import Foundation
import Core

/// One same-name meter offered when the electricity match is ambiguous.
struct PowerChoice: Identifiable, Equatable {
    var id: String { meter.comAddress }
    let meter: Meter
    var label: String {
        var parts = [meter.name]
        if let money = meter.leftMoney { parts.append("电费 " + Theme.yuan(money.yuan)) }
        if let kwh = meter.remainingKWh { parts.append("剩 " + Theme.kwh(kwh) + " 度") }
        return parts.joined(separator:" · ")
    }
}

/// UI state over `SchoolSession` (refresh, electricity resolution, sign-in/out). No school logic here.
@MainActor final class CampusModel: ObservableObject {
    static let shared = CampusModel()
    @Published private(set) var configured = false
    @Published private(set) var loading = false
    @Published private(set) var snapshot: HomeSnapshot = .empty
    @Published private(set) var profile: SchoolProfile?
    @Published private(set) var issue: String?
    @Published private(set) var matchingPower = false
    @Published private(set) var powerChoices: [PowerChoice] = []
    @Published private(set) var powerMatchIssue: String?
    /// The account signed in with the app's own form (nil after a web sign-in, which never
    /// tells us the account). Its password is present only when the user chose to save it.
    @Published private(set) var account: SchoolAccount?
    private var lastRefresh: Date?
    private var refreshesRunning = 0
    /// Bumped by `signOut()`: a refresh that returns afterwards must not put the old values back.
    private var signOutGeneration = 0
    private let session = AppEnvironment.school
    private let refresher = AppEnvironment.refresher

    init() { reload() }

    /// Re-read the Keychain (launch, after sign-in/out).
    func reload() {
        configured = ((try? AppEnvironment.schoolVault.ecyktSession()) ?? nil) != nil
        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
        account = (try? AppEnvironment.schoolVault.account()) ?? nil
        snapshot = refresher.latest()
    }

    /// Settings › 学校账号 › 保存密码.
    var passwordSaved: Bool { account?.password != nil }

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
        // A cancelled refresh (the view went away, the pull was abandoned) reads as offline; that
        // says nothing about the school, so it neither shows an issue nor counts as a refresh.
        guard !Task.isCancelled else { return }
        lastRefresh = Date()
        switch report.outcome {
        case .ok: issue = nil
        case .needsLogin: issue = "学校登录过期了，重新登录一下。"
        case .failed(let e): issue = e.userMessage
        case .notSignedIn: configured = false; issue = nil
        }
        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
        Reminders.shared.evaluateCampus(snapshot)
        if report.outcome == .ok { Reminders.shared.campusRead(snapshot) }
    }

    // MARK: Sign-in

    /// The official ecykt page finished signing in: adopt its `elecampus_state`, and keep the
    /// dorm address the portal page showed (read by the same sign-in).
    func adoptWebState(_ login: CampusWebLogin) async throws {
        _ = try await session.adoptWebState(login.state, portalToken:nil, userAgent:EcyktSession.defaultUserAgent)
        await refresher.noteChange()
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
        _ = try await session.signIn(account:account, password:password, savePassword:savePassword)
        await refresher.noteChange()
        reload(); issue = nil; lastRefresh = nil
        powerChoices = []; powerMatchIssue = nil
    }

    func signOut() {
        signOutGeneration += 1
        let session = session, refresher = refresher
        Task { try? await session.signOut(); try? await refresher.clear() }
        configured = false; snapshot = .empty; profile = nil; issue = nil; account = nil
        powerChoices = []; powerMatchIssue = nil
    }

    // MARK: Electricity

    /// Match the dorm's meter from the portal address (once after sign-in, or 「再找一次电表」).
    func matchPowerAutomatically() {
        guard configured, !matchingPower, !powerConfigured else { return }
        matchingPower = true; powerMatchIssue = nil; powerChoices = []
        Task {
            defer { matchingPower = false }
            do {
                switch try await session.resolveElectricity() {
                case .matched:
                    profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
                    await refresher.noteChange()
                    await refresh(force:true)
                case .chooseAmong(let meters): powerChoices = meters.map(PowerChoice.init)
                case .manualPicker: powerMatchIssue = "没自动找到电表，去「绑定电表」里选一下。"
                case .noAddress: powerMatchIssue = "学校没给出宿舍地址，去「绑定电表」里选一下。"
                }
            } catch { powerMatchIssue = AppErrorText.text(error) }
        }
    }

    func choosePower(_ choice: PowerChoice) {
        guard !matchingPower else { return }
        matchingPower = true
        Task {
            defer { matchingPower = false }
            do {
                try await session.chooseMatchedMeter(choice.meter)
                await refresher.noteChange()
                powerChoices = []; powerMatchIssue = nil
                profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
                await refresh(force:true)
            } catch { powerMatchIssue = AppErrorText.text(error) }
        }
    }

    /// Manual picker.
    func directory(parent: String?) async throws -> [PowerNode] { try await session.directory(parent:parent) }
    func meterRows(nodeID: String) async throws -> [Meter] { try await session.meterRows(nodeID:nodeID) }
    func chooseMeter(nodeID: String, meter: Meter, nodeIsRoom: Bool) async throws {
        try await session.chooseMeter(nodeID:nodeID, meter:meter, nodeIsRoom:nodeIsRoom)
        await refresher.noteChange()
        profile = (try? AppEnvironment.schoolVault.profile()) ?? nil
        powerChoices = []; powerMatchIssue = nil
        await refresh(force:true)
    }

    // MARK: Recharge / hot water hand-off

    func rechargeSession(_ kind: RechargeKind) async throws -> RechargeWebSession { try await session.rechargeSession(kind) }
    func showerHandoff() async throws -> ShowerHandoff { try await session.showerHandoff() }
}
