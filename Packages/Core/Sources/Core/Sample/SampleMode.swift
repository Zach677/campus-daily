import Foundation
import Observation

/// What the sample mode refuses: everything that pays, opens water, binds a device, sends
/// something or changes what is stored.
public enum SampleAction: String, Sendable, CaseIterable {
    case cardRecharge, powerRecharge, bindMeter
    case startShower, checkController, importShowerProfile
    case startWash, payLaundry, cancelLaundry, bindWasher
    case reminders, sendFeedback, resetApp, schoolAccount
}

/// What became of 「先看看示例」 (`SampleMode.enter`).
public enum SampleEntry: Equatable, Sendable {
    case entered
    /// A real shower is not over, or its record is not known (`LiveShowerGate`): nothing opens.
    case refused
}

/// What became of a link that came in (`SampleMode.open`).
public enum SampleLinkOutcome: Equatable, Sendable {
    /// Outside the sample: the live app handles it as before.
    case live
    /// campusdaily://login or ://settings/account: the sample is left first, then the live root
    /// opens the link (`takePendingLink`).
    case leftSample
    /// Another campusdaily link: the sample stays, nothing opens.
    case ignored
    /// Another app's answer (Alipay's, say): kept for the live app, handed over on leaving
    /// (`takeHeldLinks`).
    case held
}

/// 「先看看示例」: the app on synthetic data (`SampleData`) without an account. Kept in memory
/// only (a new launch starts outside it). While it is on the scene shows a graph of models built
/// on `services` (`CampusServices.sample()`, new for each sample) instead of the live one, so
/// no sample page can reach a real store, service, session or record. Blocked actions say
/// `SampleCopy.blocked`.
@MainActor @Observable public final class SampleMode {
    public var isActive: Bool { services != nil }
    /// The sample's own services while it is on; nil outside it.
    public private(set) var services: CampusServices?
    /// The action whose message is up (`SampleCopy.blocked`); nil when none.
    public var blocked: SampleAction?
    /// Set by `leave`: the root shown next opens the login step, then calls `takeLogin`.
    public private(set) var loginDue = false
    /// The widget's link for the live root to open (`takePendingLink`).
    public private(set) var pendingLink: RootLink?
    /// Other apps' links that came in during the sample, for the live app (`takeHeldLinks`).
    @ObservationIgnored private var held: [URL] = []

    /// Decides between the sample and a real shower start (`LiveShowerGate`).
    @ObservationIgnored public let gate: LiveShowerGate

    public init(gate: LiveShowerGate) { self.gate = gate }

    /// The real shower is ended from the Live Activity or Siri (`LiveShowerFinish`): back to the
    /// live app as it was, not the login step. The sample's services go.
    public func leaveForLive() {
        services = nil
        blocked = nil
        loginDue = false
        gate.sampleLeft()
    }

    /// From the login step: a new sample on new services, nothing chosen in it yet. Refused
    /// unless the real shower record is known to be at rest and no real start is under way
    /// (`LiveShowerGate.claimSample`); from then on no real start begins until it is left.
    /// The only way in: no link opens the sample.
    @discardableResult
    public func enter() -> SampleEntry {
        // Shown already: the gate is held, a new sample starts over.
        if !isActive, !gate.claimSample() { return .refused }
        services = .sample()
        blocked = nil
        loginDue = false
        pendingLink = nil
        return .entered
    }

    /// 去登录: back to the live app, on the login step. The sample's services, and everything
    /// chosen in it, go.
    public func leave() {
        services = nil
        blocked = nil
        loginDue = true
        gate.sampleLeft()
    }

    /// The login step is opening: once per `leave`. True when it was due.
    public func takeLogin() -> Bool {
        guard loginDue else { return false }
        loginDue = false
        return true
    }

    /// What the scene runs on: the sample's services while it is on, `live` otherwise.
    public func services(live: CampusServices) -> CampusServices {
        services ?? live
    }

    /// Every link the app is opened with comes here first, the one place links are dispatched.
    /// The widget's links (`RootLink`) are left for the live root (`takePendingLink`), never
    /// for a sample page: outside the sample at once (`.live`); in it, the login and 学校账号
    /// links leave the sample first (`.leftSample`) and the others are dropped. Other apps'
    /// answers are the live app's: at once outside the sample, after it otherwise (`.held`).
    public func open(_ url: URL) -> SampleLinkOutcome {
        guard isActive else {
            if let link = RootLink(url) { pendingLink = link }
            return .live
        }
        if let link = RootLink(url) {
            switch link {
            case .login, .settings(account: true):
                services = nil
                blocked = nil
                loginDue = false
                pendingLink = link
                gate.sampleLeft()
                return .leftSample
            case .home, .settings(account: false):
                return .ignored
            }
        }
        if url.scheme == "campusdaily" { return .ignored }
        held.append(url)
        return .held
    }

    /// The widget's link, once, for the live root; nil in the sample.
    public func takePendingLink() -> RootLink? {
        guard !isActive, let link = pendingLink else { return nil }
        pendingLink = nil
        return link
    }

    /// Other apps' links held during the sample, once, after it; none while it is on.
    public func takeHeldLinks() -> [URL] {
        guard !isActive else { return [] }
        defer { held = [] }
        return held
    }

    /// Runs `real` outside the sample. Inside, `real` does not run and the message comes up
    /// (`blocked`). True when `real` ran.
    @discardableResult
    public func perform(_ action: SampleAction, _ real: () -> Void) -> Bool {
        guard !isActive else { blocked = action; return false }
        real()
        return true
    }

    @discardableResult
    public func perform(_ action: SampleAction, _ real: () async -> Void) async -> Bool {
        guard !isActive else { blocked = action; return false }
        await real()
        return true
    }
}
