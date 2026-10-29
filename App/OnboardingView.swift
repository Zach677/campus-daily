import SwiftUI
import WaterCore

/// First-run guide (design §7, copy-r1 「首次引导」). Presented as a full-screen cover.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case login, dorm, washer, done }

    /// DEBUG demo values; when set, no real login or picker is opened.
    struct Preview {
        var dorm: String?
        var laundryConnected = false
    }

    var preview: Preview?
    var close: () -> Void

    init(start: Step = .login, preview: Preview? = nil, close: @escaping () -> Void) {
        self.preview = preview; self.close = close
        _step = State(initialValue:start)
    }

    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var laundry: LaundryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var step: Step
    @State private var login = false
    @State private var ujing = false
    @State private var dormPicker = false
    @State private var washer = false
    @State private var issue: String?

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
            .overlay(alignment:.topTrailing) {
                // The done screen is the end: no 「跳过」 there.
                if step != .done {
                    Button("跳过") { skip() }
                        .scaledFont(17, .medium).foregroundStyle(Theme.ink2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal,28).padding(.top,8).frame(minHeight:44)
                        .background(Theme.bg.opacity(typeSize.isAccessibilitySize ? 1 : 0))
                        .transition(.opacity)
                }
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
                    advance()
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
                Text(primaryTitle)
                    .scaledFont(18, .semibold, relativeTo:.headline).foregroundStyle(Theme.pillInk)
                    .lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.center)
                    .padding(.horizontal,20).padding(.vertical,8)
                    .frame(maxWidth:.infinity, minHeight:60)
                    .background(Theme.pill, in:Capsule())
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }
            .buttonStyle(PressScaleStyle())
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
        case .dorm: return dorm != nil ? "就是这间" : "选宿舍"
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
            if dorm != nil { advance() } else { openDormPicker() }
        case .washer:
            if preview != nil { advance() }
            else if laundryConnected { washer = true }
            else { ujing = true }
        case .done: close()
        }
    }

    private func openDormPicker() {
        guard preview == nil else { return }
        dormPicker = true
    }

    private func skip() {
        advance()   // on .done (last step) advance() closes
    }

    private func advance() {
        guard let next = Step(rawValue:step.rawValue + 1) else { close(); return }
        issue = nil
        withAnimation(reduceMotion ? .easeInOut(duration:0.2) : Theme.spring) { step = next }
    }
}
