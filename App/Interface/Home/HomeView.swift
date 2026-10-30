import SwiftUI
import UserNotifications
import Core

enum HomeRoute: Hashable { case power, powerSetup, card, shower, laundry, washerSetup }

/// Single home screen: date · the two numbers · update line · shower button · 洗衣 · 最近.
struct HomeView: View {
    @EnvironmentObject var shower: ShowerModel
    @EnvironmentObject var campus: CampusModel
    @EnvironmentObject var laundry: LaundryModel
    @Environment(\.scenePhase) var phase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var typeSize
    @State var path: [HomeRoute] = []
    @State var settings = false
    /// The sign-in form, from the expired-login line.
    @State var relogin = false
    @State var onboarding: OnboardingRequest?
    @State var scrolledPastDate = false
    @State var panel: SettlementResult?
    @State var startTick = 0
    @State var successTick = 0
    @State var errorTick = 0
    @ObservedObject var reminders = Reminders.shared
    @ObservedObject var resetter = AppResetter.shared
    @AppStorage("didSeeQuickSetup") var didSeeQuickSetup = false
    /// Last laundry order whose done panel was shown (once per order).
    @AppStorage("laundryDoneShownOrder") var laundryDoneShown = ""
    /// Negative top inset that lifts the date block into the navigation-bar row.
    let dateLift: CGFloat = -48
    #if DEBUG
    @State var demo: HomeData?
    @State var laundryDemo: LaundryDemo?
    @State var activityPreview: LaundryActivityPreview.Kind?
    @State var widgetPreview: WidgetPreview.Page?
    /// campusdaily://demo/login-loading: the sign-in sheet's opening state, nothing loaded.
    @State var loginDemo = false
    /// campusdaily://demo/recharge-blocked: the top-up page when its web view can't be allowed to load.
    @State var rechargeBlockedDemo = false
    #endif

    func openOnboarding() {
        onboarding = OnboardingRequest(step:.login)
    }

    /// Reset finished: back to the first-run guide as on a fresh install, no toast.
    func afterReset() {
        settings = false; path = []; panel = nil
        #if DEBUG
        demo = nil; laundryDemo = nil
        #endif
        successTick += 1
        // Let the settings sheet go first, otherwise the cover is not presented.
        Task { try? await Task.sleep(for:.milliseconds(600)); openOnboarding() }
    }

    /// Home is what the user sees: nothing pushed, no sheet, cover or panel on top, app in front.
    var homeClear: Bool {
        var clear = phase == .active && path.isEmpty && !settings && onboarding == nil && panel == nil && !shower.page.presented
        #if DEBUG
        clear = clear && activityPreview == nil && widgetPreview == nil
        #endif
        return clear
    }

    var settingsPreview: HomeData? {
        #if DEBUG
        return demo
        #else
        return nil
        #endif
    }

    var data: HomeData {
        #if DEBUG
        if let demo { return demo }
        #endif
        return HomeData(campus:campus, shower:shower, laundry:laundry)
    }

    var body: some View {
        let data = data
        ZStack {
            NavigationStack(path:$path) {
                ScrollViewReader { proxy in
                    ScrollView {
                        content(data).padding(.bottom,24)
                    }
                    .background(Theme.bg.ignoresSafeArea())
                    .navigationTitle(scrolledPastDate ? dateTitle : "")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement:.topBarTrailing) { gear } }
                    .refreshable { await pull() }
                    .onChange(of:data.shower.showering) { old, new in
                        if old == nil, new != nil { withAnimation(reduceMotion ? nil : Theme.spring) { proxy.scrollTo("top", anchor:.top) } }
                    }
                }
                .navigationDestination(for:HomeRoute.self) { route in destination(route) }
            }
            
