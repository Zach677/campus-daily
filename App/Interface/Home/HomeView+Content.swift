import SwiftUI
import Core

extension HomeView {
    // MARK: Content

    var dateTitle: String {
        let parts = Calendar.current.dateComponents([.month,.day], from:Date())
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    @ViewBuilder func content(_ data: HomeData) -> some View {
        let now = Date()
        VStack(alignment:.leading, spacing:0) {
            dateBlock(data).id("top")
            HomeDuo(card:data.cardFigure(now:now), power:data.powerFigure(now:now),
                    cardAction:{ data.signedIn ? path.append(.card) : openOnboarding() },
                    powerAction:{ data.signedIn ? path.append(data.powerBound ? .power : .powerSetup) : openOnboarding() })
                .padding(.top,28)
            HomeUpdateLineView(line:data.updateLine, now:now) { signInAgain(data) }
                .padding(.top,16).padding(.horizontal,24)
            showerSection(data).padding(.top,28)
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

    func dateBlock(_ data: HomeData) -> some View {
        VStack(spacing:2) {
            Text(dateTitle).scaledFont(24, .semibold, design:.serif, relativeTo:.title2).foregroundStyle(Theme.ink)
            Text([Theme.weekday(Date()), data.dorm].compactMap { $0 }.joined(separator:" · "))
                .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth:.infinity)
        // Pull the date up into the nav-bar row so 「10月28日」 is centred on the gear; at
        // accessibility sizes the taller date would run under the bar, so it stays below it.
        .padding(.top,typeSize.isAccessibilitySize ? 0 : dateLift)
        .accessibilityElement(children:.ignore)
        .accessibilityLabel([dateTitle, Theme.weekday(Date()), data.dorm].compactMap { $0 }.joined(separator:"，"))
        .accessibilityAddTraits(.isHeader)
        .onGeometryChange(for:Bool.self) { $0.frame(in:.global).maxY < 64 } action: { scrolledPastDate = $0 }
    }

    // MARK: Shower

    /// The shower button, or a plain row when hot water can't be used here.
    @ViewBuilder func showerSection(_ data: HomeData) -> some View {
        if let kind = showerKind(data) {
            HomeShowerButton(kind:kind) { tap(kind) }
        } else {
            VStack(spacing:0) {
                Hairline()
                rowLink(.shower, label:"热水，" + showerUnavailableReason(data)) {
                    StatusRow(emoji:"🚿", title:"热水", subtitle:showerUnavailableReason(data), dimmed:true)
                }
                Hairline()
            }
        }
    }

    /// The expired-login line: the sign-in form, or Settings › 学校账号 when the saved password
    /// is paused there.
    func signInAgain(_ data: HomeData) {
        switch HomeUpdateLine.signInTarget(data.schoolAccount) {
        case .signIn: relogin = true
        case .account: campus.accountPageRequested = true; settings = true
        }
    }

    func showerKind(_ data: HomeData) -> HomeShowerButton.Kind? {
        if data.shower.asksForSchoolSignIn(signedIn:data.signedIn) { return .signIn }
        switch data.shower {
        case .unconfigured, .unavailable: return nil
        case .idle:
            if let issue = data.showerIssue { return .start(caption:issue) }
            let last = data.lastShowerMinutes.map { "上次 \($0) 分钟" + (data.lastShowerCost.map { " · " + Theme.yuan($0) } ?? "") }
            return .start(caption:last)
        case .starting: return .starting
        case .showering(let start):
            return .showering(start, caption:data.showerUnconfirmed ? ShowerCopy.writeUnconfirmed : "点一下回到洗澡页")
        case .settling: return .settling
        case .unresolved: return .review
        }
    }

    func showerUnavailableReason(_ data: HomeData) -> String {
        switch data.shower {
        case .unavailable(let reason): return reason
        default: return "先在设置里选好宿舍"
        }
    }

    // MARK: Rows

    func rowLink(_ route: HomeRoute, label: String, @ViewBuilder row: () -> some View) -> some View {
        NavigationLink(value:route) { row() }
            .buttonStyle(RowPressStyle())
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    func laundryTitle(_ data: HomeData) -> String {
        guard data.laundryBound, let machine = data.laundryMachine else { return "洗衣" }
        return "\(machine) 号机"
    }
    func laundryRow(_ data: HomeData) -> some View {
        StatusRow(emoji:"🧺", title:laundryTitle(data),
                  subtitle:data.laundryBound ? data.laundry.subtitle : "扫机身上的码来绑定",
                  value:data.laundryBound ? data.laundry.value : nil)
    }
    func laundryLabel(_ data: HomeData) -> String {
        guard data.laundryBound else { return "洗衣，扫机身上的码来绑定" }
        var subtitle = data.laundry.subtitle
        if case .running(let program, let end) = data.laundry { subtitle = program + "，" + LaundryFormat.spokenClock(end) + "洗完" }
        return ["洗衣", laundryTitle(data), data.laundry.spokenValue(), subtitle].compactMap { $0 }.joined(separator:"，")
    }

    /// The app's own showers and orders open their page; card records are plain rows.
    @ViewBuilder func recentRows(_ items: [RecentItem]) -> some View {
        VStack(spacing:0) {
            ForEach(Array(items.enumerated()), id:\.element.id) { index, item in
                VStack(spacing:0) {
                    if index > 0 { RowSeparator() }
                    if item.source == .app {
                        NavigationLink(value:item.kind == .laundry ? HomeRoute.laundry : HomeRoute.shower) { RecentRow(item:item) }
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

    @ViewBuilder func destination(_ route: HomeRoute) -> some View {
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
        case .shower: if shower.configured { ShowerDetail() } else { CampusOnboardingView() }
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


    @ViewBuilder var gear: some View {
        let button = Button { settings = true } label: {
            Image(systemName:"gearshape").font(.system(size:17, weight:.medium)).foregroundStyle(Theme.ink)
        }.accessibilityLabel("设置")
        if #available(iOS 26, *) {
            button
        } else {
            button.frame(width:38, height:38).background(.ultraThinMaterial, in:Circle())
        }
    }
}
