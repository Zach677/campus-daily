import Foundation
import Core

/// Resolves the money calls at call time, so the engine survives a profile import.
/// No gateway = a definite local refusal (nothing was sent, nothing issued).
final class ShowerGatewayBox: ShowerGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var gateway: ShowerGateway?
    var current: ShowerGateway? {
        get { lock.withLock { gateway } }
        set { lock.withLock { gateway = newValue } }
    }
    func authorize(_ binding: ShowerBinding, frame: Data) async throws -> ShowerAuthorization {
        guard let current else { throw ServiceError.badRequest(.lxt6) }
        return try await current.authorize(binding, frame:frame)
    }
    func settle(_ binding: ShowerBinding, frame: Data) async throws -> ShowerReceipt {
        guard let current else { throw ServiceError.badRequest(.lxt6) }
        return try await current.settle(binding, frame:frame)
    }
}

private struct ShowerModelHooks: ShowerHooks {
    func scheduleUnsettledReminder(after seconds: TimeInterval) async {}
    func cancelUnsettledReminder() async {}
    func diagnostic(_ event: String) async { await ShowerDiagnosticReport.record(event) }
}

/// Where the hot-water platform profile comes from (bundled / imported `.waterconfig`).
enum ShowerProfileFiles {
    static var importedURL: URL {
        FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask)[0]
            .appendingPathComponent("Water", isDirectory:true).appendingPathComponent("imported.waterconfig")
    }
    static let loader = ShowerProfileLoader(bundled: {
        guard let url = Bundle.main.url(forResource:"CampusWaterPlatform", withExtension:"json") else { return nil }
        return try Data(contentsOf:url)
    }, imported: { _ in
        let url = ShowerProfileFiles.importedURL
        return FileManager.default.fileExists(atPath:url.path) ? try Data(contentsOf:url) : nil
    })
    static let sources: [ShowerProfileSource] = [.imported(fileName:"imported.waterconfig"), .bundled]
    static func localProfile() async -> ShowerPlatformProfile? {
        if case .success(.local(let profile, _)) = await ShowerProfileResolver.firstUsable(sources, provider:loader) { return profile }
        return nil
    }
}

/// UI state over `ShowerEngine`. The engine owns the session; this class only forwards taps and
/// mirrors its state (home, detail page, Live Activity, reminder).
@MainActor final class ShowerModel: ObservableObject {
    static let shared = ShowerModel()
    @Published private(set) var state = ShowerState.idle
    @Published private(set) var binding: ShowerBinding?
    @Published private(set) var profile: ShowerPlatformProfile?
    @Published private(set) var busy = false
    /// Last action's message (nil = nothing to say).
    @Published private(set) var message: String?
    @Published private(set) var storageBlocked = false
    @Published private(set) var residenceReviewRequired = UserDefaults.standard.bool(forKey:PreferenceKey.waterNeedsResidenceReview)
    @Published private(set) var verifiedDevice: VerifiedShowerDevice?
    @Published private(set) var inspectionStatus: String?
    @Published private(set) var inspecting = false
    private var engine: ShowerEngine?
    private var observer: Task<Void, Never>?
    private let gateway = ShowerGatewayBox()
    private let bluetooth = BluetoothTransport()

    init() {
        binding = (try? AppEnvironment.waterVault.binding()) ?? nil
        if let persisted = (try? AppEnvironment.waterVault.showerState()) ?? nil { state = ShowerReducer.restore(persisted) }
        Task { await reloadProfile() }
    }

    // MARK: Derived state (what the views read)

    var configured: Bool { binding != nil }
    var display: ShowerDisplay { ShowerDisplay(state) }
    /// The build has no usable profile (neither bundled nor imported).
    var platformMissing: Bool { binding != nil && profile == nil }
    var mayStart: Bool {
        configured && !platformMissing && !residenceReviewRequired && engine != nil && !busy && !storageBlocked && state.canStart
    }
    var mayFinish: Bool { configured && engine != nil && !busy && !storageBlocked && state.canFinish }
    var mayResolveManually: Bool { engine != nil && !busy && state.canResolveManually }
    var mayRetrySettle: Bool { engine != nil && !busy && state.canRetrySettle }
    /// Binding / profile may change only with no session that could still be open or charged.
    var mayImport: Bool {
        !busy && !storageBlocked && (state.phase == .idle || state.phase == .done || (state.phase == .failed && state.failure?.needsReview == false))
    }
    var problem: Bool { state.failure?.needsReview == true || state.stateReviewRequired || storageBlocked }
    /// The close was sent or the settlement is unconfirmed: money may have moved.
    var unresolvedClose: Bool {
        guard state.phase == .failed, let reason = state.failure?.reason else { return false }
        return [.closeUnconfirmed, .settleRefused, .settleUncertain, .settleUnconfirmed].contains(reason)
    }
    var sessionStarted: Date? { state.startedAt }
    var lastEnded: Date? { state.phase == .done ? state.endedAt : nil }
    var lastCost: Decimal? { (state.phase == .done ? state.receipt : state.lastReceipt)?.amount?.yuan }
    /// Line under the headline on the hot-water page.
    var status: String {
        if storageBlocked { return "这台手机暂时存不了热水记录，重启 App 后再试。" }
        if let message { return message }
        if state.stateReviewRequired { return "水控没显示在用水，校日常就没发结束。去学校的热水记录里核对一下这次洗澡。" }
        switch state.phase {
        case .failed: return ShowerDisplay.failureTitle(state.failure)
        case .writePending: return ShowerDisplay.writeUnconfirmedHint
        default: break
        }
        if !configured { return "选好宿舍后就能用热水。" }
        if platformMissing { return Self.platformMissingText }
        return ""
    }
    nonisolated static let platformMissingText = "这个版本没带热水配置，热水暂时用不了。"

