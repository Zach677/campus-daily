import SwiftUI
import WebKit
import UniformTypeIdentifiers
import WaterCore

@MainActor private final class CampusBrowserState: ObservableObject {
    weak var webView: WKWebView?
    @Published var issue: String?
    @Published var reading = false
    @Published var status = "填写学校学工号和密码，登录后自动同步校园卡。"
    @Published var connecting = false
    var portalDormAddress = ""
    @Published var connected: CampusConfig?
    @Published var stalled = false
    var retry: (() -> Void)?
    func read() async throws -> CampusConfig {
        guard !reading, let webView, webView.url?.scheme == "https", webView.url?.host == "ecykt.gdbtu.edu.cn" else { throw OnboardingError.login }
        reading = true; defer { reading = false }
        // Only the official wallet session is read in the user-started sign-in flow.
        // No password fields, form hooks, injected listeners or remote uploads.
        let script = """
        (()=>{if(location.origin!=="https://ecykt.gdbtu.edu.cn")return null;const s=JSON.parse(localStorage.getItem("elecampus_state")||"{}");return JSON.stringify({logintoken:s.logintoken,loginInfo:s.loginInfo,schoolid:s.schoolid,custInfo:s.custInfo,custid:s.custid,userAgent:navigator.userAgent})})()
        """
        guard let raw = try await webView.evaluateJavaScript(script) as? String else { throw OnboardingError.login }
        var config = try OfficialCampusSession.parse(Data(raw.utf8))
        config.portalDormAddress = portalDormAddress
        return config
    }
}

private struct OfficialCampusBrowser: UIViewRepresentable {
    @ObservedObject var state: CampusBrowserState
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame:.zero,configuration:config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.isInspectable = false
        state.webView = view
        state.retry = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }; coordinator?.connect(view)
        }
        var login = URLComponents(string:"https://cas.gdbtu.edu.cn/cas/login")!
        login.queryItems = [URLQueryItem(name:"service",value:"https://portal.gdbtu.edu.cn/?path=https%3A%2F%2Fportal.gdbtu.edu.cn%2Fmain.html%23%2FStudent")]
        view.load(URLRequest(url:login.url!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let concealed = state.connecting && !state.stalled
        uiView.alpha = concealed ? 0 : 1
        uiView.isUserInteractionEnabled = !concealed
        uiView.accessibilityElementsHidden = concealed
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop(); uiView.stopLoading()
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: CampusBrowserState
        private var automation: Task<Void,Never>?
        init(_ state: CampusBrowserState) { self.state = state }
        func stop() { automation?.cancel(); automation = nil }
        func connect(_ webView: WKWebView) {
            stop(); state.stalled = false; state.issue = nil
            guard let file = Bundle.main.url(forResource:"CampusLoginAutomation",withExtension:"js"),
                  let script = try? String(contentsOf:file,encoding:.utf8) else {
                state.stalled = true; state.issue = "自动连接暂不可用，请使用备用方式"; return
            }
            automation = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                for _ in 0..<80 {
                    if Task.isCancelled || self.state.connected != nil { return }
                    do {
                        if let raw = try await webView.evaluateJavaScript(script) as? String,
                           let bytes = raw.data(using:.utf8),
                           let result = try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                           let stage = result["stage"] as? String {
                            if Task.isCancelled { return }
                            switch stage {
                            case "portal-profile":
                                if webView.url?.host == "portal.gdbtu.edu.cn", let address = result["dormAddress"] as? String,
                                   address.count <= 128, address.rangeOfCharacter(from:.controlCharacters) == nil,
                                   let bytes = try? JSONSerialization.data(withJSONObject:address,options:.fragmentsAllowed),
                                   let quoted = String(data:bytes,encoding:.utf8) {
                                    self.state.portalDormAddress = address
                                    _ = try? await webView.evaluateJavaScript("window.__campusDormAcknowledged=" + quoted)
                                }
                            case "login": self.state.status = "填写学校学工号和密码，登录后自动同步校园卡。"
                            case "waiting-profile": self.state.status = "正在读取学校登记宿舍…"
                            case "opening-wallet", "waiting-portal": self.state.status = "正在进入一卡通…"
                            case "waiting-wallet": self.state.status = "正在连接校园卡…"
                            case "wallet-ready":
                                self.state.status = "正在同步校园卡…"
                                if let config = try? await self.state.read(), !Task.isCancelled { self.state.connected = config; return }
                            case "unsupported-entry", "unsupported-origin":
                                self.state.stalled = true; self.state.status = "自动连接尚未完成，可重试或使用备用方式"
                            default: break
                            }
                        }
                    } catch { if Task.isCancelled { return } }
                    try? await Task.sleep(nanoseconds:750_000_000)
                }
                if !Task.isCancelled { self.state.stalled = true }
            }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            stop()
            if webView.url?.host == "cas.gdbtu.edu.cn" {state.portalDormAddress = ""}
            state.connecting = ["portal.gdbtu.edu.cn","ecykt.gdbtu.edu.cn"].contains(webView.url?.host ?? "")
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { connect(webView) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url,
                  url.scheme == "https", ["portal.gdbtu.edu.cn","cas.gdbtu.edu.cn","ecykt.gdbtu.edu.cn"].contains(url.host ?? ""),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
                state.issue = "请使用学校账号密码登录，当前仅支持学校官方页面"
                decisionHandler(.cancel); return
            }
            if url.host == "cas.gdbtu.edu.cn" {state.portalDormAddress = ""}
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
               url.scheme == "https", ["portal.gdbtu.edu.cn","cas.gdbtu.edu.cn","ecykt.gdbtu.edu.cn"].contains(url.host ?? "") {
                webView.load(navigationAction.request)
            }
            return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as? URLError)?.code != .cancelled { state.issue = "学校网页加载失败，请检查网络后重试" }
        }
    }
}

