import SwiftUI
import WebKit
import UniformTypeIdentifiers
import DailyCore
import DailyHTTP
import HotWaterClient

/// What the official pages produced: the ecykt `elecampus_state` (selected fields) and the
/// portal's dorm address line. Handed to `CampusModel.adoptWebState`.
struct CampusWebLogin {
    var state: Data
    var dormAddress: String
}

@MainActor private final class CampusBrowserState: ObservableObject {
    weak var webView: WKWebView?
    @Published var issue: String?
    @Published var reading = false
    @Published var status = "填写学校学工号和密码，登录后自动同步校园卡。"
    /// Hidden-page phases and their stage line (DailyCore, unit-tested).
    @Published var progress = CampusLoginProgress()
    @Published var now = Date()
    var portalDormAddress = ""
    @Published var connected: CampusWebLogin?
    @Published var stalled = false
    var retry: (() -> Void)?
    func read() async throws -> CampusWebLogin {
        guard !reading, let webView, webView.url?.scheme == "https", webView.url?.host == "ecykt.gdbtu.edu.cn" else { throw ServiceError.malformed(.ecykt, "page") }
        reading = true; defer { reading = false }
        // Only the official wallet session is read in the user-started sign-in flow.
        // No password fields, form hooks, injected listeners or remote uploads.
        let script = """
        (()=>{if(location.origin!=="https://ecykt.gdbtu.edu.cn")return null;const s=JSON.parse(localStorage.getItem("elecampus_state")||"{}");return JSON.stringify({logintoken:s.logintoken,loginInfo:s.loginInfo,schoolid:s.schoolid,custInfo:s.custInfo,custid:s.custid,userAgent:navigator.userAgent})})()
        """
        guard let raw = try await webView.evaluateJavaScript(script) as? String, raw.utf8.count <= 65536 else {
            throw ServiceError.malformed(.ecykt, "elecampus_state")
        }
        return CampusWebLogin(state:Data(raw.utf8), dormAddress:portalDormAddress)
    }
}

private struct OfficialCampusBrowser: UIViewRepresentable {
    @ObservedObject var state: CampusBrowserState
    /// DEBUG demo: nothing is loaded (loading-state screenshots).
    var loads = true
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
        if loads { view.load(URLRequest(url:login.url!)) }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let concealed = state.progress.concealed && !state.stalled
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
                state.stalled = true; state.issue = "自动连接暂时用不了，换备用方式登录。"; return
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
                            self.state.progress.probed(automation:stage, formVisible:result["form"] as? Bool == true)
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
                            case "wallet-ready":
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
            state.progress.pageStarted(host:webView.url?.host)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { connect(webView) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url,
                  url.scheme == "https", ["portal.gdbtu.edu.cn","cas.gdbtu.edu.cn","ecykt.gdbtu.edu.cn"].contains(url.host ?? ""),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
                state.issue = "用学校账号密码登录，目前只支持学校官方页面。"
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
            if (error as? URLError)?.code != .cancelled { state.issue = "学校网页没打开，检查一下网络再试。"; state.progress.failed() }
        }
    }
}

