import SwiftUI
import WaterCore

/// First-run guide (design §7, copy-r1 「首次引导」). Presented as a full-screen cover.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case login, dorm, washer, done }

    /// DEBUG demo values; when set, no real login or picker is opened.
    struct Preview {
        var dorm: String?
        var laundryConnected = false
        /// Same-name building choices (labels) for the dorm step's apartment picker.
        var powerChoices: [String] = []
    }

    var preview: Preview?
    var close: () -> Void

    init(start: Step = .login, preview: Preview? = nil, close: @escaping () -> Void) {
        self.preview = preview; self.close = close
        _step = State(initialValue:start)
    }

    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var laundry: LaundryModel
    @EnvironmentObject private var water: WaterModel
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
        .sheet(isPresented:$login) {
            CampusLoginSheet { config in
                do {
                    try campus.acceptLogin(config)
                    issue = nil
                    Task { await campus.refresh(force:true) }
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
            icon.frame(width:76, height:76, alignment:.leading).padding(.top,typeSize.isAccessibilitySize ? 56 : 120)
            // Same title style on every step, done screen included (32 bold, line height 40).
            title.scaledFont(32, .bold, relativeTo:.largeTitle).lineSpacing(2).foregroundStyle(Theme.ink)
                .fixedSize(horizontal:false, vertical:true)
                .padding(.top,26)
                .accessibilityAddTraits(.isHeader)
            if let body = bodyText {
                Text(body).scaledFont(17).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal:false, vertical:true)
                    .padding(.top,12)
            }
            if step == .login {
                VStack(spacing:0) {
                    benefit("⚡", "宿舍电量"); Hairline()
                    benefit("💳", "校园卡余额"); Hairline()
                    benefit("🏠", "你的宿舍")
                }
                .padding(.top,30)
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
        case .login: return Text("你好，\n先登录") + accent("学校账号") + Text("。")
        case .dorm: return Text("你住在") + accent("哪一间") + question
        case .washer: return Text("常用的") + accent("洗衣机") + Text("是哪台") + question
        case .done: return Text("好了，\n") + accent("都准备好了") + Text("。")
        }
    }

    private var bodyText: String? {
        switch step {
        case .login: return "在学校官方网页登录，登录后这些会自己出现："
        case .dorm: return dorm.map { "已经从学校账号读到：\($0)。不对就改一下。" } ?? "没读到你的宿舍，手动选一下。"
        case .washer: return "先登录 U净，再扫机身上的码，以后一按就能付款。"
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

    private func benefit(_ emoji: String, _ text: String) -> some View {
        HStack(spacing:14) {
            Text(emoji).scaledFont(17).frame(minWidth:24).fixedSize().accessibilityHidden(true)
            Text(text).scaledFont(17).foregroundStyle(Theme.ink).fixedSize(horizontal:false, vertical:true)
            Spacer()
        }
        .frame(minHeight:50)
        .accessibilityElement(children:.combine)
    }

    // MARK: Bottom

    private var bottom: some View {
        VStack(spacing:0) {
            if step != .done {
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
                // Waiting for an apartment choice: the home dock's disabled look (「正在结算…」: fill + ink2).
                Text(primaryTitle)
                    .scaledFont(18, .semibold, relativeTo:.headline).foregroundStyle(waitingForApartment ? Theme.ink2 : Theme.pillInk)
                    .lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.center)
                    .padding(.horizontal,20).padding(.vertical,8)
                    .frame(maxWidth:.infinity, minHeight:60)
                    .background(waitingForApartment ? Theme.fill : Theme.pill, in:Capsule())
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(waitingForApartment || bindingWater)
            .accessibilityLabel(primaryTitle)
            // Fixed slot below the pill so the pill doesn't jump between steps.
            ZStack(alignment:.top) {
                if step == .dorm && dorm != nil {
                    Button("换一间") { openDormPicker() }
                        .scaledFont(17, .medium).foregroundStyle(Theme.ink2)
                        .frame(minHeight:44).padding(.top,4)
                }
                if step == .login {
                    Label("密码只交给学校，不经过我们", systemImage:"lock.fill")
                        .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal:false, vertical:true)
                        .padding(.top,12)
                }
            }
            .frame(minHeight:48, alignment:.top)
        }
        .padding(.horizontal,28)
        .padding(.bottom,4)
        .animation(reduceMotion ? .easeInOut(duration:0.2) : Theme.spring, value:step)
    }

    private var primaryTitle: String {
        switch step {
        case .login: return "去学校网页登录"
        case .dorm: return bindingWater ? "正在找宿舍的水控…" : dorm != nil ? "就是这间" : "选宿舍"
        case .washer: return laundryConnected ? "扫码绑定" : "登录 U净"
        case .done: return "开始用"
        }
    }

    // MARK: Actions

    private func primary() {
        switch step {
        case .login:
            if preview != nil { advance() } else { login = true }
        case .dorm:
            if choosingApartment {
                guard let apartment else { return }
                if let candidate = campus.powerChoices.first(where:{ $0.id == apartment }) { campus.choosePowerApartment(candidate) }
                bindWaterThenAdvance()
            } else if dorm != nil { bindWaterThenAdvance() } else { openDormPicker() }
        case .washer:
            if preview != nil { advance() }
            else if laundryConnected { washer = true }
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