    // MARK: Setup

    func reloadProfile() async {
        profile = await ShowerProfileFiles.localProfile()
        rebuildEngine()
    }

    /// (Re)creates the engine for the current binding. Only while nothing is in flight.
    private func rebuildEngine() {
        guard !busy else { return }
        observer?.cancel(); observer = nil; engine = nil
        guard binding != nil else {
            state = ((try? AppEnvironment.waterVault.showerState()) ?? nil).map(ShowerReducer.restore) ?? .idle
            return
        }
        let bleName: String
        if let profile {
            bleName = profile.bleName
            gateway.current = LxtClient(http:AppEnvironment.waterHTTP, profile:profile)
        } else {
            bleName = ""
            gateway.current = nil
        }
        do {
            let engine = try ShowerEngine(transport:bluetooth, gateway:gateway, vault:AppEnvironment.waterVault,
                                          configuration:.init(bleName:bleName,
                                                              reminderMinutes:UserDefaults.standard.integer(forKey:ReminderKey.unsettledMinutes)),
                                          hooks:ShowerModelHooks())
            self.engine = engine
            observer = Task { [weak self] in
                let blocked = await engine.storageBlocked
                self?.storageBlocked = blocked
                for await next in await engine.updates() {
                    guard let self else { return }
                    self.apply(next)
                    self.storageBlocked = await engine.storageBlocked
                }
            }
        } catch {
            storageBlocked = true
        }
    }

    private func apply(_ next: ShowerState) {
        let old = state
        state = next
        if next != old {
            ShowerActivityController.shared.sync(state:next)
            Reminders.shared.syncShower(started:next.mayBeFlowing ? next.startedAt : nil)
        }
    }

    /// Onboarding saved a binding (dorm + controller).
    func saveBinding(_ value: ShowerBinding) throws {
        guard mayImport else { throw ShowerEngineError.blocked }
        var value = value
        // Re-binding the same machine keeps the controller already verified for it.
        if value.peripheralID == nil, let old = binding, old.machineId == value.machineId { value.peripheralID = old.peripheralID }
        try AppEnvironment.waterVault.saveBinding(value)
        binding = value
        verifiedDevice = nil
        if residenceReviewRequired { setResidenceReview(false) }
        rebuildEngine()
    }

    func setResidenceReview(_ value: Bool) {
        residenceReviewRequired = value
        UserDefaults.standard.set(value, forKey:PreferenceKey.waterNeedsResidenceReview)
    }