struct CampusLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = CampusBrowserState()
    @State private var manual = false
    /// The automatic read and the manual 读取 button can both produce a login: deliver it once.
    @State private var delivered = false
    /// Adopts the login and reads the card and meter; the sheet shows 「正在读电量…」 meanwhile and
    /// closes when it returns (or after `readLimit`, leaving the read running).
    let receive: (CampusWebLogin) async -> Void
    /// DEBUG demo: keep the opening state (no page is loaded).
    var holdOpening = false
    private static let readLimit: Duration = .seconds(20)
    private func deliver(_ config: CampusWebLogin) {
        guard !delivered else { return }
        delivered = true
        browser.progress.delivered()
        // Not cancelled by the time limit: a slow read finishes after the sheet has closed.
        Task { await receive(config); close() }
        Task { try? await Task.sleep(for:Self.readLimit); close() }
    }
    @State private var closed = false
    private func close() {
        guard !closed else { return }
        closed = true; dismiss()
    }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                if !hidden {
                    Text(browser.status)
                        .font(.footnote).foregroundStyle(.secondary).padding(12)
                }
                ZStack {
                    OfficialCampusBrowser(state:browser, loads:!holdOpening)
                    if hidden {
                        VStack(spacing:16) {
                            ProgressView()
                            VStack(spacing:6) {
                                Text(browser.progress.text ?? CampusLoginProgress.openingText)
                                    .font(.subheadline).foregroundStyle(Theme.ink)
                                    .accessibilityIdentifier("campusLoginStage")
                                // Space kept from the start so the spinner doesn't move when it appears.
                                let slow = browser.progress.slowNote(now:browser.now)
                                Text(slow ?? CampusLoginProgress.slowText).font(.footnote).foregroundStyle(.secondary)
                                    .opacity(slow == nil ? 0 : 1)
                                    .accessibilityHidden(slow == nil)
                            }
                            .multilineTextAlignment(.center)
                            .animation(.easeInOut(duration:0.2), value:browser.progress.slowNote(now:browser.now))
                        }
                        .padding(.horizontal,32).padding(.bottom,60)
                        .frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.bg)
                        .accessibilityElement(children:.combine)
                    }
                }
                if let issue = browser.issue { Text(issue).font(.footnote).foregroundStyle(.orange).padding(10) }
                if browser.stalled { Button("再连一次") { browser.retry?() }
                    .buttonStyle(.borderedProminent).padding().disabled(browser.reading) }
                if browser.stalled || manual {Button("备用方式") { manual.toggle() }.font(.footnote).padding(.vertical,4)}
                if manual { Button {
                    Task { do { let config = try await browser.read(); deliver(config) }
                        catch { browser.issue = "登录信息没读到，再试一次。" } }
                } label: { Text(browser.reading ? "正在读取…" : "从当前页面读取").frame(maxWidth:.infinity,minHeight:44) }
                    .buttonStyle(.borderedProminent).padding().disabled(browser.reading || delivered).accessibilityIdentifier("readCampusLogin")
                }
            }.background(Theme.bg).navigationTitle("登录学校账号").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } } }
                .onReceive(browser.$connected.compactMap { $0 }) { config in deliver(config) }
                .task {
                    // One clock for the 8 s slow line and the opening fallback.
                    while !Task.isCancelled {
                        try? await Task.sleep(for:.seconds(1))
                        browser.now = Date()
                        if !holdOpening { browser.progress.tick(now:browser.now) }
                    }
                }
        }
    }
    /// Spinner instead of the page (a stalled automation shows the page and its buttons).
    private var hidden: Bool { browser.progress.concealed && !browser.stalled }
}