struct CampusLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = CampusBrowserState()
    @State private var manual = false
    let receive: (CampusConfig) -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                Text(browser.status)
                    .font(.footnote).foregroundStyle(.secondary).padding(12)
                ZStack {
                    OfficialCampusBrowser(state:browser)
                    if browser.connecting && !browser.stalled {
                        VStack(spacing:16) {ProgressView();Text("正在连接校园卡…").font(.subheadline).foregroundStyle(.secondary)}
                            .frame(maxWidth:.infinity,maxHeight:.infinity).background(NativeTheme.background)
                    }
                }
                if let issue = browser.issue { Text(issue).font(.footnote).foregroundStyle(.orange).padding(10) }
                if browser.stalled { Button("再连一次") { browser.retry?() }
                    .buttonStyle(.borderedProminent).padding().disabled(browser.reading) }
                if browser.stalled || manual {Button("备用方式") { manual.toggle() }.font(.footnote).padding(.vertical,4)}
                if manual { Button {
                    Task { do { let config = try await browser.read(); receive(config); dismiss() }
                        catch { browser.issue = (error as? LocalizedError)?.errorDescription ?? "登录信息读取失败，请重试" } }
                } label: { Text(browser.reading ? "正在读取…" : "从当前一卡通页面读取").frame(maxWidth:.infinity,minHeight:44) }
                    .buttonStyle(.borderedProminent).padding().disabled(browser.reading).accessibilityIdentifier("readCampusLogin")
                }
            }.background(NativeTheme.background).navigationTitle("连接校园卡").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
                .onReceive(browser.$connected.compactMap { $0 }) { config in receive(config); dismiss() }
        }
    }
}

