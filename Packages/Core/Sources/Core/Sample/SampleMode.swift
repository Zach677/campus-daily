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

/// 「先看看示例」: the app on synthetic data (`SampleData`) without an account. Kept in memory
/// only (a new launch starts outside it), and while it is on nothing real runs: no request,
/// no Keychain, preferences, App Group or widget write. Blocked actions say `SampleCopy.blocked`.
@MainActor @Observable public final class SampleMode {
    public private(set) var isActive = false
    /// The theme picked in 主题 while in the sample, held here instead of stored; nil: the stored one.
    public private(set) var theme: AppTheme?
    /// The action whose message is up (`SampleCopy.blocked`); nil when none.
    public var blocked: SampleAction?
    /// Set by `leave`: the root shown next opens the login step, then calls `takeLogin`. The
    /// root may be another than the one left (a theme picked in the sample goes with it).
    public private(set) var loginDue = false

    public init() {}

    /// From the login step: the sample shows, nothing chosen in it yet.
    public func enter() {
        isActive = true
        theme = nil
        blocked = nil
        loginDue = false
    }

    /// 去登录: back to the login step; the theme picked in the sample goes with it.
    public func leave() {
        isActive = false
        theme = nil
        blocked = nil
        loginDue = true
    }

    /// The login step is opening: once per `leave`. True when it was due.
    public func takeLogin() -> Bool {
        guard loginDue else { return false }
        loginDue = false
        return true
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

    /// A write to what the app keeps (UserDefaults, the App Group, the Keychain, files): dropped
    /// in the sample, run as is outside it.
    public func persist(_ write: () throws -> Void) rethrows {
        guard !isActive else { return }
        try write()
    }

    /// 主题's choice over `current`: in the sample held here (the same rules as storing it: not
    /// while `themeLock` holds, not when already shown), outside stored with
    /// `ThemePreference.select`. True when the theme changed.
    public func selectTheme(_ theme: AppTheme, current: AppTheme, preference: ThemePreference, lock themeLock: ThemeLock?,
                            under lock: any SharedLock) throws -> Bool {
        guard isActive else { return try preference.select(theme, current: current, lock: themeLock, under: lock) }
        guard theme != current, themeLock == nil else { return false }
        self.theme = theme
        return true
    }
}
