import SwiftUI
import UserNotifications
import Core

#if DEBUG
extension HomeView {
    /// Also called from inside the onboarding cover: while a full-screen cover is up,
    /// the URL is delivered to the cover's hierarchy instead of the home view.
    func handleDemo(_ url: URL) {
            if let kind = notifyDemo(url) { Task { await reminders.demoNotify(kind) }; return }
            if let page = WidgetPreview.handle(url) { activityPreview = nil; widgetPreview = page; return }
            widgetPreview = nil
            if let kind = LaundryActivityPreview.handle(url) { activityPreview = kind; return }
            activityPreview = nil
            if LaundryActivityController.handleDemo(url) { return }
            if url.host == "demo", url.lastPathComponent == "login-loading" {
                onboarding = nil; settings = false; path = []
                demo = HomeDemo.normal.content().0
                Task { try? await Task.sleep(for:.milliseconds(400)); loginDemo = true }
                return
            }
            if let onboard = OnboardingDemo.handle(url) {
                settings = false; path = []
                onboarding = OnboardingRequest(step:onboard.0, preview:onboard.1)
                return
            }
            if let laundryPage = LaundryDemo.handle(url) {
                onboarding = nil; settings = false
                demo = HomeDemo.normal.content().0
                laundryDemo = laundryPage
                panel = laundryPage.panel
                // Fresh push so the page's @State starts from this demo.
                path = []
                Task { try? await Task.sleep(for:.milliseconds(350)); path = [.laundry] }
                return
            }
            if url.host == "demo", url.lastPathComponent == "recharge-blocked" {
                onboarding = nil; settings = false
                demo = HomeDemo.normal.content().0
                rechargeBlockedDemo = true
                path = []
                Task { try? await Task.sleep(for:.milliseconds(350)); path = [.card] }
                return
            }
            if url.host == "demo", url.lastPathComponent.hasPrefix("account-switched") {
                // Account-switch alert over the home demo; 「-water」 adds the hot-water line and button.
                onboarding = nil; settings = false; path = []
                demo = HomeDemo.normal.content().0
                campus.switchNotice = AccountSwitchNotice(hotWaterCleared:url.lastPathComponent.hasSuffix("-water"))
                return
            }
            if url.host == "demo", url.lastPathComponent == "permission" {
                // Pre-permission sheet over the home demo, whatever the real authorization is.
                onboarding = nil; settings = false; path = []
                demo = HomeDemo.normal.content().0
                reminders.prompt = .app
                return
            }
            if url.host == "demo", url.lastPathComponent == "permission-home" {
                // Home demo, then the first-home-read trigger: the sheet appears once home is clear.
                onboarding = nil; settings = false; path = []; panel = nil; laundryDemo = nil
                demo = HomeDemo.normal.content().0
                reminders.demoHomeRead()
                return
            }
            if url.host == "demo", let record = ShowerPageDemo.record(url.lastPathComponent) {
                // The shower page over the home demo, on a synthetic record (nothing connects).
                onboarding = nil; settings = false; path = []; panel = nil; laundryDemo = nil
                demo = HomeDemo.normal.content().0
                // Collapsed while water runs, home shows the showering button, as it would live.
                if record.phase == .running, let start = record.startedAt { demo?.shower = .showering(start) }
                shower.showDemoPage(record)
                return
            }
            let settingsDemos: [String:UNAuthorizationStatus] = ["settings":.authorized, "settings-notif-off":.denied,
                                                                  "settings-ask":.notDetermined, "settings-password-on":.authorized,
                                                                  "settings-paused":.authorized, "settings-paused-noanswer":.authorized,
                                                                  "settings-web-login":.authorized,
                                                                  "settings-reset-shower":.authorized, "settings-reset-unsure":.authorized,
                                                                  "settings-laundry-off":.authorized, "settings-laundry-locked":.authorized]
            reminders.demoStatus = settingsDemos[url.lastPathComponent]
            guard let result = HomeDemo.handle(url) else { return }
            onboarding = nil; settings = false; path = []; laundryDemo = nil
            withAnimation(Theme.spring) {
                demo = result?.0
                panel = result?.1
            }
            if settingsDemos[url.lastPathComponent] != nil {
                // Let any open sheet dismiss first, otherwise the reopen is coalesced away.
                Task { try? await Task.sleep(for:.milliseconds(500)); settings = true }
            }
    }
    /// campusdaily://demo/sh-<face>: connect, run, settle, done, nocon, denied, busy, unsure.
    enum ShowerPageDemo {
        static func record(_ name: String, now: Date = Date()) -> ShowerState? {
            let start = now.addingTimeInterval(-(8 * 60 + 42))
            func failed(_ reason: ShowerFailureReason, review: Bool) -> ShowerState {
                ShowerState(phase:.failed, startedAt:start,
                            failure:ShowerFailure(reason:reason, needsReview:review))
            }
            switch name {
            case "sh-connect": return ShowerState(phase:.authorizing, startedAt:now)
            case "sh-run": return ShowerState(phase:.running, startedAt:start)
            case "sh-settle": return ShowerState(phase:.settling, startedAt:start)
            case "sh-done":
                return ShowerState(phase:.done, startedAt:now.addingTimeInterval(-11 * 60),
                                   receipt:ShowerReceipt(amount:Money(fen:132)), endedAt:now)
            case "sh-nocon": return failed(.deviceUnavailable, review:false)
            case "sh-denied": return failed(.authorizeRefused, review:false)
            case "sh-busy": return failed(.deviceBusy, review:false)
            case "sh-unsure": return failed(.settleUncertain, review:true)
            default: return nil
            }
        }
    }

    /// campusdaily://demo/notify/<kind>
    func notifyDemo(_ url: URL) -> String? {
        let parts = Array(url.pathComponents.dropFirst())
        guard url.scheme == "campusdaily", url.host == "demo", parts.first == "notify" else { return nil }
        return parts.count > 1 ? parts[1] : "laundry"
    }

    func demoTap(_ kind: HomeShowerButton.Kind) {
        switch kind {
        case .start:
            startTick += 1
            withAnimation(Theme.spring) { demo?.shower = .showering(Date()) }
        case .showering where shower.page.record.phase == .running:
            // Collapsed from a demo page: open it again, as the live button does.
            shower.pageEvent(.reopen)
        case .showering(let start, _):
            withAnimation(Theme.spring) { demo?.shower = .settling(start) }
            Task {
                try? await Task.sleep(for:.seconds(1.5))
                let minutes = max(1, Int((Date().timeIntervalSince(start) / 60).rounded()))
                withAnimation(Theme.spring) {
                    demo?.shower = .idle
                    demo?.lastShowerMinutes = minutes; demo?.lastShowerCost = Decimal(string:"1.32")
                    demo?.appActivities.insert(AppActivity(id:"demo-\(Date().timeIntervalSince1970)", kind:.shower(minutes:minutes),
                                                           date:Date(), amount:Money(fen:132)), at:0)
                }
                successTick += 1
                panel = .settled(minutes:minutes, amount:Decimal(string:"1.32"))
            }
        case .signIn: openOnboarding()
        case .review, .settling: path.append(.shower)
        case .starting: break
        }
    }
}
#endif
