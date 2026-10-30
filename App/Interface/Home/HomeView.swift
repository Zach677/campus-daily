import SwiftUI
import UserNotifications
import Core

enum HomeRoute: Hashable { case power, powerSetup, card, water, laundry, washerSetup }

/// Single home screen: date · the two numbers · update line · shower button · 洗衣 · 最近.
struct HomeView: View {
    @EnvironmentObject private var water: ShowerModel
    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var laundry: LaundryModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [HomeRoute] = []
    @State private var settings = false
    @State private var onboarding: OnboardingRequest?
    @State private var scrolledPastDate = false
    @State private var panel: SettlementResult?
    @State private var startTick = 0
    @State private var successTick = 0
    @State private var errorTick = 0
    @ObservedObject private var reminders = Reminders.shared
    @ObservedObject private var resetter = AppResetter.shared
    @AppStorage("didSeeQuickSetup") private var didSeeQuickSetup = false
    /// Last laundry order whose done panel was shown (once per order).
    @AppStorage("laundryDoneShownOrder") private var laundryDoneShown = ""
    #if DEBUG
    @State private var demo: HomeData?
    @State private var laundryDemo: LaundryDemo?
    @State private var activityPreview: LaundryActivityPreview.Kind?
    @State private var widgetPreview: WidgetPreview.Page?
    /// campusdaily://demo/login-loading: the sign-in sheet's opening state, nothing loaded.
    @State private var loginDemo = false
    /// campusdaily://demo/recharge-blocked: the top-up page when its web view can't be allowed to load.
    @State private var rechargeBlockedDemo = false
    #endif

    private func openOnboarding() {
        onboarding = OnboardingRequest(step:.login)
    }

    /// Reset finished: back to the first-run guide as on a fresh install, no toast.
    private func afterReset() {
        settings = false; path = []; panel = nil
        #if DEBUG
        demo = nil; laundryDemo = nil
        #endif
        successTick += 1
        // Let the settings sheet go first, otherwise the cover is not presented.
        Task { try? await Task.sleep(for:.milliseconds(600)); openOnboarding() }
    }

    /// Home is what the user sees: nothing pushed, no sheet, cover or panel on top, app in front.
    private var homeClear: Bool {
        var clear = phase == .active && path.isEmpty && !settings && onboarding == nil && panel == nil
        #if DEBUG
        clear = clear && activityPreview == nil && widgetPreview == nil
        #endif
        return clear
    }

    private var settingsPreview: HomeData? {
        #if DEBUG
        return demo
        #else
        return nil
        #endif
    }

