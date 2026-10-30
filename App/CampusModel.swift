import Foundation
import DailyCore
import SchoolClient

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
    private var lastRefresh: Date?
    private let session = AppServices.school

    init() { reload() }

    /// Re-read the Keychain (launch, after sign-in/out).
    func reload() {
        configured = ((try? AppServices.schoolVault.ecyktSession()) ?? nil) != nil
        profile = (try? AppServices.schoolVault.profile()) ?? nil
        snapshot = ((try? AppServices.snapshots.loadSnapshot()) ?? nil) ?? .empty
    }

    var address: DormAddress? { profile?.residence?.address }
    /// 「9 栋 199」 style label, or 「未配置」.
    var room: String {
        if let address { return address.building + " 栋 " + address.room }
        return Theme.dorm(snapshot.roomLabel ?? profile?.meter?.label ?? "") ?? "未配置"
    }
    var powerConfigured: Bool { profile?.meter != nil }
    var balance: Decimal? { snapshot.card.value?.yuan }
    var meter: Meter? { snapshot.power.value }

    // MARK: Refresh

    /// Foreground refresh; `force` skips the 60 s throttle.
    func refresh(force: Bool = false, inBackground: Bool = false) async {
        guard configured, !loading else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        loading = true; defer { loading = false }
        let report = await session.refresh(inBackground:inBackground)
        snapshot = report.snapshot
        lastRefresh = Date()
        switch report.outcome {
        case .ok: issue = nil
        case .needsLogin: issue = "学校登录过期了，重新登录一下。"
        case .failed(let e): issue = e.userMessage
        case .notSignedIn: configured = false; issue = nil
        }
        profile = (try? AppServices.schoolVault.profile()) ?? nil
        Reminders.shared.evaluateCampus(snapshot)
        if report.outcome == .ok { Reminders.shared.campusRead(snapshot) }
    }

    // MARK: Sign-in

    /// The official ecykt page finished signing in: adopt its `elecampus_state`, and keep the
    /// dorm address the portal page showed (read by the same sign-in).
    func adoptWebState(_ login: CampusWebLogin) async throws {
        _ = try await session.adoptWebState(login.state, portalToken:nil, userAgent:EcyktSession.defaultUserAgent)
        let raw = login.dormAddress.trimmingCharacters(in:.whitespacesAndNewlines)
        if !raw.isEmpty {
            var stored = (try? AppServices.schoolVault.profile()) ?? nil ?? SchoolProfile()
            if stored.residence?.raw != raw {
                stored.residence = PortalResidence(raw:raw)
                stored.meter = nil
            }
            try AppServices.schoolVault.saveProfile(stored)
        }
        reload(); issue = nil; lastRefresh = nil
        powerChoices = []; powerMatchIssue = nil
    }

    func signOut() {
        let session = session
        Task { try? await session.signOut() }
        configured = false; snapshot = .empty; profile = nil; issue = nil
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
                case .matched: profile = (try? AppServices.schoolVault.profile()) ?? nil; await refresh(force:true)
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
                powerChoices = []; powerMatchIssue = nil
                profile = (try? AppServices.schoolVault.profile()) ?? nil
                await refresh(force:true)
            } catch { powerMatchIssue = AppErrorText.text(error) }
        }
    }

    /// Manual picker.
    func directory(parent: String?) async throws -> [PowerNode] { try await session.directory(parent:parent) }
    func meterRows(nodeID: String) async throws -> [Meter] { try await session.meterRows(nodeID:nodeID) }
    func chooseMeter(nodeID: String, meter: Meter, nodeIsRoom: Bool) async throws {
        try await session.chooseMeter(nodeID:nodeID, meter:meter, nodeIsRoom:nodeIsRoom)
        profile = (try? AppServices.schoolVault.profile()) ?? nil
        powerChoices = []; powerMatchIssue = nil
        await refresh(force:true)
    }

    // MARK: Recharge / hot water hand-off

    func rechargeSession(_ kind: RechargeKind) async throws -> RechargeWebSession { try await session.rechargeSession(kind) }
    func waterHandoff() async throws -> WaterHandoff { try await session.waterHandoff() }
}