struct CampusOnboardingView: View {
    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var water: WaterModel
    @State private var login = false
    @State private var offeredLogin = false
    @State private var importingPlatform = false
    /// Dorm → hot-water controller binding; shared with the first-run guide's dorm step.
    @StateObject private var flow = DormSetupFlow()
    private let levels = ["校区","楼栋","楼层","宿舍"]
    var body: some View {
        Form {
            if water.profile == nil && water.binding?.access == nil && flow.identity == nil {
                Section("热水") {
                    Text("登录学校账号后会自动读到宿舍和水控，不用导入文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if campus.configured {Button("再连一次") {Task {await flow.prepare(campus:campus,water:water)}}.disabled(flow.busy || !water.mayImport || campus.loading)}
                    DisclosureGroup("导入热水配置") {
                        Button("选择配置文件") {importingPlatform = true}
                            .disabled(flow.busy || !water.mayImport).accessibilityIdentifier("importWaterPlatform")
                        Text("平时用不到，只在从旧版迁移或排查问题时用。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let address = campus.profile?.residence?.raw, !address.isEmpty {
                Section("学校登记宿舍") {
                    Text(address).font(.subheadline)
                    if flow.autoMatched {Text(campus.powerConfigured ? "宿舍和电表都找到了。" : "找到你的宿舍了，核对一下再保存。")
                        .font(.footnote).foregroundStyle(.secondary)}
                }
            }
            AutomaticPowerSection()
            Section {
                Button { login = true } label: { Label(campus.configured ? "重新登录" : "登录并连接校园卡",systemImage:"person.crop.circle") }
                    .accessibilityIdentifier("officialCampusLogin").disabled(flow.busy)
                if campus.configured {
                    Label("已读取学校账号",systemImage:"checkmark.circle").foregroundStyle(.green)
                    Button(flow.identity == nil ? "继续读取宿舍" : "重新读取宿舍") { Task { await flow.prepare(campus:campus,water:water) } }
                        .disabled(flow.busy || !water.mayImport || campus.loading).accessibilityIdentifier("prepareDormOnboarding")
                }
            } header: { Text("学校账号") } footer: { Text("密码只交给学校，不经过我们。登录后会读到你的校园卡和宿舍。") }
            if flow.serviceEnabled == false {
                Section {Text("宿舍已经设好了，热水开放后就能用。")
                    .font(.footnote).foregroundStyle(.orange)}
            }
            if flow.identity != nil {
                Section("热水宿舍") {
                    if flow.autoMatched, let address = campus.address {
                        LabeledContent("已匹配宿舍",value:Theme.dorm(address.roomLabel) ?? address.roomLabel)
                        DisclosureGroup("更换宿舍") {dormMenus}
                    } else {dormMenus}
                    ForEach(flow.machines, id:\.machineId) { machine in
                        VStack(alignment:.leading,spacing:10) {
                            Label(machine.name,systemImage:"drop").font(.headline)
                            Text("水控编号 " + machine.machineId).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("核对是你的宿舍后保存。保存不会出水，也不会更改学校绑定。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("就是这间") {Task {await flow.save(machine,water:water)}}
                                .buttonStyle(.borderedProminent).frame(minHeight:44)
                                .disabled(flow.busy || !water.mayImport || campus.loading || flow.saved).accessibilityIdentifier("saveDormBinding")
                        }.padding(.vertical,6)
                    }
                }
            }
            if flow.busy { Section { HStack { ProgressView(); Text("正在读取学校信息…") } } }
            if let issue = flow.issue { Section { Text(issue).foregroundStyle(.orange).font(.footnote) } }
            if flow.saved {
                Section {
                    Label("宿舍已保存",systemImage:"checkmark.circle.fill").foregroundStyle(.green)
                    NavigationLink("前往连接检查") { AdvancedSettingsView() }
                    Text("靠近宿舍水控，在“连接检查”里核对水控。也可以直接开始洗澡，校日常会先核对水控编号。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("学校账号与宿舍").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented:$importingPlatform,allowedContentTypes:[.json,.data]) {result in
                do {
                    try water.importConfig(result.get()); flow.issue = nil
                    if campus.configured {Task {try? await Task.sleep(for:.milliseconds(300)); await flow.prepare(campus:campus,water:water)}}
                    else {login = true}
                } catch {flow.issue = "没导入成功。选热水平台给的配置文件，别用别人的完整配置。"}
            }
            .sheet(isPresented:$login) { CampusLoginSheet { value in
                do {
                    try await campus.adoptWebState(value)
                    flow.reset()
                    await campus.refresh(force:true)
                    campus.matchPowerAutomatically()
                    Task { await flow.prepare(campus:campus,water:water) }
                } catch { flow.issue = "这次没登录上，再试一次。" }
            } }
            .task {
                if campus.configured {
                    if !water.configured && flow.identity == nil { await flow.prepare(campus:campus,water:water) }
                } else if !offeredLogin {
                    offeredLogin = true
                    login = true
                }
            }
            .scrollContentBackground(.hidden).background(NothingTheme.background).tint(NativeTheme.tint)
    }
    private var dormMenus: some View {
        ForEach(0..<4,id:\.self) {level in
            if !flow.options[level].isEmpty {
                Menu {
                    ForEach(flow.options[level], id:\.id) {option in
                        Button(option.name) {Task {await flow.choose(option,at:level)}}
                    }
                } label: {LabeledContent(levels[level],value:flow.selected.count > level ? flow.selected[level].name : "选一下")}
                    .disabled(flow.busy).accessibilityIdentifier("dormLevel\(level)")
            }
        }
    }
}

/// Dorm → hot-water controller binding over `WaterOnboarding` (direct platform) or the access
/// service's bootstrap. Used by the dorm screen and by the first-run guide. Saving never starts
/// water or changes school data.
@MainActor final class DormSetupFlow: ObservableObject {
    @Published private(set) var identity: WaterUser?
    @Published private(set) var options: [[AreaNode]] = [[],[],[],[]]
    @Published private(set) var selected: [AreaNode] = []
    @Published private(set) var machines: [WaterMachine] = []
    @Published private(set) var serviceEnabled: Bool?
    @Published private(set) var autoMatched = false
    @Published private(set) var busy = false
    @Published private(set) var saved = false
    @Published var issue: String?
    private var directory: WaterDirectory?
    private var access: (client: WaterAccessServiceClient, grant: WaterAccessGrant, endpoint: URL)?

    func reset() {
        identity = nil; options = [[],[],[],[]]; selected = []; machines = []; saved = false; issue = nil
        autoMatched = false; serviceEnabled = nil; directory = nil; access = nil
    }

    enum AutoBind: Equatable {
        /// Saved: the portal address matched exactly one room with exactly one controller.
        case bound
        /// Hot water isn't available for this account/build: nothing to bind.
        case unavailable
        /// Needs the user: several rooms/controllers, nothing matched, or a read failed (`issue`).
        case needsChoice
    }

    /// First-run guide: the user confirmed the dorm read from the school account. Bind its
    /// controller when the match is unambiguous; otherwise the caller opens the dorm screen.
    func autoBind(campus: CampusModel, water: WaterModel) async -> AutoBind {
        if water.configured { return .bound }
        guard campus.configured else { return .needsChoice }
        await prepare(campus:campus, water:water)
        if identity == nil && issue == WaterModel.platformMissingText { return .unavailable }
        guard autoMatched, machines.count == 1, let machine = machines.first else { return .needsChoice }
        await save(machine, water:water)
        return saved ? .bound : .needsChoice
    }

    /// Reads the hot-water identity, then matches the portal dorm address (never guesses).
    func prepare(campus: CampusModel, water: WaterModel) async {
        guard !busy, campus.configured, water.mayImport else { return }
        reset()
        busy = true
        defer { busy = false }
        do {
            if let profile = water.profile {
                let client = LxtClient(http:AppServices.waterHTTP, profile:profile)
                let user = try await client.userInfo(campus.waterHandoff())
                identity = user; directory = client
                let onboarding = WaterOnboarding(directory:client)
                if let address = campus.address {
                    apply(try await onboarding.match(address, schoolId:user.schoolId), address:address)
                }
                if options[0].isEmpty { options[0] = try await client.areas(parent:user.schoolId) }
                if selected.isEmpty, options[0].count == 1, let only = options[0].first { busy = false; await choose(only, at:0) }
            } else {
                guard let session = try AppServices.schoolVault.ecyktSession(), let custid = session.custid else {
                    throw ServiceError.sessionExpired(.ecykt)
                }
                guard let endpoint = await WaterAccessServiceClient.firstHealthy(http:AppServices.waterAccessHTTP) else {
                    issue = WaterModel.platformMissingText; return
                }
                let base = WaterAccessServiceClient(http:AppServices.waterAccessHTTP, endpoint:endpoint)
                let (user, grant) = try await base.connect(session, custid:custid)
                let client = base.with(grant:grant)
                identity = user; directory = client; access = (client, grant, endpoint)
                let raw = campus.profile?.residence?.raw ?? ""
                let boot = try await client.bootstrap(residence:raw)
                serviceEnabled = boot.transactionsEnabled
                for (index, level) in boot.levels.prefix(4).enumerated() { options[index] = level }
                selected = boot.path; machines = boot.machines; autoMatched = boot.matched
                if boot.matched && boot.machines.isEmpty { issue = WaterOnboarding.noControllerText }
            }
        } catch {
            issue = (error as? ServiceError)?.userMessage ?? "暂时读不到宿舍，稍后再试。"
        }
    }

    private func apply(_ result: WaterOnboarding.Result, address: DormAddress) {
        switch result {
        case .matched(let path, let machine):
            selected = path; machines = [machine]; autoMatched = true
        case .chooseMachine(let path, let list):
            selected = path; machines = list; autoMatched = true
        case .pick(let level, let list, let path):
            selected = path; options[level.rawValue] = list
        case .noController(let path, let message):
            selected = path; issue = message
        case .addressUnknown(let message):
            issue = message
        }
    }

    func choose(_ option: AreaNode, at level: Int) async {
        guard !busy, selected.count >= level, let directory, let identity else { return }
        autoMatched = false
        selected = Array(selected.prefix(level)) + [option]
        for index in (level+1)..<4 { options[index] = [] }
        machines = []; saved = false; issue = nil; busy = true
        defer { busy = false }
        do {
            if level == 3 {
                switch try await WaterOnboarding(directory:directory).controllers(path:selected, schoolId:identity.schoolId) {
                case .matched(_, let machine): machines = [machine]
                case .chooseMachine(_, let list): machines = list
                case .noController(_, let message), .addressUnknown(let message): issue = message
                case .pick: issue = WaterOnboarding.noControllerText
                }
            } else {
                options[level+1] = level + 1 == 3 ? try await directory.rooms(floor:option.id) : try await directory.areas(parent:option.id)
                busy = false
                if options[level+1].count == 1, let only = options[level+1].first { await choose(only, at:level+1) }
            }
        } catch { issue = (error as? ServiceError)?.userMessage ?? "宿舍列表没读到，重新选一下。" }
    }

    func save(_ machine: WaterMachine, water: WaterModel) async {
        guard selected.count == 4, let identity, water.mayImport else { return }
        busy = true; defer { busy = false }
        do {
            if let access {
                try await access.client.bind(room:selected[3].id, machineID:machine.machineId)
                WaterProfileFiles.accessEndpoint = access.endpoint
            }
            let binding = WaterBinding(studentId:identity.studentId, schoolId:identity.schoolId, machineId:machine.machineId,
                                       roomId:selected[3].id, roomLabel:WaterOnboarding.roomLabel(selected),
                                       machineName:machine.name, access:access?.grant)
            try water.saveBinding(binding)
            saved = true; issue = nil
        } catch { issue = (error as? ServiceError)?.userMessage ?? "没保存上，再试一次。" }
    }
}