struct CampusOnboardingView: View {
    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var water: WaterModel
    @State private var login = false
    @State private var offeredLogin = false
    @State private var draft: CampusConfig?
    @State private var identity: (student: String, school: String)?
    @State private var options: [[DormOption]] = [[],[],[],[]]
    @State private var selected: [DormOption] = []
    @State private var machines: [DormMachine] = []
    @State private var serviceEnabled: Bool?
    @State private var autoMatched = false
    @State private var importingPlatform = false
    @State private var busy = false
    @State private var saved = false
    @State private var issue: String?
    private let provider = DormOnboardingProvider()
    private let levels = ["校区","楼栋","楼层","宿舍"]
    var body: some View {
        Form {
            if water.onboardingProfile == nil {
                Section("热水") {
                    Text("登录学校账号后会自动读到宿舍和水控，不用导入文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if draft != nil {Button("再连一次") {Task {await prepare()}}.disabled(busy || !water.mayImport || campus.loading)}
                    DisclosureGroup("导入热水配置") {
                        Button("选择配置文件") {importingPlatform = true}
                            .disabled(busy || !water.mayImport).accessibilityIdentifier("importWaterPlatform")
                        Text("平时用不到，只在从旧版迁移或排查问题时用。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let address = draft?.portalDormAddress, !address.isEmpty {
                Section("学校登记宿舍") {
                    Text(address).font(.subheadline)
                    if autoMatched {Text(campus.powerConfigured ? "宿舍和电表都找到了。" : "找到你的宿舍了，核对一下再保存。")
                        .font(.footnote).foregroundStyle(.secondary)}
                }
            }
            AutomaticPowerSection()
            Section {
                Button { login = true } label: { Label(draft == nil ? "登录并连接校园卡" : "重新登录",systemImage:"person.crop.circle") }
                    .accessibilityIdentifier("officialCampusLogin").disabled(busy)
                if draft != nil {
                    Label("已读取学校账号",systemImage:"checkmark.circle").foregroundStyle(.green)
                    Button(identity == nil ? "继续读取宿舍" : "重新读取宿舍") { Task { await prepare() } }
                        .disabled(busy || !water.mayImport || campus.loading).accessibilityIdentifier("prepareDormOnboarding")
                }
            } header: { Text("学校账号") } footer: { Text("密码只交给学校，不经过我们。登录后会读到你的校园卡和宿舍。") }
            if serviceEnabled == false {
                Section {Text("宿舍已经设好了，热水开放后就能用。")
                    .font(.footnote).foregroundStyle(.orange)}
            }
            if identity != nil {
                Section("热水宿舍") {
                    if autoMatched, let address = draft.flatMap({PortalDormAddress.parse($0.portalDormAddress)}) {
                        LabeledContent("已匹配宿舍",value:Theme.dorm(address.shortRoom) ?? address.shortRoom)
                        DisclosureGroup("更换宿舍") {dormMenus}
                    } else {dormMenus}
                    ForEach(machines) { machine in
                        VStack(alignment:.leading,spacing:10) {
                            Label(machine.name,systemImage:"drop").font(.headline)
                            Text("水控编号 " + machine.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("核对是你的宿舍后保存。保存不会出水，也不会更改学校绑定。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("就是这间") {Task {await save(machine)}}
                                .buttonStyle(.borderedProminent).frame(minHeight:44)
                                .disabled(busy || !water.mayImport || campus.loading || saved).accessibilityIdentifier("saveDormBinding")
                        }.padding(.vertical,6)
                    }
                }
            }
            if busy { Section { HStack { ProgressView(); Text("正在读取学校信息…") } } }
            if let issue { Section { Text(issue).foregroundStyle(.orange).font(.footnote) } }
            if saved {
                Section {
                    Label("宿舍已保存",systemImage:"checkmark.circle.fill").foregroundStyle(.green)
                    NavigationLink("前往选择附近水控") { WaterDetail() }
                    Text("靠近宿舍水控，在“连接检查”中选择并核对设备。也可以稍后开始洗澡时选择。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("学校账号与宿舍").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented:$importingPlatform,allowedContentTypes:[.json,.data]) {result in
                do {
                    try water.importPlatform(result.get()); issue = nil
                    if draft != nil {Task {await prepare()}}
                    else {login = true}
                } catch {issue = "没导入成功。选热水平台给的配置文件，别用别人的完整配置。"}
            }
            .sheet(isPresented:$login) { CampusLoginSheet { value in
                draft = value; identity = nil; options = [[],[],[],[]]; selected = []; machines = []; saved = false; issue = nil
                autoMatched = false;serviceEnabled = nil
                Task { await prepare() }
            } }
            .task {
                if draft == nil, let existing = campus.onboardingLogin {
                    draft = existing
                    if !water.configured { await prepare() }
                } else if draft == nil && !offeredLogin {
                    offeredLogin = true
                    login = true
                }
            }
            .scrollContentBackground(.hidden).background(NothingTheme.background).tint(NativeTheme.tint)
    }
    private var dormMenus: some View {
        ForEach(0..<4,id:\.self) {level in
            if !options[level].isEmpty {
                Menu {
                    ForEach(options[level]) {option in
                        Button(option.name) {Task {await choose(option,at:level)}}
                    }
                } label: {LabeledContent(levels[level],value:selected.count > level ? selected[level].name : "请选择")}
                    .disabled(busy).accessibilityIdentifier("dormLevel\(level)")
            }
        }
    }
    private func prepare() async {
        guard !busy, let draft, water.mayImport else { return }
        do { try campus.acceptLogin(draft) }
        catch { issue = "学校账号暂未保存，请稍后重试"; return }
        // The card is ready independently of hot-water platform provisioning
        // or whether the user finishes choosing a dorm in this visit.
        Task { await campus.refresh(force:true) }
        busy = true; issue = nil; saved = false;serviceEnabled = nil
        defer { busy = false }
        do {
            try water.scopeAccess(to:draft)
            let seed: WaterPlatformProfile
            guard let existing = water.onboardingProfile, existing.access == nil else {throw OnboardingError.platform}
            seed = existing
            let who = try await provider.identity(campus:draft,seed:seed)
            try water.confirmDirectIdentity(student:who.student,school:who.school,profile:seed)
            let values = try await provider.options(parent:who.school,seed:seed)
            identity = who; options = [values,[],[],[]]; selected = []; machines = [];autoMatched = false
            busy = false
            if let address = PortalDormAddress.parse(draft.portalDormAddress) {
                for level in 0..<4 {
                    if selected.count > level {continue}
                    let matches = options[level].filter {address.matches($0.name,level:level)}
                    guard matches.count == 1, let option = matches.first else {break}
                    await choose(option,at:level)
                }
                if selected.count == 4 && selected.enumerated().allSatisfy({address.matches($0.element.name,level:$0.offset)}) {
                    autoMatched = true
                }
            } else if values.count == 1, let only = values.first { await choose(only,at:0) }
        } catch { issue = (error as? LocalizedError)?.errorDescription ?? "暂时无法读取宿舍，请稍后重试" }
    }
    private func choose(_ option: DormOption, at level: Int) async {
        guard !busy, selected.count >= level, let seed = water.onboardingProfile, let identity else { return }
        autoMatched = false
        selected = Array(selected.prefix(level)) + [option]
        for index in (level+1)..<4 { options[index] = [] }
        machines = []; saved = false; issue = nil; busy = true
        defer { busy = false }
        do {
            if level == 3 { machines = try await provider.machines(room:option.id,school:identity.school,seed:seed)
                if machines.isEmpty { issue = "这间宿舍没有找到水控，请核对宿舍" }
            } else {
                options[level+1] = try await provider.options(parent:option.id,rooms:level == 2,seed:seed)
                busy = false
                if options[level+1].count == 1, let only = options[level+1].first { await choose(only,at:level+1) }
            }
        } catch { issue = (error as? LocalizedError)?.errorDescription ?? "宿舍列表读取失败，请重新选择" }
    }
    private func save(_ machine: DormMachine) async {
        guard selected.count == 4, let seed = water.onboardingProfile, let identity, water.mayImport, !campus.loading else { return }
        busy = true;defer {busy = false}
        // Existing model's BLE profile is reused; hardware identity is still checked before every authorization.
        do {
            guard seed.access == nil else {throw OnboardingError.platform}
            let value = try seed.configuration(student:identity.student,school:identity.school,machine:machine.id)
            let old = water.onboardingSeed
            let reviewRequired = water.residenceReviewRequired
            try WaterDormSaveTransaction.perform(
                saveWater:{try water.acceptDorm(value)},
                saveCampus:{try campus.saveDormName(selected[1].name + selected[3].name,selection:selected.map(\.name))},
                rollbackWater:{try water.restoreDorm(old,reviewRequired:reviewRequired)})
            saved = true; issue = nil
            Task { await campus.refresh(force:true) }
        } catch { issue = (error as? LocalizedError)?.errorDescription ?? "保存失败，请重试" }
    }
}
