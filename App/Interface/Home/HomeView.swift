import SwiftUI
import UserNotifications
import Core

enum HomeRoute: Hashable { case power, powerSetup, card, water, laundry, washerSetup }

/// Single home screen: date · hero sentence · status rows · 最近 · bottom dock.
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
                    .safeAreaInset(edge:.bottom, spacing:0) { dock(data) }
                    .refreshable { await campus.refresh(force:true); await laundry.refresh(force:true) }
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
    /// Subtitle bottom → hero glyph top ≈ 28pt (text line boxes add the rest).
    private let heroGap: CGFloat = 16

    private var dateTitle: String {
        let parts = Calendar.current.dateComponents([.month,.day], from:Date())
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    @ViewBuilder private func content(_ data: HomeData) -> some View {
        VStack(alignment:.leading, spacing:0) {
            dateBlock(data).id("top")
            hero(data)
                .padding(.top,heroGap).padding(.horizontal,24).padding(.bottom,6)
            if !data.signedIn {
                HomeSectionHeader(text:"登录后会出现").padding(.top,24)
                signedOutRows(data)
            } else {
                statusRows(data).padding(.top,24)
                if !data.recents.isEmpty {
                    HomeSectionHeader(text:"最近").padding(.top,30)
                    recentRows(data)
                }
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

    @ViewBuilder private func hero(_ data: HomeData) -> some View {
        ZStack(alignment:.topLeading) {
            if let start = data.water.showering, data.signedIn {
                ShowerHero(start:start, dorm:data.dorm, unconfirmed:data.showerUnconfirmed)
                    .transition(heroTransition)
            } else {
                VStack(alignment:.leading, spacing:14) {
                    if !data.signedIn { Mascot(size:52) }
                    sentence(data)
                }
                .frame(maxWidth:.infinity, alignment:.leading)
                .transition(heroTransition)
            }
        }
        .animation(Theme.spring, value:data.water.showering)
    }

    /// Reduce Motion: plain cross-fade, no offset.
    private var heroTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with:.offset(y:6))
    }

    private func sentence(_ data: HomeData) -> some View {
        var text = AttributedString()
        for segment in data.hero {
            var run = AttributedString(segment.text)
            run.foregroundColor = segment.color ?? Theme.ink
            text += run
        }
        return Text(text)
            .scaledFont(30, .bold, relativeTo:.title)
            .tracking(-0.6).lineSpacing(5)
            .fixedSize(horizontal:false, vertical:true)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(Theme.spring, value:data.heroLabel)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(data.heroLabel)
            .accessibilityHint(data.powerLow ? "电量不足" : "")
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Rows

    @ViewBuilder private func statusRows(_ data: HomeData) -> some View {
        VStack(spacing:0) {
            rowLink(.power, label:powerLabel(data)) { powerRow(data) }
            RowSeparator()
            rowLink(.card, label:cardLabel(data)) { cardRow(data) }
            RowSeparator()
            rowLink(.water, label:waterLabel(data)) { waterRow(data) }
            if data.laundryEnabled {
                RowSeparator()
                rowLink(data.laundryBound ? .laundry : .washerSetup, label:laundryLabel(data)) { laundryRow(data) }
            }
        }
    }

    private func signedOutRows(_ data: HomeData) -> some View {
        let rows = [("⚡","电量"),("💳","校园卡"),("🚿","热水")] + (data.laundryEnabled ? [("🧺","洗衣")] : [])
        return VStack(spacing:0) {
            ForEach(Array(rows.enumerated()), id:\.offset) { index, row in
                if index > 0 { RowSeparator() }
                StatusRow(emoji:row.0, title:row.1, subtitle:"登录后显示", value:.dash, dimmed:true)
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel(row.1 + "，登录后显示")
            }
        }
    }

    private func rowLink(_ route: HomeRoute, label: String, @ViewBuilder row: () -> some View) -> some View {
        NavigationLink(value:route) { row() }
            .buttonStyle(RowPressStyle())
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    private func powerRow(_ data: HomeData) -> some View {
        let value: RowValue = data.remainingKWh.map { .number(Theme.kwh($0), unit:"度", low:data.powerLow) } ?? .dash
        return StatusRow(emoji:"⚡", title:"电量", subtitle:data.powerIssue ?? data.powerSubtitle, subtitleLow:data.powerIssue == nil && data.powerLow, value:value)
            .animation(Theme.spring, value:data.remainingKWh)
    }
    private func powerLabel(_ data: HomeData) -> String {
        guard let kwh = data.remainingKWh else { return ["电量，未读取", data.powerIssue].compactMap { $0 }.joined(separator:"，") }
        return ["电量", Theme.kwh(kwh) + " 度", data.powerIssue ?? (data.powerSubtitle.isEmpty ? nil : data.powerSubtitle)].compactMap { $0 }.joined(separator:"，")
    }

    private func cardRow(_ data: HomeData) -> some View {
        let value: RowValue = data.balance.map { .number(Theme.yuan($0), unit:nil, low:data.cardLow) } ?? .dash
        return StatusRow(emoji:"💳", title:"校园卡", subtitle:data.campusIssue ?? data.balanceUpdated.map { Theme.updated($0) } ?? "", value:value)
            .animation(Theme.spring, value:data.balance)
    }
    private func cardLabel(_ data: HomeData) -> String {
        guard let balance = data.balance else { return ["校园卡余额，未读取", data.campusIssue].compactMap { $0 }.joined(separator:"，") }
        return "校园卡余额，" + Theme.yuan(balance).dropFirst() + " 元" + (data.campusIssue.map { "，" + $0 } ?? "")
    }

    private func waterSubtitle(_ data: HomeData) -> String {
        switch data.water {
        case .unconfigured: return "先在设置里选好宿舍"
        case .unavailable(let reason): return reason
        case .showering, .settling: return "正在洗澡"
        case .unresolved(let label): return label
        case .idle, .starting:
            if let issue = data.waterIssue { return issue }
            guard let minutes = data.lastShowerMinutes else { return "" }
            return "上次 \(minutes) 分钟" + (data.lastShowerCost.map { " · " + Theme.yuan($0) } ?? "")
        }
    }
    private func waterValue(_ data: HomeData) -> RowValue? {
        switch data.water {
        case .unconfigured, .unavailable: return nil
        case .showering, .settling: return .word("使用中")
        case .unresolved: return .accentWord("待核对")
        case .idle, .starting: return .word("可以洗")
        }
    }
    private func waterRow(_ data: HomeData) -> some View {
        StatusRow(emoji:"🚿", title:"热水", subtitle:waterSubtitle(data), value:waterValue(data), dimmed:isUnavailable(data.water))
    }
    /// Hot water can't be used (not imported, no platform, school not open): ink2 title, no value, no pill.
    private func isUnavailable(_ water: HomeData.Shower) -> Bool {
        switch water {
        case .unconfigured, .unavailable: return true
        default: return false
        }
    }
    private func waterLabel(_ data: HomeData) -> String {
        var parts = ["热水"]
        switch waterValue(data) {
        case .word(let word)?, .accentWord(let word)?: parts.append(word)
        default: break
        }
        let subtitle = waterSubtitle(data)
        if !subtitle.isEmpty { parts.append(subtitle.replacingOccurrences(of:" · ¥", with:" ").appending(data.lastShowerCost != nil && subtitle.hasPrefix("上次") ? " 元" : "")) }
        return parts.joined(separator:"，")
    }

    private func laundryTitle(_ data: HomeData) -> String {
        guard data.laundryBound, let machine = data.laundryMachine else { return "洗衣" }
        return "洗衣 · \(machine) 号机"
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
        return [laundryTitle(data), data.laundry.spokenValue(), subtitle].compactMap { $0 }.joined(separator:"，")
    }

    @ViewBuilder private func recentRows(_ data: HomeData) -> some View {
        VStack(spacing:0) {
            ForEach(Array(data.recents.enumerated()), id:\.element.id) { index, item in
                VStack(spacing:0) {
                    if index > 0 { RowSeparator() }
                    NavigationLink(value:item.emoji == "🧺" ? HomeRoute.laundry : HomeRoute.water) { RecentRow(item:item) }
                        .buttonStyle(RowPressStyle())
                }
                .transition(reduceMotion ? .opacity : .move(edge:.top).combined(with:.opacity))
            }
        }
        .animation(Theme.spring, value:data.recents.map(\.id))
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

    // MARK: Toolbar & dock

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

    private enum PillKind: Equatable { case start, starting, finish, settling, signIn, review, laundryReview }

    private func pillKind(_ data: HomeData) -> PillKind? {
        guard data.signedIn else { return .signIn }
        let water = waterPillKind(data)
        // Laundry 待核对 takes the dock only when the shower is idle (shower 待核对 wins).
        if data.laundryEnabled, data.laundryBound, data.laundry == .unresolved, water == nil || water == .start { return .laundryReview }
        return water
    }

    private func waterPillKind(_ data: HomeData) -> PillKind? {
        switch data.water {
        case .unconfigured, .unavailable: return nil
        case .showering: return .finish
        case .settling: return .settling
        case .starting: return .starting
        case .unresolved: return .review
        case .idle: return .start
        }
    }

    private func dock(_ data: HomeData) -> some View {
        let kind = pillKind(data)
        // The scan button only leads to the washer: gone with 学校洗衣机 off (the pill fills the row).
        let showsRound = data.laundryEnabled && data.signedIn && kind != .finish && kind != .settling
        return HStack(spacing:12) {
            if let kind { pill(kind, data:data) }
            else { Spacer(minLength:0) }
            if showsRound {
                Button { path.append(.washerSetup) } label: {
                    Image(systemName:"qrcode.viewfinder").font(.system(size:22)).foregroundStyle(Theme.ink)
                        .frame(width:60, height:60)
                        .background(Theme.group, in:Circle())
                        .overlay(Circle().strokeBorder(Theme.separator, lineWidth:0.5))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("扫码")
                .transition(reduceMotion ? .opacity : .scale.combined(with:.opacity))
            }
        }
        .padding(.top,18).padding(.horizontal,20)
        .frame(maxWidth:640)
        .frame(maxWidth:.infinity)
        .background {
            ZStack { Rectangle().fill(.ultraThinMaterial); Theme.bg.opacity(0.85) }.ignoresSafeArea(edges:.bottom)
        }
        .animation(Theme.spring, value:kind)
    }

    private func pill(_ kind: PillKind, data: HomeData) -> some View {
        let background: Color, foreground: Color, title: String
        switch kind {
        case .start: background = Theme.pill; foreground = Theme.pillInk; title = "开始洗澡"
        case .starting: background = Theme.fill; foreground = Theme.ink2; title = "开始洗澡"
        case .finish: background = Theme.accent; foreground = Theme.accentInk; title = "结束并结算"
        case .settling: background = Theme.fill; foreground = Theme.ink2; title = "正在结算…"
        case .signIn: background = Theme.pill; foreground = Theme.pillInk; title = "登录学校账号"
        case .review: background = Theme.pill; foreground = Theme.pillInk; title = "核对上次结算"
        case .laundryReview: background = Theme.pill; foreground = Theme.pillInk; title = "核对洗衣订单"
        }
        return Button { tap(kind) } label: {
            HStack(spacing:8) {
                if kind == .starting || kind == .settling { ProgressView().tint(Theme.ink2) }
                if kind == .start { Image(systemName:"drop.fill").font(.system(size:17)) }
                Text(title).scaledFont(18, .semibold, relativeTo:.headline)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }
            // One line at any size: cap the label; the pill grows with it (minHeight, not a fixed height).
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .foregroundStyle(foreground)
            .padding(.horizontal,16)
            .frame(maxWidth:.infinity).frame(minHeight:60)
            .background(background, in:Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(kind == .starting || kind == .settling)
        .accessibilityLabel(title)
    }

    // MARK: Actions

    private func tap(_ kind: PillKind) {
        #if DEBUG
        if demo != nil { demoTap(kind); return }
        #endif
        switch kind {
        case .signIn: openOnboarding()
        case .review: path.append(.water)
        case .laundryReview: path.append(.laundry)
        case .start:
            // An unchecked record blocks a new start: show it instead of failing.
            guard water.mayStart else { path.append(.water); return }
            startTick += 1
            Task {
                do { try await water.run(start:true) }
                catch { errorTick += 1 }
            }
        case .finish:
            Task {
                do { try await water.run(start:false) }
                catch { if unresolvedClose { presentUnconfirmed() } else { errorTick += 1 } }
            }
        case .starting, .settling: break
        }
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
    private func demoTap(_ kind: PillKind) {
        switch kind {
        case .start:
            startTick += 1
            withAnimation(Theme.spring) { demo?.water = .showering(Date()) }
        case .finish:
            guard case .showering(let start)? = demo?.water else { return }
            withAnimation(Theme.spring) { demo?.water = .settling(start) }
            Task {
                try? await Task.sleep(for:.seconds(1.5))
                let minutes = max(1, Int((Date().timeIntervalSince(start) / 60).rounded()))
                let amount = Decimal(string:"1.32")
                withAnimation(Theme.spring) {
                    demo?.water = .idle
                    demo?.lastShowerMinutes = minutes; demo?.lastShowerCost = amount
                    demo?.recents.insert(.init(id:"demo-\(Date().timeIntervalSince1970)", emoji:"🚿", title:"热水 · \(minutes) 分钟",
                                               date:Date(), detail:nil, amount:amount), at:0)
                    demo?.recents = Array(demo?.recents.prefix(4) ?? [])
                }
                successTick += 1
                panel = .settled(minutes:minutes, amount:amount)
            }
        case .signIn: openOnboarding()
        case .review: path.append(.water)
        case .laundryReview:
            laundryDemo = LaundryDemo.make(.check)
            path.append(.laundry)
        case .starting, .settling: break
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