    private var data: HomeData {
        #if DEBUG
        if let demo { return demo }
        #endif
        return HomeData(campus:campus, water:water, laundry:laundry)
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
                    .onChange(of:data.water.showering) { old, new in
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
            await resetter.resumeIfInterrupted(campus:campus, water:water, laundry:laundry)
            if resetter.completed > 0 { return }
            if !didSeeQuickSetup && !campus.configured && !water.configured && !laundry.configured { openOnboarding() }
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
        .onChange(of:water.state.phase) { old, value in
            guard old != .done, value == .done else { return }
            presentSettled()
            Task { await campus.refresh(force:true) }
        }
        .onChange(of:water.problem) { _, problem in
            if problem, unresolvedClose { presentUnconfirmed() }
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

    #if DEBUG
    /// Also called from inside the onboarding cover: while a full-screen cover is up,
    /// the URL is delivered to the cover's hierarchy instead of the home view.
    private func handleDemo(_ url: URL) {
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
    /// campusdaily://demo/notify/<kind>
    private func notifyDemo(_ url: URL) -> String? {
        let parts = Array(url.pathComponents.dropFirst())
        guard url.scheme == "campusdaily", url.host == "demo", parts.first == "notify" else { return nil }
        return parts.count > 1 ? parts[1] : "laundry"
    }
    #endif

    // MARK: Content

    /// Negative top inset that lifts the date block into the navigation-bar row.
    private let dateLift: CGFloat = -48

    private var dateTitle: String {
        let parts = Calendar.current.dateComponents([.month,.day], from:Date())
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    @ViewBuilder private func content(_ data: HomeData) -> some View {
        let now = Date()
        VStack(alignment:.leading, spacing:0) {
            dateBlock(data).id("top")
            HomeDuo(card:data.cardFigure(now:now), power:data.powerFigure(now:now),
                    cardAction:{ data.signedIn ? path.append(.card) : openOnboarding() },
                    powerAction:{ data.signedIn ? path.append(data.powerBound ? .power : .powerSetup) : openOnboarding() })
                .padding(.top,28)
            HomeUpdateLineView(line:data.updateLine, now:now)
                .padding(.top,16).padding(.horizontal,24)
            shower(data).padding(.top,28)
            if data.laundryEnabled {
                HomeSectionHeader(text:"洗衣").padding(.top,30)
                rowLink(data.laundryBound ? .laundry : .washerSetup, label:laundryLabel(data)) { laundryRow(data) }
            }
            let recents = data.recents
            if !recents.isEmpty {
                HomeSectionHeader(text:"最近").padding(.top,30)
                recentRows(recents)
            }
        }
        .frame(maxWidth:600)
        .frame(maxWidth:.infinity)
    }

    private func dateBlock(_ data: HomeData) -> some View {
        VStack(spacing:2) {
            Text(dateTitle).scaledFont(24, .semibold, design:.serif, relativeTo:.title2).foregroundStyle(Theme.ink)
            Text([Theme.weekday(Date()), data.dorm].compactMap { $0 }.joined(separator:" · "))
                .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth:.infinity)
        // Pull the date up into the nav-bar row so 「10月28日」 is centred on the gear.
        .padding(.top,dateLift)
        .accessibilityElement(children:.combine)
        .onGeometryChange(for:Bool.self) { $0.frame(in:.global).maxY < 64 } action: { scrolledPastDate = $0 }
    }

    // MARK: Shower

    /// The shower button, or a plain row when hot water can't be used here.
    @ViewBuilder private func shower(_ data: HomeData) -> some View {
        if let kind = showerKind(data) {
            HomeShowerButton(kind:kind) { tap(kind) }
        } else {
            VStack(spacing:0) {
                Hairline()
                rowLink(.water, label:"热水，" + showerUnavailableReason(data)) {
                    StatusRow(emoji:"🚿", title:"热水", subtitle:showerUnavailableReason(data), dimmed:true)
                }
                Hairline()
            }
        }
    }

    private func showerKind(_ data: HomeData) -> HomeShowerButton.Kind? {
        guard data.signedIn else { return .signIn }
        switch data.water {
        case .unconfigured, .unavailable: return nil
        case .idle:
            if let issue = data.waterIssue { return .start(caption:issue) }
            let last = data.lastShowerMinutes.map { "上次 \($0) 分钟" + (data.lastShowerCost.map { " · " + Theme.yuan($0) } ?? "") }
            return .start(caption:last)
        case .starting: return .starting
        case .showering(let start):
            return .showering(start, caption:data.showerUnconfirmed ? ShowerCopy.writeUnconfirmed : "点一下回到洗澡页")
        case .settling: return .settling
        case .unresolved: return .review
        }
    }

    private func showerUnavailableReason(_ data: HomeData) -> String {
        switch data.water {
        case .unavailable(let reason): return reason
        default: return "先在设置里选好宿舍"
        }
    }

    // MARK: Rows

    private func rowLink(_ route: HomeRoute, label: String, @ViewBuilder row: () -> some View) -> some View {
        NavigationLink(value:route) { row() }
            .buttonStyle(RowPressStyle())
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    private func laundryTitle(_ data: HomeData) -> String {
        guard data.laundryBound, let machine = data.laundryMachine else { return "洗衣" }
        return "\(machine) 号机"
    }
    private func laundryRow(_ data: HomeData) -> some View {
        StatusRow(emoji:"🧺", title:laundryTitle(data),
                  subtitle:data.laundryBound ? data.laundry.subtitle : "扫机身上的码来绑定",
                  value:data.laundryBound ? data.laundry.value : nil)
    }
    private func laundryLabel(_ data: HomeData) -> String {
        guard data.laundryBound else { return "洗衣，扫机身上的码来绑定" }
        var subtitle = data.laundry.subtitle
        if case .running(let program, let end) = data.laundry { subtitle = program + "，" + LaundryFormat.spokenClock(end) + "洗完" }
        return ["洗衣", laundryTitle(data), data.laundry.spokenValue(), subtitle].compactMap { $0 }.joined(separator:"，")
    }

    /// The app's own showers and orders open their page; card records are plain rows.
    @ViewBuilder private func recentRows(_ items: [RecentItem]) -> some View {
        VStack(spacing:0) {
            ForEach(Array(items.enumerated()), id:\.element.id) { index, item in
                VStack(spacing:0) {
                    if index > 0 { RowSeparator() }
                    if item.source == .app {
                        NavigationLink(value:item.kind == .laundry ? HomeRoute.laundry : HomeRoute.water) { RecentRow(item:item) }
                            .buttonStyle(RowPressStyle())
                    } else {
                        RecentRow(item:item)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge:.top).combined(with:.opacity))
            }
        }
        .padding(.bottom,40)
        .animation(Theme.spring, value:items.map(\.id))
    }

    @ViewBuilder private func destination(_ route: HomeRoute) -> some View {
        switch route {
        case .power: if campus.powerConfigured { CampusRechargeView(kind:.power) } else { CampusPowerSetupView() }
        case .powerSetup: CampusPowerSetupView()
        case .card:
            #if DEBUG
            CampusRechargeView(kind:.card, demoBlocked:rechargeBlockedDemo)
            #else
            CampusRechargeView(kind:.card)
            #endif
        // Not set up yet: hot water is bound by choosing the dorm.
        case .water: if water.configured { ShowerDetail() } else { CampusOnboardingView() }
        case .laundry:
            #if DEBUG
            LaundryDetail(demo:laundryDemo)
            #else
            LaundryDetail()
            #endif
        case .washerSetup: WasherSetupView()
        }
    }

    // MARK: Toolbar


    @ViewBuilder private var gear: some View {
        let button = Button { settings = true } label: {
            Image(systemName:"gearshape").font(.system(size:17, weight:.medium)).foregroundStyle(Theme.ink)
        }.accessibilityLabel("设置")
        if #available(iOS 26, *) {
            button
        } else {
            button.frame(width:38, height:38).background(.ultraThinMaterial, in:Circle())
        }
    }

    // MARK: Actions

    /// Starting works as before (the shower runs from here, its page shows the details); every
    /// other state opens the shower page, where 结束并结算 and 核对 live.
    private func tap(_ kind: HomeShowerButton.Kind) {
        #if DEBUG
        if demo != nil { demoTap(kind); return }
        #endif
        switch kind {
        case .signIn: openOnboarding()
        case .review, .showering, .settling: path.append(.water)
        case .start:
            // An unchecked record blocks a new start: show it instead of failing.
            guard water.mayStart else { path.append(.water); return }
            startTick += 1
            Task {
                do { try await water.run(start:true) }
                catch { errorTick += 1 }
            }
        case .starting: break
        }
    }

    /// Pull to refresh: joins a running refresh. Only a pull the user made buzzes on failure.
    private func pull() async {
        await campus.refresh(force:true)
        await laundry.refresh(force:true)
        if case .failed = HomeData(campus:campus, water:water, laundry:laundry).updateLine { errorTick += 1 }
    }

    private var unresolvedClose: Bool { water.unresolvedClose }

    private func presentSettled() {
        var minutes: Int?
        if let start = water.sessionStarted, let end = water.lastEnded {
            minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        }
        successTick += 1
        panel = .settled(minutes:minutes, amount:water.lastCost)
    }

    private func presentLaundryDone(_ done: HomeData.LaundryDone?) {
        #if DEBUG
        if demo != nil { return }
        #endif
        guard let done, done.id != laundryDoneShown, panel == nil else { return }
        laundryDoneShown = done.id
        successTick += 1
        panel = .laundryDone(amount:done.amount, detail:done.detail)
    }

    private func presentUnconfirmed() {
        guard panel == nil else { return }
        errorTick += 1
        panel = .unconfirmed
    }

    #if DEBUG
    private func demoTap(_ kind: HomeShowerButton.Kind) {
        switch kind {
        case .start:
            startTick += 1
            withAnimation(Theme.spring) { demo?.water = .showering(Date()) }
        case .showering(let start, _):
            withAnimation(Theme.spring) { demo?.water = .settling(start) }
            Task {
                try? await Task.sleep(for:.seconds(1.5))
                let minutes = max(1, Int((Date().timeIntervalSince(start) / 60).rounded()))
                withAnimation(Theme.spring) {
                    demo?.water = .idle
                    demo?.lastShowerMinutes = minutes; demo?.lastShowerCost = Decimal(string:"1.32")
                    demo?.appActivities.insert(AppActivity(id:"demo-\(Date().timeIntervalSince1970)", kind:.shower(minutes:minutes),
                                                           date:Date(), amount:Money(fen:132)), at:0)
                }
                successTick += 1
                panel = .settled(minutes:minutes, amount:Decimal(string:"1.32"))
            }
        case .signIn: openOnboarding()
        case .review, .settling: path.append(.water)
        case .starting: break
        }
    }
    #endif
}

/// One presentation of the onboarding cover; a new id replaces the current one.
struct OnboardingRequest: Identifiable {
    let id = UUID()
    var step: OnboardingView.Step
    var preview: OnboardingView.Preview? = nil
}