    /// `.waterconfig` import (Settings › 高级). The profile is the shared platform part only.
    func importConfig(_ url: URL) throws {
        guard mayImport else { throw ShowerEngineError.blocked }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf:url)
        _ = try ShowerConfigFile.parse(data, source:.imported(fileName:"imported.waterconfig"))
        let target = ShowerProfileFiles.importedURL
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(), withIntermediateDirectories:true)
        try data.write(to:target, options:[.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Task { await reloadProfile() }
    }

    // MARK: Actions

    /// 开始洗澡 / 结束并结算 (home, detail page, Shortcuts, Live Activity).
    func run(start: Bool) async throws {
        guard let engine, let binding else { throw ShowerEngineError.notAllowed }
        guard !busy else { throw ShowerEngineError.busy }
        if start {
            guard mayStart else { throw ShowerEngineError.blocked }
        } else {
            guard state.canFinish else { throw ShowerEngineError.notAllowed }
            ShowerActivityController.shared.settling()
        }
        busy = true; message = nil
        defer { busy = false }
        do {
            let result = start ? try await engine.start(binding) : try await engine.finish(binding)
            apply(result)
            // The engine saves the verified controller into the stored binding; pick it up so the
            // next start goes to it directly instead of after a relaunch.
            if start, let stored = (try? AppEnvironment.waterVault.binding()) ?? nil, stored.machineId == binding.machineId {
                self.binding = stored
            }
            message = Self.noticeText(result.notice)
            if result.phase == .failed { throw ShowerEngineError.notAllowed }
            if !start, result.phase != .done { throw ShowerEngineError.notAllowed }
        } catch {
            storageBlocked = await engine.storageBlocked
            throw error
        }
    }

    /// Read-only state probe of the session's controller (Settings › 高级 › 检查水控状态).
    func reviewCurrentSession() async {
        guard let engine, let binding, !busy, state.canFinish else { return }
        busy = true; defer { busy = false }
        if let result = try? await engine.review(binding) {
            apply(result)
            message = Self.noticeText(result.notice) ?? (result.phase == .running ? "水控显示正在用水。" : nil)
        }
    }

    func resolveManually() async {
        guard let engine, !busy else { return }
        busy = true; defer { busy = false }
        if let result = try? await engine.resolveManually() { apply(result); message = nil }
    }

    func requestSettleRetry() async {
        guard let engine, !busy else { return }
        if let result = try? await engine.requestSettleRetry() { apply(result) }
    }

    func confirmSettleRetry() async {
        guard let engine, let binding, !busy else { return }
        busy = true; defer { busy = false }
        if let result = try? await engine.confirmSettleRetry(binding) { apply(result) }
    }

    func dismiss() async {
        guard let engine, !busy else { return }
        if let result = try? await engine.dismiss() { apply(result) }
    }

    /// Read-only: connect, ask the identity (0xAA), disconnect. Never sent during a session.
    func inspectBluetooth() async {
        guard let binding, mayImport, !inspecting else { return }
        let bleName = profile?.bleName ?? ""
        guard !bleName.isEmpty else { inspectionStatus = Self.platformMissingText; return }
        inspecting = true; inspectionStatus = nil; verifiedDevice = nil
        defer { inspecting = false }
        do {
            let nearby = try await bluetooth.inspect(bleName:bleName, remembered:binding.peripheralID)
            guard nearby > 0 else { inspectionStatus = Self.deviceText(.notFound); return }
            let id = try await bluetooth.connect(bleName:bleName, machineID:binding.machineId, required:nil, preferred:binding.peripheralID)
            let frame = try await bluetooth.exchange(ShowerFrames.probeCommand)
            await bluetooth.disconnect()
            guard let identity = ShowerFrames.identity(frame) ?? (ShowerFrames.isActive(frame) ? binding.machineId : nil) else {
                inspectionStatus = Self.deviceText(.malformedFrame); return
            }
            guard identity == binding.machineId.uppercased() else { inspectionStatus = "附近的水控不是你宿舍的那台。"; return }
            verifiedDevice = VerifiedShowerDevice(id:id, name:bleName, machineID:identity, rssi:nil, nearbyCount:nearby, verifiedAt:Date())
            rememberVerified(id, for:binding)
            inspectionStatus = "找到了你宿舍的水控。"
        } catch {
            await bluetooth.disconnect()
            inspectionStatus = Self.deviceText((error as? ShowerDeviceError) ?? .disconnected)
        }
    }

    /// The check proved this controller's identity: remember it for the next start.
    private func rememberVerified(_ id: String, for checked: ShowerBinding) {
        guard checked.peripheralID != id, var stored = (try? AppEnvironment.waterVault.binding()) ?? nil,
              stored.machineId == checked.machineId else { return }
        stored.peripheralID = id
        guard (try? AppEnvironment.waterVault.saveBinding(stored)) != nil else { return }
        binding = stored
    }

    func exportDiagnostics() throws -> URL {
        try ShowerDiagnosticReport.export(phase:state.phase, needsReview:problem, manualSettleAttempts:state.manualSettleAttempts)
    }

    func show(_ error: Error) { message = AppErrorText.text(error) }

    // MARK: Copy

    static func noticeText(_ notice: ShowerNotice?) -> String? {
        switch notice {
        case nil: return nil
        case .device(let e)?: return deviceText(e)
        case .notActive?: return "水控没显示在用水，校日常就没发结束。去学校的热水记录里核对一下这次洗澡。"
        case .wrongDevice?: return "附近的水控不是你宿舍的那台。"
        case .writeUnconfirmed?: return ShowerDisplay.writeUnconfirmedHint
        }
    }

    static func deviceText(_ e: ShowerDeviceError) -> String {
        switch e {
        case .bluetoothOff: return "蓝牙没开，打开后再试。"
        case .notFound: return "附近没找到水控，靠近一点再试。"
        case .ambiguous: return "附近有好几台同名水控，没认出你宿舍的那台。靠近一点再试。"
        case .timedOut: return "水控没回应，靠近一点再试。"
        case .disconnected, .interrupted: return "和水控的连接断了，再试一次。"
        case .malformedFrame: return "水控回的内容看不懂，再试一次。"
        case .busy: return "正在和水控通信，稍等一下。"
        }
    }
}