            SettlementOverlay(result:$panel)
        }
        .sensoryFeedback(.impact(weight:.medium), trigger:startTick)
        .sensoryFeedback(.success, trigger:successTick)
        .sensoryFeedback(.error, trigger:errorTick)
        .accountSwitchAlert { campus.hotWaterSetupRequested = true; settings = true }
        .sheet(isPresented:$settings) { SettingsView(preview:settingsPreview).typesettingLanguage(Theme.typesetting) }
        .sheet(isPresented:$relogin) { SchoolReloginSheet().typesettingLanguage(Theme.typesetting) }
        // The shower page: down only by its own buttons, or a swipe while water runs (收起).
        .fullScreenCover(isPresented:Binding(get:{ shower.page.presented },
                                             set:{ if !$0, shower.page.presented { shower.pageEvent(.collapseTapped) } })) {
            #if DEBUG
            ShowerPageView(room:demo?.dorm ?? campus.room).environmentObject(shower).onOpenURL { handleDemo($0) }
            #else
            ShowerPageView(room:campus.room).environmentObject(shower)
            #endif
        }
        .fullScreenCover(item:$onboarding, onDismiss:{ didSeeQuickSetup = true }) { request in
            // .id: a new request must reset the cover's @State (step), not reuse it.
            // Own device chooser: a sheet from the home root can't show above this cover.
            let cover = OnboardingView(start:request.step, preview:request.preview) { onboarding = nil }.id(request.id)
            #if DEBUG
            cover.onOpenURL { handleDemo($0) }
            #else
            cover
            #endif
        }
        #if DEBUG
        .fullScreenCover(item:$activityPreview) { kind in
            LaundryActivityPreview(kind:kind).onTapGesture { activityPreview = nil }.onOpenURL { handleDemo($0) }
        }
        .sheet(isPresented:$loginDemo) {
            CampusLoginSheet(receive:{ _ in }, holdOpening:true)
        }
        .fullScreenCover(item:$widgetPreview) { page in
            WidgetPreview(page:page.number).onTapGesture { widgetPreview = nil }.onOpenURL { handleDemo($0) }
        }
        #endif
        .task {
            #if DEBUG
            if demo != nil { return }
            #endif
            // A reset the app was killed in: finished now (then the guide opens), or not, and why.
            await resetter.resumeIfInterrupted(campus:campus, water:shower, laundry:laundry)
            if resetter.completed > 0 { return }
            if !didSeeQuickSetup && !campus.configured && !shower.configured && !laundry.configured { openOnboarding() }
        }
        .alert(ResetLockText.blockedTitle, isPresented:Binding(get:{ resetter.resumeStopped != nil },
                                                               set:{ if !$0 { resetter.resumeStopped = nil } })) {
            Button("好", role:.cancel) {}
        } message: {
            Text(resetter.resumeStopped.map(ResetLockText.blockedMessage) ?? "")
        }
        .alert(resetter.resumeFailed ?? "", isPresented:Binding(get:{ resetter.resumeFailed != nil },
                                                                set:{ if !$0 { resetter.resumeFailed = nil } })) {
            Button("好", role:.cancel) {}
        }
        .onChange(of:phase) { _, value in
            if value == .active { Task { await campus.refresh(); await laundry.refresh(); await laundry.refreshOrder() } }
        }
        .onChange(of:shower.state.phase) { old, value in
            // The result is on the shower page; the balance it was taken from is read again.
            guard old != .done, value == .done else { return }
            Task { await campus.refresh(force:true) }
        }
        .onChange(of:shower.reviewRequested) { _, requested in
            guard requested else { return }
            shower.reviewRequested = false
            settings = false; path = [.shower]
        }
        .onChange(of:resetter.completed) { _, _ in afterReset() }
        .onChange(of:data.laundryDone, initial:true) { _, done in presentLaundryDone(done) }
        // A done panel that arrived while another panel was up is shown once that one closes.
        .onChange(of:panel == nil) { _, clear in if clear { presentLaundryDone(data.laundryDone) } }
        .modifier(ReminderHooks(settings:$settings, path:$path, homeClear:homeClear))
        .onOpenURL { url in
            // Widget tap: campusdaily://home back to the home screen; campusdaily://login (login
            // expired, never signed in) straight to the login step; campusdaily://settings/account
            // (automatic login held off) to Settings › 学校账号. Any app can open these, so they
            // never close a top-up page or a laundry order being paid.
            if url.scheme == "campusdaily", ["home", "login", "settings"].contains(url.host ?? ""),
               !WidgetLink.mayClosePages(rechargeOpen:path.contains(.card) || path.contains(.power),
                                         laundryOpen:path.contains(.laundry), laundry:laundry.checkout?.phase) {
                return
            }
            if url.scheme == "campusdaily", url.host == "home" { settings = false; path = []; return }
            // A paused automatic login (widget): Settings › 学校账号, where the pause is explained.
            if url.scheme == "campusdaily", url.host == "settings", url.path == "/account" {
                path = []; campus.accountPageRequested = true; settings = true
                return
            }
            if url.scheme == "campusdaily", url.host == "login" {
                let sheetUp = settings
                settings = false; path = []
                // As after a reset: let the settings sheet go first, or the cover is not presented.
                Task { if sheetUp { try? await Task.sleep(for:.milliseconds(600)) }; openOnboarding() }
                return
            }
            #if DEBUG
            handleDemo(url)
            #endif
        }
    }

    // MARK: Actions

    /// 开始洗澡 opens the shower page and starts connecting; a shower going on opens the page as
    /// it stands; a record to check opens the 核对 screen.
    func tap(_ kind: HomeShowerButton.Kind) {
        #if DEBUG
        if demo != nil { demoTap(kind); return }
        #endif
        switch kind {
        case .signIn: openOnboarding()
        case .review: path.append(.shower)
        case .showering, .settling, .starting: shower.pageEvent(.reopen)
        case .start:
            // An unchecked record blocks a new start: show it instead of failing.
            guard shower.mayStart else { path.append(.shower); return }
            startTick += 1
            shower.pageEvent(.startTapped)
        }
    }

    /// Pull to refresh: joins a running refresh. Only a pull the user made buzzes on failure.
    func pull() async {
        await campus.refresh(force:true)
        await laundry.refresh(force:true)
        if case .failed = HomeData(campus:campus, shower:shower, laundry:laundry).updateLine { errorTick += 1 }
    }

    func presentLaundryDone(_ done: HomeData.LaundryDone?) {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let done, done.id != laundryDoneShown, panel == nil else { return }
        laundryDoneShown = done.id
        successTick += 1
        panel = .laundryDone(amount:done.amount, detail:done.detail)
    }
}
