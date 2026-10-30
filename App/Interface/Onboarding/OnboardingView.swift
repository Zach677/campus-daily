import SwiftUI
import Core

/// First-run guide (design §7, copy-r1 「首次引导」). Presented as a full-screen cover.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case login, dorm, washer, done }

    /// DEBUG demo values; when set, no real login or picker is opened.
    struct Preview {
        var dorm: String?
        var laundryConnected = false
        /// Same-name building choices (labels) for the dorm step's apartment picker.
        var powerChoices: [String] = []
        /// Login step: what the form starts with.
        var account = ""
        var password = ""
        var savePassword = false
        var loginState = SchoolLoginState.idle
    }

    var preview: Preview?
    var close: () -> Void

    init(start: Step = .login, preview: Preview? = nil, close: @escaping () -> Void) {
        self.preview = preview; self.close = close
        _step = State(initialValue:start)
        _account = State(initialValue:preview?.account ?? "")
        _password = State(initialValue:preview?.password ?? "")
        _savePassword = State(initialValue:preview?.savePassword ?? false)
        _loginState = State(initialValue:preview?.loginState ?? .idle)
    }

    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var laundry: LaundryModel
    @EnvironmentObject private var water: ShowerModel
    /// Binds the dorm's hot-water controller when 「就是这间」 confirms the dorm.
    @StateObject private var dormFlow = DormSetupFlow()
    @State private var bindingWater = false
    /// Automatic binding already needed the dorm screen once; the next 「就是这间」 just continues
    /// (hot water can be finished later from 设置 › 热水).
    @State private var bindTried = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var step: Step
    @State private var login = false
    @State private var ujing = false
    @State private var dormPicker = false
    @State private var washer = false
    @State private var issue: String?
    /// Same-name apartment picked on the dorm step (candidate id); confirmed by 「就是这间」.
    @State private var apartment: String?
    @State private var account: String
    @State private var password: String
    /// 「保存密码，让小组件自动刷新」, off by default.
    @State private var savePassword: Bool
    @State private var loginState: SchoolLoginState
    @FocusState private var loginFocus: SchoolLoginField?

    /// Keyboard up on the login step: mascot and body make room; the save-password note stays.
    private var keyboardUp: Bool { step == .login && loginFocus != nil }
    private var loginReady: Bool {
        !account.trimmingCharacters(in:.whitespaces).isEmpty && !password.isEmpty
    }

    private var dorm: String? { preview != nil ? preview?.dorm : Theme.dorm(campus.room) }
    private var laundryConnected: Bool { preview?.laundryConnected ?? laundry.accountConnected }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                content
                    .id(step)
                    .transition(reduceMotion ? .opacity : .push(from:.trailing))
                    .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.topLeading)
            }
            .safeAreaInset(edge:.bottom, spacing:0) {
                // Accessibility sizes: the controls scroll with the content (end of the ScrollView)
                // instead of covering half the screen.
                if !typeSize.isAccessibilitySize { bottom.background(Theme.bg) }
            }
            .toolbar(.hidden, for:.navigationBar)
            .navigationDestination(isPresented:$dormPicker) { CampusOnboardingView() }
            .navigationDestination(isPresented:$washer) { WasherSetupView() }
        }
        .tint(Theme.accentText)
        .typesettingLanguage(Theme.typesetting)
        .accountSwitchAlert { openDormPicker() }
        .sheet(isPresented:$login) {
            CampusLoginSheet { value in
                do {
                    try await campus.adoptWebState(value)
                    issue = nil; loginState = .idle; password = ""
                    // The sheet shows 「正在读电量…」 until the card and meter are read.
                    await campus.refresh(force:true)
                    campus.matchPowerAutomatically()
                    // Only from the login step: a repeated delivery must not skip the dorm step.
                    if step == .login { advance() }
                } catch { issue = "这次没登录上，再试一次。" }
            }
        }
        .sheet(isPresented:$ujing) { UjingLoginView() }
        .onChange(of:laundry.savedMachines.count) { old, new in
            if preview == nil, step == .washer, new > old { advance() }
        }
    }

    // MARK: Step content

    @ViewBuilder private var content: some View {
        ScrollView {
        VStack(alignment:.leading, spacing:0) {
            if !keyboardUp {
                icon.frame(width:76, height:76, alignment:.leading).padding(.top,typeSize.isAccessibilitySize ? 56 : 120)
            }
            // Same title style on every step, done screen included (32 bold, line height 40);
            // 28 while the login keyboard is up.
            title.scaledFont(keyboardUp ? 28 : 32, .bold, relativeTo:.largeTitle).lineSpacing(2).foregroundStyle(Theme.ink)
                .fixedSize(horizontal:false, vertical:true)
                .padding(.top,keyboardUp ? 40 : 26)
                .accessibilityAddTraits(.isHeader)
            if !keyboardUp, let body = bodyText {
                Text(body).scaledFont(17).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal:false, vertical:true)
                    .padding(.top,12)
            }
            if step == .login {
                SchoolLoginForm(account:$account, password:$password, savePassword:$savePassword,
                                state:loginState, focus:$loginFocus, submit:submitLogin)
                    .padding(.top,keyboardUp ? 20 : 28)
            }
            if step == .dorm, preview == nil, !campus.powerChoices.isEmpty || campus.powerMatchIssue != nil && !campus.powerConfigured {
                powerApartment.padding(.top,30)
            } else if step == .dorm, let choices = preview?.powerChoices, !choices.isEmpty {
                previewApartment(choices).padding(.top,30)
            }
            if let issue {
                Text(issue).scaledFont(15, relativeTo:.subheadline).foregroundStyle(Theme.redText)
                    .fixedSize(horizontal:false, vertical:true).padding(.top,16)
            }
        }
        .padding(.horizontal,28)
        .frame(maxWidth:.infinity, alignment:.leading)
        if typeSize.isAccessibilitySize { bottom.padding(.top,40) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .animation(reduceMotion ? .easeInOut(duration:0.2) : Theme.spring, value:keyboardUp)
    }

    @ViewBuilder private var icon: some View {
        switch step {
        case .login, .done: Mascot(size:76)
        case .dorm: symbol("house.fill")
        case .washer: symbol("washer.fill")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName:name).font(.system(size:60, weight:.semibold)).foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
    }

    private var title: Text {
        let accent = { (word: String) in Text(word).foregroundStyle(Theme.accentLarge) }
        let question = Text("？")   // full-width U+FF1F, per copy
        switch step {
        case .login: return Text("登录") + accent("学校账号")
        case .dorm: return Text("你住在") + accent("哪一间") + question
        // 学校洗衣机 question (laundry-optional spec §1): same page, 「洗衣机」 in the accent colour.
        case .washer: return Text("宿舍用学校的") + accent("洗衣机") + Text("吗") + question
        case .done: return Text("好了，\n") + accent("都准备好了") + Text("。")
        }
    }

    private var bodyText: String? {
        switch step {
        case .login: return "用你在学校官网登录时的账号和密码。"
        case .dorm: return dorm.map { "已经从学校账号读到：\($0)。不对就改一下。" } ?? "没读到你的宿舍，手动选一下。"
        case .washer: return SchoolLaundryPreference.Onboarding.subtitle
        case .done: return nil
        }
    }

    /// Upstream 0.8.0-beta.2: the school directory can list two buildings with the same name.
    /// Automatic meter matching then needs the student to confirm the apartment once.
    @ViewBuilder private var powerApartment: some View {
        VStack(alignment:.leading, spacing:0) {
            if !campus.powerChoices.isEmpty {
                apartmentHint
                ForEach(Array(campus.powerChoices.enumerated()), id:\.element.id) { index, candidate in
                    if index > 0 { Hairline() }
                    apartmentRow(candidate.label, selected:apartment == candidate.id) { apartment = candidate.id }
                        .disabled(campus.matchingPower)
                        .accessibilityIdentifier("powerApartment-" + candidate.id)
                }
            }
            if let issue = campus.powerMatchIssue {
                Text(issue).scaledFont(15, relativeTo:.subheadline).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal:false, vertical:true).padding(.top,8)
                Button("再找一次电表") { campus.matchPowerAutomatically() }
                    .scaledFont(17, .medium).foregroundStyle(Theme.accentText)
                    .frame(minHeight:44).disabled(campus.matchingPower)
            }
        }
    }

    private var apartmentHint: some View {
        Text("学校里有同名楼栋，选一下你住的公寓，电表就能绑上。")
            .scaledFont(15, relativeTo:.subheadline).foregroundStyle(Theme.ink2)
            .fixedSize(horizontal:false, vertical:true).padding(.bottom,6)
    }

    /// Single-select row: a tap only marks it; 「就是这间」 confirms.
    private func apartmentRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action:action) {
            HStack(spacing:14) {
                Text(label).scaledFont(17).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal:false, vertical:true)
                Spacer()
                if selected {
                    Image(systemName:"checkmark").scaledFont(17, .semibold).foregroundStyle(Theme.accentText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight:50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.replacingOccurrences(of:" · ", with:" "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var waitingForApartment: Bool { choosingApartment && apartment == nil }

    /// The dorm step lists same-name apartments; 「就是这间」 waits for a choice.
    private var choosingApartment: Bool {
        guard step == .dorm else { return false }
        if let choices = preview?.powerChoices { return !choices.isEmpty }
        return !campus.powerChoices.isEmpty
    }

    /// DEBUG demo: the same picker with sample labels; tapping does nothing.
    private func previewApartment(_ choices: [String]) -> some View {
        VStack(alignment:.leading, spacing:0) {
            apartmentHint
            ForEach(Array(choices.enumerated()), id:\.offset) { index, label in
                if index > 0 { Hairline() }
                apartmentRow(label, selected:apartment == "preview-\(index)") { apartment = "preview-\(index)" }
            }
        }
    }

    // MARK: Bottom

    private var bottom: some View {
        VStack(spacing:0) {
            if step != .done && !keyboardUp {
                HStack(spacing:7) {
                    ForEach(0..<3, id:\.self) { index in
                        Circle().fill(index == step.rawValue ? Theme.ink : Theme.ink3).frame(width:7, height:7)
                    }
                }
                .accessibilityElement().accessibilityLabel("第 \(step.rawValue + 1) 步，共 3 步")
                .padding(.bottom,18)
            }
            Button(action:primary) {
                // Same pill style on every step (18 semibold, headline-relative).
                // Waiting for an apartment choice or logging in: the home dock's disabled look
                // (「正在结算…」: fill + ink2). Login fields not filled yet: fill + ink3.
                HStack(spacing:10) {
                    if loggingIn { ProgressView().tint(Theme.ink2) }
                    Text(primaryTitle)
                }
                    .scaledFont(18, .semibold, relativeTo:.headline).foregroundStyle(primaryInk)
                    .lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.center)
                    .padding(.horizontal,20).padding(.vertical,8)
                    .frame(maxWidth:.infinity, minHeight:keyboardUp ? 52 : 60)
                    .background(primaryDimmed ? Theme.fill : Theme.pill, in:Capsule())
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(primaryDimmed || bindingWater)
            .accessibilityIdentifier("onboardingPrimary")
            .accessibilityLabel(primaryTitle)
            // Fixed slot below the pill so the pill doesn't jump between steps.
            ZStack(alignment:.top) {
                if step == .dorm && dorm != nil {
                    Button("换一间") { openDormPicker() }
                        .scaledFont(17, .medium).foregroundStyle(Theme.ink2)
                        .frame(minHeight:44).padding(.top,4)
                }
                if step == .washer {
                    VStack(spacing:0) {
                        Button(action:skipLaundry) {
                            Text(SchoolLaundryPreference.Onboarding.no)
                                .scaledFont(17, .medium, relativeTo:.body).foregroundStyle(Theme.ink)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth:.infinity, minHeight:50)
                                // Spec: 6% black light / secondary fill dark — that's Theme.fill (Theme.group is white).
                                .background(Theme.fill, in:RoundedRectangle(cornerRadius:25, style:.continuous))
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityLabel(SchoolLaundryPreference.Onboarding.no)
                        Text(SchoolLaundryPreference.Onboarding.note)
                            .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
                            .multilineTextAlignment(.center).fixedSize(horizontal:false, vertical:true)
                            .padding(.top,10)
                    }
                    .padding(.top,12)
                }
                if step == .login && !keyboardUp && loginState != .cannotDirect {
                    Button(SchoolLoginText.webLogin) { openWebLogin() }
                        .scaledFont(17, .medium).foregroundStyle(Theme.ink2)
                        .frame(minHeight:44).padding(.top,4)
                        .disabled(loggingIn)
                        .accessibilityIdentifier("webLogin")
                }
            }
            .frame(minHeight:keyboardUp ? 0 : 48, alignment:.top)
        }
        .padding(.horizontal,28)
        .padding(.bottom,keyboardUp ? 12 : 4)
        .animation(reduceMotion ? .easeInOut(duration:0.2) : Theme.spring, value:step)
    }

    private var primaryTitle: String {
        switch step {
        case .login:
            if loggingIn { return "正在登录…" }
            return loginState == .cannotDirect ? SchoolLoginText.webLogin : "登录"
        case .dorm: return bindingWater ? "正在找宿舍的水控…" : dorm != nil ? "就是这间" : "选宿舍"
        case .washer: return SchoolLaundryPreference.Onboarding.yes
        case .done: return "开始用"
        }
    }

    private var loggingIn: Bool { step == .login && loginState == .loading }

    /// Login: dimmed until both fields are filled, and while logging in. After 「没法直接登录」
    /// it is the web login and always available.
    private var primaryDimmed: Bool {
        if step == .login { return loginState != .cannotDirect && (loggingIn || !loginReady) }
        return waitingForApartment
    }

    private var primaryInk: Color {
        guard primaryDimmed else { return Theme.pillInk }
        return step == .login && !loggingIn ? Theme.ink3 : Theme.ink2
    }

    // MARK: Actions

    private func primary() {
        switch step {
        case .login:
            if loginState == .cannotDirect { openWebLogin() } else { submitLogin() }
        case .dorm:
            if choosingApartment {
                guard let apartment else { return }
                if let candidate = campus.powerChoices.first(where:{ $0.id == apartment }) { campus.choosePower(candidate) }
                bindWaterThenAdvance()
            } else if dorm != nil { bindWaterThenAdvance() } else { openDormPicker() }
        case .washer:
            // 用，接着设置: the U净 login / scan flow as before.
            if preview != nil { advance(); return }
            laundry.setSchoolEnabled(true)
            if laundryConnected { washer = true }
            else { ujing = true }
        case .done: close()
        }
    }

    /// The dorm is confirmed: bind its hot-water controller too (one room, one controller), or open
    /// the dorm screen once when that needs a choice. Never blocks the guide.
    private func bindWaterThenAdvance() {
        guard preview == nil, !bindTried, !water.configured else { advance(); return }
        guard !bindingWater else { return }
        bindingWater = true
        Task {
            let result = await dormFlow.autoBind(campus:campus, water:water)
            bindingWater = false
            switch result {
            case .bound, .unavailable: advance()
            case .needsChoice: bindTried = true; openDormPicker()
            }
        }
    }

    /// 不用: laundry hidden everywhere (changeable in 设置); first-run setup ends here.
    private func skipLaundry() {
        if preview == nil { laundry.setSchoolEnabled(false) }
        close()
    }

    /// One login with the form's account and password; never retried (failures count towards
    /// the school's lock). Wrong → password cleared and focused; anything the school put in the
    /// way → the primary button becomes the web login.
    private func submitLogin() {
        guard step == .login, loginReady, loginState != .loading else { return }
        if preview != nil { advance(); return }
        loginFocus = nil
        loginState = .loading
        let name = account.trimmingCharacters(in:.whitespaces), secret = password, save = savePassword
        Task {
            do {
                try await campus.signIn(account:name, password:secret, savePassword:save)
                password = ""
                await campus.refresh(force:true)
                campus.matchPowerAutomatically()
                loginState = .idle
                if step == .login { advance() }
            } catch SchoolLoginFailure.wrongCredentials {
                password = ""
                loginState = .wrong
                loginFocus = .password
            } catch SchoolLoginFailure.cannotLoginDirectly {
                loginState = .cannotDirect
            } catch {
                loginState = .failed(SchoolLoginText.text(error))
            }
        }
    }

    /// The school's own page (behind the loading cover); nothing to save on that path.
    private func openWebLogin() {
        if preview != nil { advance(); return }
        loginFocus = nil
        login = true
    }

    private func openDormPicker() {
        guard preview == nil else { return }
        dormPicker = true
    }

    private func advance() {
        guard let next = Step(rawValue:step.rawValue + 1) else { close(); return }
        issue = nil
        withAnimation(reduceMotion ? .easeInOut(duration:0.2) : Theme.spring) { step = next }
    }
}
